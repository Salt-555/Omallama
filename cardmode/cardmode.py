#!/usr/bin/env python3
"""cardmode — Blackwell card-mode reconciler for the omallama control plane.

The RTX PRO 6000 holds exactly one resident shape at a time: mode "llm" (the
SGLang Flash-Next cell at mem-fraction 0.98) or mode "gen" (27B llama.cpp
CUDA + ComfyUI on the leftovers). Transitions cost real time (sglang reload
is minutes), so this daemon is the SINGLE owner of them:

  - nginx fronts ComfyUI (:8188 public -> comfy 127.0.0.1:8189) and gates
    every prompt POST through GET/POST /gate here via auth_request. nginx
    HOLDS the request while this handler runs; it is forwarded only once the
    card is actually in gen mode. Nothing can load diffusion models ahead of
    the switch, which is what keeps a Flash-Next-loaded card from OOMing a
    comfy job (or vice versa).
  - After gen_idle_minutes without comfy queue activity it reverts to llm.
  - Policy knobs in ~/.config/llama-server/modes.json (re-read on every
    switch, edit freely): on contention the LLM wins -- the gate waits up to
    llm_drain_cap_seconds for the current server to go idle, then answers 503
    and the client resubmits. The gate FAILS CLOSED: arbiter down = prompts
    refused, never blindly forwarded. min_dwell_seconds throttles thrash.

Modes are names mapped to presets.json entries by preset NAME, so the widget,
modelctl, and presets.json stay the single model registry. Mode is DERIVED
from model.json's .name on every call (state file is bookkeeping only), which
means a manual widget switch is self-adopted, never fought.

Transitions reuse the existing primitives in enforced order:
  gen -> llm:  POST comfy /free, wait nvidia-smi free >= sglang_min_free_mib,
               modelctl set <llm preset>, systemctl --user restart
               llama-server, health-gate on /health.
  llm -> gen:  modelctl set <gen preset>, systemctl restart, wait nvidia-smi
               free >= gen_min_free_mib (the previous backend's VRAM release
               lags tens of seconds on this card), health-gate on /v1/models.
Health-gating matters because sglang at 0.98 fails its startup malloc if the
card isn't free, and llama-server.service is Restart=no by design.
"""
import json
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

CFG_DIR = Path.home() / ".config/llama-server"
MODES_FILE = CFG_DIR / "modes.json"
MODEL_JSON = CFG_DIR / "model.json"
STATE_FILE = CFG_DIR / ".cardmode.json"
MODELCTL = Path.home() / ".config/omarchy/plugins/salt.llama-server/modelctl.sh"

DEFAULTS = {
    "gen_idle_minutes": 30,
    "llm_drain_cap_seconds": 600,
    "min_dwell_seconds": 120,
    "sglang_min_free_mib": 90000,
    "gen_min_free_mib": 40000,
    "comfy_url": "http://127.0.0.1:8189",
    "llm_url": "http://127.0.0.1:6969",
    "gate_port": 8190,
    "modes": {},
}


def log(msg: str) -> None:
    print(f"[cardmode] {time.strftime('%H:%M:%S')} {msg}", flush=True)


def load_cfg() -> dict:
    cfg = dict(DEFAULTS)
    try:
        cfg.update(json.loads(MODES_FILE.read_text()))
    except FileNotFoundError:
        log(f"config missing: {MODES_FILE}")
    except Exception as e:  # noqa: BLE001 - bad config must not kill the loop
        log(f"config error in {MODES_FILE}: {e}")
    return cfg


def http(url: str, method: str = "GET", payload=None, timeout: float = 5):
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["content-type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode(errors="replace")


def sh(*args: str, timeout: float = 60) -> tuple[int, str]:
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    out = (p.stdout + p.stderr).strip()
    return p.returncode, out


class Engine:
    def __init__(self) -> None:
        self.lock = threading.RLock()  # one transition at a time, gate + timer
        self.st = {
            "last_switch_ts": 0.0,
            "last_gen_activity": time.time(),
            "switching": False,
            "note": "boot",
        }
        self.last_revert_try = 0.0
        self._load_persisted()

    # ---------------- bookkeeping ----------------
    def _load_persisted(self) -> None:
        try:
            self.st.update(json.loads(STATE_FILE.read_text()))
            self.st["switching"] = False  # a restart mid-switch is not switching
        except FileNotFoundError:
            pass
        except Exception as e:  # noqa: BLE001
            log(f"state file unreadable, starting fresh: {e}")
        self.save()

    def save(self) -> None:
        try:
            STATE_FILE.write_text(json.dumps(self.st, indent=2) + "\n")
        except Exception as e:  # noqa: BLE001
            log(f"state write failed: {e}")

    def touched(self) -> None:
        """Adopt state changes made outside this process (manual widget switch)
        without touching the boot-preserved activity anchor."""
        self.st["note"] = "state re-derived"
        self.save()

    # ---------------- probes ----------------
    def current_mode(self, cfg: dict) -> tuple[str, dict]:
        try:
            mj = json.loads(MODEL_JSON.read_text())
        except Exception:  # noqa: BLE001
            return "unknown", {}
        name = mj.get("name", "")
        for mname, m in (cfg.get("modes") or {}).items():
            if m.get("preset") == name:
                return mname, mj
        return "manual", mj

    def ready_for(self, cfg: dict, mode: str) -> bool:
        url = cfg["llm_url"]
        try:
            if mode == "llm":
                status, _ = http(url + "/health", timeout=3)
                return status == 200
            status, body = http(url + "/v1/models", timeout=3)
            return status == 200 and "ALLMIND" in body
        except Exception:  # noqa: BLE001
            return False

    def llm_busy(self, mj: dict, cfg: dict) -> int:
        """In-flight + queued count on whatever serves :6969 right now.
        Metric names per monitor.sh: sglang:* carry verbose labels (sum all
        lines); llamacpp:* are plain."""
        backend = (mj.get("backend") or "").lower()
        try:
            _, body = http(cfg["llm_url"] + "/metrics", timeout=3)
        except Exception:  # noqa: BLE001 - server down = nothing in flight
            return 0
        total = 0.0
        for line in body.splitlines():
            if backend == "sglang":
                if line.startswith("sglang:num_running_reqs{") or line.startswith(
                    "sglang:num_queue_reqs{"
                ):
                    try:
                        total += float(line.rsplit(" ", 1)[1])
                    except (IndexError, ValueError):
                        pass
            else:
                if line.startswith("llamacpp:requests_processing ") or line.startswith(
                    "llamacpp:requests_deferred "
                ):
                    try:
                        total += float(line.rsplit(" ", 1)[1])
                    except (IndexError, ValueError):
                        pass
        return int(total)

    def comfy_busy(self, cfg: dict):
        try:
            _, body = http(cfg["comfy_url"] + "/queue", timeout=4)
            q = json.loads(body)
            return bool(q.get("queue_running") or q.get("queue_pending"))
        except Exception:  # noqa: BLE001 - comfy restarting/absent = unknown
            return None

    def comfy_free(self, cfg: dict) -> None:
        try:
            http(
                cfg["comfy_url"] + "/free",
                "POST",
                {"unload_models": True, "free_memory": True},
                timeout=15,
            )
            log("asked comfy to free models")
        except Exception as e:  # noqa: BLE001
            log(f"comfy /free failed (continuing): {e}")

    def gpu_free_mib(self):
        try:
            rc, out = sh(
                "nvidia-smi",
                "--query-gpu=memory.free",
                "--format=csv,noheader,nounits",
                timeout=10,
            )
            vals = [int(l.strip()) for l in out.splitlines() if l.strip()]
            return max(vals) if rc == 0 and vals else None
        except Exception:  # noqa: BLE001
            return None

    def wait_gpu_free(self, need_mib: int, deadline_s: float) -> bool:
        t0 = time.time()
        while time.time() - t0 < deadline_s:
            free = self.gpu_free_mib()
            if free is None:  # no nvidia-smi / no card: don't block forever
                return True
            if free >= need_mib:
                return True
            log(f"card handoff: free {free} MiB < {need_mib} MiB, waiting")
            time.sleep(5)
        return False

    # ---------------- the one transition executor ----------------
    def ensure(self, target: str, reason: str) -> tuple[bool, str]:
        with self.lock:
            cfg = load_cfg()
            modes = cfg.get("modes") or {}
            if target not in modes:
                return False, f"mode '{target}' not in modes.json"
            cur, mj = self.current_mode(cfg)
            if cur == target and self.ready_for(cfg, target):
                return True, f"already in {target}"

            dwell = float(cfg["min_dwell_seconds"])
            gap = dwell - (time.time() - self.st["last_switch_ts"])
            if cur != target and gap > 0:
                log(f"dwell: waiting {gap:.0f}s before {cur} -> {target} ({reason})")
                time.sleep(gap)

            # LLM wins contention: never restart :6969 with work in flight.
            cap = float(cfg["llm_drain_cap_seconds"])
            t0 = time.time()
            while True:
                busy = self.llm_busy(mj, cfg)
                if busy == 0:
                    break
                if time.time() - t0 > cap:
                    self.st["note"] = f"switch {target} blocked: llm busy > cap ({reason})"
                    self.save()
                    return False, f"llm still busy after {cap:.0f}s drain cap ({reason})"
                log(f"draining :6969 ({busy} in flight), {reason}")
                time.sleep(5)

            preset = modes[target]["preset"]
            ready_to = int(modes[target].get("ready_timeout", 600 if target == "llm" else 180))
            self.st["switching"] = True
            self.st["note"] = f"switching {cur} -> {target} ({reason})"
            self.save()
            log(self.st["note"])

            # Release order: stop the server BEFORE measuring free VRAM -- the
            # outgoing model's own allocation would otherwise pin the guard
            # under its threshold forever (27B holds ~26 GB while we wait).
            if target == "llm":
                self.comfy_free(cfg)
            sh("systemctl", "--user", "stop", "llama-server.service", timeout=120)
            need = int(cfg["sglang_min_free_mib"] if target == "llm" else cfg["gen_min_free_mib"])
            if not self.wait_gpu_free(need, 90 if target == "llm" else 120):
                log(f"card not free ({need} MiB target) for {target}; launching anyway (watch the journal)")

            rc, out = sh("bash", str(MODELCTL), "set", preset)
            if rc != 0:
                self.st.update(switching=False, note=f"modelctl set failed: {out}")
                self.save()
                return False, f"modelctl set failed: {out}"

            rc, out = sh("systemctl", "--user", "start", "llama-server.service", timeout=120)

            t0 = time.time()
            while time.time() - t0 < ready_to:
                if self.ready_for(cfg, target):
                    now = time.time()
                    self.st.update(
                        switching=False,
                        last_switch_ts=now,
                        note=f"in {target} (was {cur}, {reason})",
                    )
                    if target == "gen":
                        # idle clock starts on entry: 30 min of unused comfy
                        # reverts even if nobody ever prompted it
                        self.st["last_gen_activity"] = now
                    self.save()
                    log(f"switched {cur} -> {target} in {now - t0:.0f}s ({reason})")
                    return True, self.st["note"]
                time.sleep(3)
            self.st.update(switching=False, note=f"switch to {target} timed out ({reason})")
            self.save()
            return False, self.st["note"]

    # ---------------- surfaces ----------------
    def handle_gate(self, method: str = "GET") -> tuple[int, str]:
        """nginx auth_request target. 200 = prompt may proceed on comfy.
        The auth subrequest inherits the original method; GET /prompt is just
        queue info, only POSTs are demand. Fail closed on any anomaly."""
        if method == "GET":
            return 200, "open:get"
        cfg = load_cfg()
        cur, _ = self.current_mode(cfg)
        if cur == "gen":
            self.st["last_gen_activity"] = time.time()
            self.save()
            return 200, "mode=gen"
        ok, why = self.ensure("gen", "comfy-prompt")
        if ok:
            self.st["last_gen_activity"] = time.time()
            self.save()
            return 200, why
        return 503, why

    def idle_loop(self) -> None:
        while True:
            time.sleep(15)
            cfg = load_cfg()
            cur, _ = self.current_mode(cfg)
            if self.comfy_busy(cfg):
                self.st["last_gen_activity"] = time.time()
                self.save()
            if cur == "gen":
                idle_s = float(cfg["gen_idle_minutes"]) * 60
                if time.time() - self.st["last_gen_activity"] > idle_s:
                    if time.time() - self.last_revert_try < 60:
                        continue
                    self.last_revert_try = time.time()
                    ok, why = self.ensure("llm", "gen-idle")
                    log(f"idle revert: {'ok' if ok else 'FAILED'}: {why}")


class Handler(BaseHTTPRequestHandler):
    engine: Engine = None  # set once

    def _reply(self, code: int, body: str) -> None:
        raw = body.encode()
        self.send_response(code)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _route(self) -> None:
        u = urlparse(self.path)
        if u.path in ("/gate", "/gate/"):
            # nginx auth subrequests arrive as GET; the parent method rides in
            # X-Original-Method (set in nginx.conf). Fail closed: decide on the
            # header, never on the subrequest line alone.
            method = self.headers.get("X-Original-Method") or self.command
            code, body = self.engine.handle_gate(method)
            log(f"gate [{method}] -> {code} {body}")
            self._reply(code, body)
        elif u.path == "/status":
            cfg = load_cfg()
            cur, mj = self.engine.current_mode(cfg)
            st = dict(self.engine.st)
            st.update(
                mode=cur,
                model=mj.get("name") or mj.get("model"),
                backend=mj.get("backend"),
                last_gen_activity_iso=time.strftime(
                    "%Y-%m-%dT%H:%M:%S", time.localtime(st.get("last_gen_activity", 0))
                ),
                gpu_free_mib=self.engine.gpu_free_mib(),
            )
            self._reply(200, json.dumps(st, indent=2) + "\n")
        elif u.path == "/switch":
            mode = (parse_qs(u.query).get("mode") or [""])[0]
            if mode not in ("llm", "gen"):
                self._reply(400, "usage: /switch?mode=llm|gen\n")
                return
            ok, why = self.engine.ensure(mode, "manual")
            self._reply(200 if ok else 503, ("ok: " if ok else "failed: ") + why + "\n")
        else:
            self._reply(404, "not found\n")

    do_GET = do_POST = _route

    def log_message(self, *args) -> None:  # quiet: our own log() covers it
        pass


def main() -> None:
    cfg = load_cfg()
    eng = Engine()
    Handler.engine = eng
    cur, mj = eng.current_mode(cfg)
    log(f"start; model.json name={mj.get('name')!r} backend={mj.get('backend')!r} -> mode={cur}")
    threading.Thread(target=eng.idle_loop, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", int(cfg["gate_port"])), Handler).serve_forever()


if __name__ == "__main__":
    main()
