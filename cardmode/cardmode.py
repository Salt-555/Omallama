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
    switch, edit freely): on contention the LLM wins -- the gate WAITS for the
    current server to go idle (drain), for the card to be handed over, and for
    the new model to load. NONE of those waits has a deadline (Salt,
    2026-11-18): the reconciler publishes what it is waiting on as a `phase`
    state and keeps watching until the condition clears. The gate still FAILS
    CLOSED on a real conflict or error (arbiter down = prompts refused, an
    unknown process holding :6969 = abort), but "still busy" is never a
    refusal. min_dwell_seconds throttles thrash.
    EXCEPTION (2026-10-17): when nothing ACCEPTS connections on :6969 there
    is no work in flight to protect -- in-flight requests imply a live
    listener. A gen-mode demand (comfy prompt) arriving during an llm BOOT
    then PREEMPTS the load (cancel + switch to gen) instead of holding the
    gate to the cap and killing the finished boot afterward anyway; dwell is
    skipped for the same reason (it protects a serving LLM, which does not
    exist). The same rule lets an idle revert heal a dead :6969 instead of
    looping blocked on "still busy" forever.

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

Every transition step fails closed (2026-10-16 incident, five linked holes):
a /metrics scrape failure is UNKNOWN = busy until the drain cap; two
consecutive idle reads are required before the stop; wait_gpu_free timing
out ABORTS the switch instead of "launching anyway"; ready_for() matches
runtime IDENTITY (sglang:* vs llamacpp:* metric families), not liveness --
an orphaned container answering :6969 satisfies liveness checks perfectly;
and before any start the unit's leftovers are reaped (docker rm -f) and the
port must be free or the switch aborts.
"""
import json
import socket
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
PRESETS_FILE = CFG_DIR / "presets.json"
STATE_FILE = CFG_DIR / ".cardmode.json"
MODELCTL = Path.home() / ".config/omarchy/plugins/salt.llama-server/modelctl.sh"
# One implementation of runtime semantics (health/counts/ready/label), shared
# with monitor.sh. cardmode supplies the POLICY -- fail closed -- and this
# script supplies the SHAPES.
PROBE = CFG_DIR / "probe.sh"
SGLANG_CONTAINER = "sglang-llm"  # serve-sglang.sh's --name; ours to reap
BASALT_CONTAINER = "basalt-llm"  # serve-basalt.sh's --name; same contract
# serve-basalt.sh's default root (BASALT_ROOT env can move it). Its generated
# appdata/basalt_config.json names the pack the RUNNING container loaded, which
# is the only per-shape identity a basalt boot exposes -- the alias is ALLMIND
# for every pack and the container name is the same for every pack.
BASALT_ROOT = Path.home() / "egpu-nvidia-setup/basalt"

DEFAULTS = {
    "gen_idle_minutes": 30,
    # Cap on drain/card/load waits: REMOVED 2026-11-18 (Salt). Waiting is a
    # state now; llm_drain_cap_seconds in modes.json is inert.
    "min_dwell_seconds": 120,
    "sglang_min_free_mib": 90000,
    "gen_min_free_mib": 40000,
    "comfy_url": "http://127.0.0.1:8189",
    "llm_url": "http://127.0.0.1:6969",
    # Chatterbox TTS on the card (:8880). Coexists with sglang only once it is
    # up, but must be clear while sglang does its ~0.98-card startup malloc;
    # cardmode bounces it around that malloc and does nothing else with it.
    "tts_service": "chatterbox.service",
    # Pressure valve: unload TTS once card usage hits (100 - this) percent.
    "tts_pressure_min_free_pct": 1.0,
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
    """Run a command; NEVER raise.

    A command that outlives its timeout answers rc 124 with "timeout", which
    every caller already treats as a failed read. That is deliberate: a wait
    on a slow probe must cost one state update, never an exception. On
    2026-11-18 a bare nvidia-smi timeout escaped the idle timer's thread and
    killed it for good (23 hours stuck in gen with every surface healthy).
    """
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        log(f"command timed out after {timeout:.0f}s: {' '.join(args[:2])} (state: unknown)")
        return 124, "timeout"
    except Exception as e:  # noqa: BLE001
        log(f"command failed to run: {' '.join(args[:2])}: {e!r}")
        return 125, str(e)
    return p.returncode, (p.stdout + p.stderr).strip()


class Engine:
    def __init__(self) -> None:
        self.lock = threading.RLock()  # one transition at a time, gate + timer
        self.st = {
            "last_switch_ts": 0.0,
            "last_gen_activity": time.time(),
            "switching": False,
            "enabled": True,
            "note": "boot",
            # What the reconciler is WAITING on, as a state: "waiting: drain
            # 2 in flight", "waiting: card handoff (71000/90000 MiB free)",
            # "loading llm". Empty = nothing pending. A wait has no deadline;
            # it publishes itself here and keeps watching.
            "phase": "",
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

    def set_phase(self, text: str) -> None:
        """Publish what we are waiting on. A wait is a STATE: nothing here has
        a deadline, and nothing refuses because a condition is not clear yet.
        Logged only on change, because the drain/handoff loops re-assert it
        every few seconds."""
        text = " ".join(str(text).split())
        if self.st.get("phase") == text:
            return
        self.st["phase"] = text
        self.save()
        log(f"phase: {text or 'idle'}")

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

    def preset_for_mode(self, cfg: dict, mode: str) -> dict:
        """The shape a mode DECLARES (modes.json -> presets.json). Never from
        model.json: that records what was last selected, which is exactly what
        an identity check must not vouch for."""
        name = ((cfg.get("modes") or {}).get(mode) or {}).get("preset")
        if not name:
            return {}
        try:
            for p in json.loads(PRESETS_FILE.read_text()):
                if p.get("name") == name:
                    return p
        except Exception:  # noqa: BLE001 - unreadable declaration: no shape gate
            pass
        return {}

    def ready_for(self, cfg: dict, mode: str) -> bool:
        """IDENTITY, not liveness. Anything answering :6969 satisfies a
        liveness check -- on 2026-10-16 an orphaned sglang container
        (health 503, still holding ~94 GiB) answered /v1/models with ALLMIND
        and a gen switch that never happened was logged as done in 0s. The
        runtime names itself through its metric families (the monitor.sh
        contract): sglang:* or llamacpp:* plus the ALLMIND id.
        Which family proves WHICH mode is the preset's business now, not the
        mode name's: llm mode may run sglang or llama.cpp. And since one
        llama.cpp build serves both our 27B shapes, family alone cannot tell a
        gen boot from an llm boot -- so a preset that pins n_parallel must also
        see /props total_slots match it."""
        url = cfg["llm_url"]
        want = self.preset_for_mode(cfg, mode)
        backend = (want.get("backend") or "").lower()
        if not backend:  # preset without a declared backend: historic mapping
            backend = "sglang" if mode == "llm" else "llama"
        slots = want.get("n_parallel")
        if slots is None:
            slots = want.get("parallel")  # basalt presets name the same knob parallel
        try:
            # The shapes live in probe.sh (shared with monitor.sh); the policy
            # lives here. Any non-"yes" -- failed scrape, half-booted engine,
            # wrong shape on the port -- is NOT ready.
            rc, out = sh("bash", str(PROBE), "ready", backend, url,
                         "" if slots is None else str(int(slots)), timeout=10)
            return rc == 0 and out.strip() == "yes"
        except Exception:  # noqa: BLE001 - fail closed
            return False

    def llm_busy(self, mj: dict, cfg: dict) -> "int | None":
        """In-flight + queued count on whatever serves :6969 right now, or
        None when the scrape fails. A failed scrape is UNKNOWN, never idle:
        the 2026-10-16 incident stopped sglang mid-request because the
        exception path here returned 0 ("server down = nothing in flight").
        The per-runtime metric shapes live in probe.sh, shared with the
        widget's poller."""
        backend = (mj.get("backend") or "").lower()
        try:
            rc, out = sh("bash", str(PROBE), "counts", backend, cfg["llm_url"], timeout=6)
        except Exception:  # noqa: BLE001 - unknown, fail closed
            return None
        if rc != 0 or not out.strip():
            return None
        parts = out.split()
        try:
            active = float(parts[0])
            deferred = float(parts[1]) if len(parts) > 1 else 0.0
            return int(active + deferred)
        except (ValueError, IndexError):
            return None

    def port_held(self, cfg: dict) -> bool:
        """True when something ACCEPTS connections on the LLM port. A connect
        succeeds regardless of protocol and long before any HTTP probe could
        answer -- this is the identity gate run before every start."""
        u = urlparse(cfg["llm_url"])
        try:
            with socket.create_connection((u.hostname or "127.0.0.1", u.port or 80), timeout=2):
                return True
        except OSError:
            return False

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

    def tts_active(self, cfg: dict) -> bool:
        # A probe failure must never propagate: this runs inside the idle
        # timer's tick AND inside ensure()'s transition, and an nvidia-smi or
        # systemctl timeout under load used to kill the timer thread outright.
        try:
            rc, _ = sh("systemctl", "--user", "is-active", cfg["tts_service"], timeout=10)
        except Exception as e:  # noqa: BLE001
            log(f"tts state probe failed (treating as off): {e!r}")
            return False
        return rc == 0

    def tts_set(self, cfg: dict, on: bool) -> None:
        rc, out = sh(
            "systemctl", "--user", "start" if on else "stop", cfg["tts_service"], timeout=90
        )
        if rc != 0:
            log(f"tts {'start' if on else 'stop'} failed (rc {rc}): {out.strip()[:160]}")

    def tts_pressure_check(self, cfg: dict) -> None:
        """Pressure valve. The card keeps no slack once the sglang pool
        creeps, and TTS is the only tenant that can give memory back without
        breaking an in-flight job. UNLOAD-ONLY by design: cardmode never
        re-starts TTS from here, or a manual toggle-off in the widget could
        be resurrected against the user's will. Re-enable is a human click.
        An unreadable probe is no action -- TTS must not flap on a bad probe."""
        lim = float(cfg.get("tts_pressure_min_free_pct", 1.0))
        if lim <= 0 or not self.tts_active(cfg):
            return
        try:
            rc, out = sh(
                "nvidia-smi",
                "--query-gpu=memory.used,memory.total",
                "--format=csv,noheader,nounits",
                timeout=10,
            )
        except Exception as e:  # noqa: BLE001 - pressure valve skips this tick
            log(f"tts pressure probe failed (skipped): {e!r}")
            return
        try:
            pairs = [[int(x) for x in l.split(",", 1)] for l in out.splitlines() if l.strip()]
            used, total = max(pairs, key=lambda p: p[0])
            pct = 100.0 * used / total
        except (ValueError, IndexError, ZeroDivisionError):
            return
        if rc == 0 and pairs and pct >= 100.0 - lim:
            self.tts_set(cfg, False)
            self.st["note"] = f"tts unloaded: card at {pct:.1f}% (limit {100 - lim:.0f}%)"
            self.save()
            log(self.st["note"])

    def unit_active(self) -> bool:
        rc, _ = sh("systemctl", "--user", "is-active", "llama-server.service", timeout=10)
        return rc == 0

    def llm_runtime_evidence(self, cfg: dict) -> bool:
        """True when :6969 is (or is becoming) the runtime llm mode DECLARES.
        For an sglang llm mode: the sglang-llm container running, or sglang
        metric families present. A container mid-load answers neither /metrics
        nor /health yet -- the container name is the only early signal
        (2026-10-17 revert killed a healthy Flash-Next boot because model.json
        still named the gen preset).
        A llama.cpp llm mode has no container, so the identity check carries
        it: ready_for matches the metric family AND /props total_slots, which a
        gen-shape llama.cpp on the same file cannot fake. Same blind spot the
        container path has: a llama.cpp boot that has not bound :6969 yet is
        invisible, and the revert pays one reload."""
        if (self.preset_for_mode(cfg, "llm").get("backend") or "").lower() == "llama":
            return self.ready_for(cfg, "llm")
        if (self.preset_for_mode(cfg, "llm").get("backend") or "").lower() == "basalt":
            # The container NAME is shared: the gen preset is a basalt pack too
            # and runs as the SAME basalt-llm. "running" therefore proves
            # nothing about WHICH pack holds the card -- and on 2026-11-14,
            # when llm mode became a basalt preset, that shortcut adopted the
            # gen 27B as if it were an llm boot on every idle revert (4/4),
            # flipping model.json to the Chat preset while the card kept the
            # image pack. No gen -> llm transition ran again for three days
            # (35 of them in the sixteen days before, all from this branch's
            # sglang path). Identity has to come from the pack, not the name.
            #
            # serve-basalt.sh regenerates appdata/basalt_config.json from
            # model.json BEFORE it execs docker, so the file records the pack
            # the running container actually loaded -- and it is available
            # during the load window, when no HTTP probe can answer yet.
            try:
                rc, out = sh("docker", "inspect", "-f", "{{.State.Running}}", BASALT_CONTAINER, timeout=10)
                if not (rc == 0 and out.strip() == "true"):
                    return False
            except Exception:  # noqa: BLE001
                return False
            want = self.preset_for_mode(cfg, "llm").get("model") or ""
            try:
                booted = json.loads((BASALT_ROOT / "appdata/basalt_config.json").read_text())
                packs = {Path(m.get("model") or "").name for m in booted.get("models") or []}
            except Exception:  # noqa: BLE001 - unreadable launch config: no evidence
                return False
            return bool(want) and Path(want).name in packs
        try:
            rc, out = sh("docker", "inspect", "-f", "{{.State.Running}}", SGLANG_CONTAINER, timeout=10)
            if rc == 0 and out.strip() == "true":
                return True
        except Exception:  # noqa: BLE001
            pass
        try:
            status, body = http(cfg["llm_url"] + "/metrics", timeout=3)
            return status == 200 and "sglang:" in body
        except Exception:  # noqa: BLE001
            return False

    def gpu_free_mib(self) -> tuple["int | None", bool]:
        """(free MiB, probe_trustworthy). A TIMED-OUT probe is unknown, not
        'the card is gone': the handoff guard must keep waiting on unknown, or
        a slow nvidia-smi reads as free and the next model loads into the
        outgoing one's memory. Only a probe that actually runs and reports no
        card is allowed to mean 'nothing to wait for'."""
        rc, out = sh(
            "nvidia-smi",
            "--query-gpu=memory.free",
            "--format=csv,noheader,nounits",
            timeout=10,
        )
        if rc in (124, 125):  # timed out / could not run: state unknown
            return None, True
        try:
            vals = [int(l.strip()) for l in out.splitlines() if l.strip()]
        except ValueError:
            return None, False
        return (max(vals) if rc == 0 and vals else None), bool(rc == 0 and vals)

    def wait_gpu_free(self, need_mib: int) -> None:
        """Wait for the card. No deadline, no abort: the outgoing server's
        release lag is measured in seconds, and a transition that waits is
        better than one that dies after an arbitrary 90 s and leaves the box
        half-switched."""
        while True:
            free, known = self.gpu_free_mib()
            if not known:  # probe ran and found no card: nothing to wait for
                return
            if free is not None and free >= need_mib:
                return
            shown = "unknown" if free is None else f"{free} MiB free"
            self.set_phase(f"waiting: card handoff ({shown}/{need_mib} needed)")
            time.sleep(5)

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

            # Preempt rule (2026-10-17): nothing accepting :6969 = nothing in
            # flight to protect (in-flight work implies a live listener). A
            # live container with an unbound port is a boot in progress
            # (sglang binds the HTTP port last); a dead unit is equally
            # preemptible. Skip dwell: it protects a serving LLM, which does
            # not exist here. A HELD port with a failed scrape stays
            # fail-closed below (the 2026-10-16 incident class).
            preempting = cur != target and not self.port_held(cfg)
            dwell = float(cfg["min_dwell_seconds"])
            gap = dwell - (time.time() - self.st["last_switch_ts"])
            if cur != target and gap > 0 and not preempting:
                self.set_phase(f"waiting: dwell {gap:.0f}s before {cur} -> {target} ({reason})")
                time.sleep(gap)

            # LLM wins contention: never restart :6969 with work in flight.
            # A failed scrape is UNKNOWN and counts as busy. Two consecutive
            # zero reads debounce the stop: the second one is the re-check
            # immediately before systemctl stop, closing the
            # request-arrived-between-polls race.
            #
            # NO DRAIN CAP (Salt, 2026-11-18): waiting for the port to go idle
            # is a state, not a deadline. The old 600 s cap turned a busy server
            # into a 503 the client had to retry; the reconciler now publishes
            # what it is waiting on and keeps watching until the work drains.
            zeros = 0
            while True:
                busy = self.llm_busy(mj, cfg)
                if busy == 0:
                    zeros += 1
                    if zeros >= 2:
                        break
                else:
                    zeros = 0
                    if busy is None and not self.port_held(cfg):
                        # No listener on :6969: no work to drain. A live
                        # container here is a boot in progress -- cancel it
                        # (comfy demand preempts an llm load, 2026-10-17)
                        # rather than waiting on a boot that will be killed
                        # afterward anyway.
                        log(f"preempting {cur} -> {target}: no listener on :6969 ({reason})")
                        break
                    self.set_phase(
                        f"waiting: drain ({'unknown in flight' if busy is None else str(busy) + ' in flight'})"
                        f" before {cur} -> {target} ({reason})"
                    )
                time.sleep(5)

            preset = modes[target]["preset"]
            self.st["switching"] = True
            self.st["note"] = f"switching {cur} -> {target} ({reason})"
            self.save()
            log(self.st["note"])

            # Release order: stop the server BEFORE measuring free VRAM -- the
            # outgoing model's own allocation would otherwise pin the guard
            # under its threshold forever (27B holds ~26 GB while we wait).
            # Chatterbox (~4 GB) coexists with sglang only AFTER sglang is up
            # (it fits the ~7 GB sglang leaves free); sglang reserves ~0.98 of
            # the card at STARTUP, so a resident Chatterbox would make that
            # cudaMalloc fail. Bounce it before the guard, restore on every
            # exit only if the user had it on. gen fits it directly -> untouched.
            tts_on = self.tts_active(cfg)
            if target == "llm":
                if tts_on:
                    self.tts_set(cfg, False)
                self.comfy_free(cfg)
            else:
                tts_on = False
            # Must exceed the unit's TimeoutStopSec (300): returning early
            # would have cardmode act on a stop still in flight -- two owners.
            # sh() never raises, so a wedged stop lands as rc 124 and the card
            # handoff below simply waits for the release instead of aborting.
            self.set_phase(f"stopping {cur} for {target} ({reason})")
            rc, out = sh("systemctl", "--user", "stop", "llama-server.service", timeout=360)
            if rc != 0:
                log(f"stop returned rc {rc}: {out[:160]} (continuing; the card guard is the sync)")
            need = int(cfg["sglang_min_free_mib" if target == "llm" else "gen_min_free_mib"])
            self.wait_gpu_free(need)

            rc, out = sh("bash", str(MODELCTL), "set", preset)
            if rc != 0:
                self.st.update(switching=False, phase="", note=f"modelctl set failed: {out}")
                self.save()
                if tts_on:
                    self.tts_set(cfg, True)
                return False, f"modelctl set failed: {out}"

            # Identity gate before the start: with the unit down, a surviving
            # sglang container is OUR orphan (the 2026-10-16 zombie held ~94 GiB
            # and :6969 while answering every liveness check) -- reap it. An
            # unknown squatter is not ours: a conflict, not a wait, so fail.
            if sh("docker", "rm", "-f", SGLANG_CONTAINER)[0] == 0:
                log(f"reaped leftover container {SGLANG_CONTAINER}")
            if sh("docker", "rm", "-f", BASALT_CONTAINER)[0] == 0:
                log(f"reaped leftover container {BASALT_CONTAINER}")
            if self.port_held(cfg):
                self.st.update(
                    switching=False,
                    phase="",
                    note=f"switch to {target} aborted: something still holds :6969",
                )
                self.save()
                if tts_on:
                    self.tts_set(cfg, True)
                return False, self.st["note"]

            rc, out = sh("systemctl", "--user", "start", "llama-server.service", timeout=120)

            # Loading is a state too: a 67.8 GiB pack takes as long as it takes.
            t0 = time.time()
            self.set_phase(f"loading {target} ({reason})")
            while True:
                if self.ready_for(cfg, target):
                    now = time.time()
                    self.st.update(
                        switching=False,
                        phase="",
                        last_switch_ts=now,
                        note=f"in {target} (was {cur}, {reason})",
                    )
                    if target == "gen":
                        # idle clock starts on entry: 30 min of unused comfy
                        # reverts even if nobody ever prompted it
                        self.st["last_gen_activity"] = now
                    self.save()
                    # Restore TTS last: the new runtime is confirmed serving, so
                    # its startup malloc has landed and Chatterbox's ~4 GB fits
                    # the residual headroom.
                    if tts_on:
                        self.tts_set(cfg, True)
                    log(f"switched {cur} -> {target} in {now - t0:.0f}s ({reason})")
                    return True, self.st["note"]
                time.sleep(3)

    # ---------------- surfaces ----------------
    def handle_gate(self, method: str = "GET") -> tuple[int, str]:
        """nginx auth_request target. 200 = prompt may proceed on comfy.
        The auth subrequest inherits the original method; GET /prompt is just
        queue info, only POSTs are demand. Fail closed on any anomaly.
        Smart mode off = instant pass-through (pre-cardmode semantics: the
        comfy headroom guard is the only remaining protection)."""
        if method == "GET":
            return 200, "open:get"
        if not self.st.get("enabled", True):
            return 200, "open:auto-off"
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
        """The idle timer, in a thread that must outlive its probes.

        This daemon thread IS the only thing that ever returns the card from
        gen to llm on its own. On 2026-11-18 10:22 an nvidia-smi call inside
        tts_pressure_check hit its 10 s timeout under load, the TimeoutExpired
        escaped the thread's target, and the thread died for good: the gate
        kept answering 200 (so nothing looked broken) while no revert could
        ever fire again. A probe that fails may cost one tick, never the loop.
        """
        while True:
            time.sleep(15)
            try:
                self.idle_tick()
            except Exception as e:  # noqa: BLE001 - a bad tick is not a dead timer
                log(f"idle tick failed (loop continues): {e!r}")

    def idle_tick(self) -> None:
        cfg = load_cfg()
        cur, _ = self.current_mode(cfg)
        if self.comfy_busy(cfg):
            self.st["last_gen_activity"] = time.time()
            self.save()
        # Same lock as ensure(): a switch mid-flight owns the card; its
        # bounce already handles TTS, and a pressure probe racing it would
        # just read stale numbers.
        with self.lock:
            self.tts_pressure_check(cfg)
        if cur == "gen" and self.st.get("enabled", True):
            idle_s = float(cfg["gen_idle_minutes"]) * 60
            if time.time() - self.st["last_gen_activity"] > idle_s:
                if time.time() - self.last_revert_try < 60:
                    return
                self.last_revert_try = time.time()
                # Adopt a manual llm boot instead of killing it. The mode is
                # derived from model.json alone, so an llm boot that predates
                # cardmode's own switch reads as "gen" here and the revert paid
                # the ~3 min load twice (2026-10-17). The evidence call must
                # prove the RESIDENT SHAPE is the llm preset -- on a basalt
                # backend the container name and the ALLMIND id are shared by
                # both modes, and trusting them adopted the gen pack 4/4 from
                # 2026-11-14, leaving the card on the image pack for days.
                if self.unit_active() and self.llm_runtime_evidence(cfg):
                    preset = (cfg.get("modes") or {}).get("llm", {}).get("preset")
                    if preset:
                        sh("bash", str(MODELCTL), "set", preset, timeout=60)
                    self.st.update(
                        switching=False,
                        last_switch_ts=time.time(),
                        note="adopted manual llm boot (gen-idle revert skipped)",
                    )
                    self.save()
                    log(self.st["note"])
                    return
                ok, why = self.ensure("llm", "gen-idle")
                log(f"idle revert: {'ok' if ok else 'FAILED'}: {why}")


class Handler(BaseHTTPRequestHandler):
    engine: Engine = None  # set once

    def _reply(self, code: int, body: str, headers: dict | None = None) -> None:
        raw = body.encode()
        self.send_response(code)
        self.send_header("content-type", "text/plain")
        self.send_header("content-length", str(len(raw)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _route(self) -> None:
        try:
            self._dispatch()
        except Exception as e:  # noqa: BLE001 - never hang nginx on a bug
            import traceback

            log(f"handler error: {e!r}\n{traceback.format_exc()}")
            try:
                self._reply(500, f"cardmode error: {e}\n")
            except Exception:  # noqa: BLE001
                pass

    def _dispatch(self) -> None:
        u = urlparse(self.path)
        if u.path in ("/gate", "/gate/"):
            # nginx auth subrequests arrive as GET; the parent method rides in
            # X-Original-Method (set in nginx.conf). Fail closed: decide on the
            # header, never on the subrequest line alone.
            method = self.headers.get("X-Original-Method") or self.command
            code, body = self.engine.handle_gate(method)
            # A denial must reach the client with its REASON, and auth_request
            # only forwards 401/403 verbatim -- every other non-2xx becomes a
            # bodiless 500. So answer 403 here and let the proxy's
            # `error_page 403` turn it into a 503 carrying $cardmode_reason.
            # The public contract is unchanged: a refused prompt still gets 503.
            reason = " ".join(str(body).split())[:400]
            hdrs = {"X-Cardmode-Reason": reason} if code != 200 else {}
            if code not in (200, 403):
                code = 403
            log(f"gate [{method}] -> {code} {body}")
            self._reply(code, body, hdrs)
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
                gpu_free_mib=self.engine.gpu_free_mib()[0],
            )
            self._reply(200, json.dumps(st, indent=2) + "\n")
        elif u.path == "/enable":
            # Smart-mode master switch (the widget toggle). Off = gate passes
            # prompts straight through and the idle timer stands down; it
            # never unloads anything -- residency stays llama-server's job.
            eng = self.engine
            on = (parse_qs(u.query).get("on") or ["1"])[0]
            enabled = on not in ("0", "false", "off")
            eng.st["enabled"] = enabled
            if enabled:
                # Grace: re-arming must not instantly revert a freshly idle
                # gen mode with a timer that was frozen while disarmed.
                eng.st["last_gen_activity"] = time.time()
            eng.st["note"] = f"smart mode {'ON' if enabled else 'OFF'}"
            eng.save()
            log(eng.st["note"])
            self._reply(200, eng.st["note"] + "\n")
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
