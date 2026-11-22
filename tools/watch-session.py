#!/usr/bin/env python3
"""Passive real-workload sampler for the :6969 engine.

Records what the engine reports while you use it normally, then reports
averages. No synthetic load, no restarts, no state written into the server.

  ./watch-session.py --minutes 10          # record for 10 min, then report
  ./watch-session.py --minutes 10 --quiet  # record only
  ./watch-session.py --report FILE.jsonl   # report on an earlier capture

Basalt's /metrics is JSON and already carries per-request telemetry:
decode_tok_s, ttft_s, prompt_tokens, reused, drafts_accepted/offered, slot and
duration. That is what makes a passive average honest -- these are the engine's
own numbers for real requests, not a benchmark's guess.

JSONL lines: {"kind":"sample"} every interval, {"kind":"req"} once per new
completed request (deduped by id), {"kind":"miss"} when the scrape fails, so a
restart shows up as a gap instead of silently skewing the averages.
"""

import argparse
import json
import os
import statistics
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
OUTDIR = os.path.join(HOME, ".config/llama-server/sessions")

FIELDS = (
    "id", "path", "slot", "time", "duration_s", "finish",
    "prompt_tokens", "reused", "output_tokens", "prompt_ms",
    "decode_tok_s", "ttft_s", "drafts_offered", "drafts_accepted",
    "hit_rate", "pcie_share", "ssd_share",
)


def scrape(url, timeout=3):
    with urllib.request.urlopen(url.rstrip("/") + "/metrics", timeout=timeout) as resp:
        return json.loads(resp.read())


def record(url, minutes, interval, path, quiet=False):
    t_end = time.time() + minutes * 60
    seen = set()
    seeded = False
    samples = 0
    requests = 0
    misses = 0
    started = time.time()
    with open(path, "w") as fh:
        while time.time() < t_end:
            now = time.time()
            try:
                m = scrape(url)
            except Exception as exc:                # noqa: BLE001 - gap is the point
                misses += 1
                fh.write(json.dumps({"kind": "miss", "t": now, "err": type(exc).__name__}) + "\n")
            else:
                hw = m.get("hardware") or {}
                gpu = (hw.get("gpus") or [{}])[0]
                eng = m.get("engine") or {}
                live = m.get("live") or {}
                slots = live.get("slots") or {}
                tot = m.get("totals") or {}
                fh.write(json.dumps({
                    "kind": "sample",
                    "t": now,
                    "state": live.get("state"),
                    "active": slots.get("active"),
                    "total_slots": slots.get("total"),
                    "queue": slots.get("queue_depth"),
                    "tok_s": live.get("tok_s"),
                    "prefill_tok_s": live.get("prefill_tok_s_mean"),
                    "gen": live.get("generated"),
                    "prompt": live.get("prompt_tokens"),
                    "written": tot.get("written"),
                    "decode_ms": tot.get("decode_ms"),
                    "tot_prompt": tot.get("prompt"),
                    "tot_reused": tot.get("reused"),
                    "tot_requests": tot.get("requests"),
                    "vram_used": gpu.get("mem_used"),
                    "vram_total": gpu.get("mem_total"),
                    "vram_free_mib": eng.get("vram_free_mib"),
                    "util": gpu.get("util"),
                    "temp": gpu.get("temp"),
                    "power": gpu.get("power"),
                    "ram_used": hw.get("ram_used"),
                    "ram_total": hw.get("ram_total"),
                    "pcie_gen": gpu.get("pcie_gen"),
                    "kv_resident": eng.get("kv_resident"),
                    "batch_slots": eng.get("batch_slots"),
                }) + "\n")
                samples += 1

                for r in m.get("requests") or []:
                    rid = r.get("id")
                    if not rid or rid in seen:
                        continue
                    seen.add(rid)
                    # The engine keeps a ring buffer of finished requests, so the
                    # first scrape would log work that happened before the window
                    # even opened. Seed the set and emit nothing on that pass.
                    if not seeded:
                        continue
                    entry = {k: r.get(k) for k in FIELDS}
                    entry.update(kind="req", t=now)
                    fh.write(json.dumps(entry) + "\n")
                    requests += 1
                seeded = True
            fh.flush()
            if not quiet and samples % 30 == 0:
                print(f"  {int(time.time() - started)}s: {samples} samples, {requests} requests, {misses} misses", flush=True)
            time.sleep(interval)
    return {"path": path, "samples": samples, "requests": requests, "misses": misses}


def pct(vals, p):
    if not vals:
        return None
    vals = sorted(vals)
    k = (len(vals) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def med(vals):
    return statistics.median(vals) if vals else None


def f(v, nd=1, unit=""):
    if v is None:
        return "—"
    return f"{v:,.{nd}f}{unit}" if isinstance(v, float) else f"{v:,}{unit}"


def report(path):
    samples, reqs = [], []
    misses = 0
    with open(path) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("kind") == "sample":
                samples.append(rec)
            elif rec.get("kind") == "req":
                reqs.append(rec)
            elif rec.get("kind") == "miss":
                misses += 1

    if not samples:
        print("no samples in that file")
        return

    span = samples[-1]["t"] - samples[0]["t"]
    active = [s.get("active") or 0 for s in samples]
    queue = [s.get("queue") or 0 for s in samples]
    live_rates = [s["tok_s"] for s in samples if s.get("tok_s")]
    vram = [s["vram_used"] / 2**30 for s in samples if s.get("vram_used")]
    free = [s["vram_free_mib"] / 1024 for s in samples if s.get("vram_free_mib") is not None]
    temps = [s["temp"] for s in samples if s.get("temp") is not None]
    pwr = [s["power"] for s in samples if s.get("power")]
    util = [s["util"] for s in samples if s.get("util") is not None]
    ram = [s["ram_used"] / 2**30 for s in samples if s.get("ram_used")]
    vtot = (samples[-1].get("vram_total") or 0) / 2**30
    rtot = (samples[-1].get("ram_total") or 0) / 2**30

    busy = sum(1 for a in active if a > 0)
    conc = {}
    for a in active:
        conc[a] = conc.get(a, 0) + 1

    print(f"\nwindow {span/60:.1f} min · {len(samples)} samples every "
          f"{span/max(len(samples)-1,1):.1f}s" + (f" · {misses} failed scrapes" if misses else ""))
    print(f"GPU   temp {f(med(temps),0,'°C')} (max {f(max(temps) if temps else None,0,'°C')}) · "
          f"power {f(med(pwr),0,'W')} (max {f(max(pwr) if pwr else None,0,'W')}) · "
          f"util {f(med(util),0,'%')}")
    print(f"VRAM  {f(med(vram))} GiB of {f(vtot)} · peak {f(max(vram) if vram else None)} · "
          f"min free {f(min(free) if free else None)} GiB")
    print(f"RAM   {f(med(ram))} GiB of {f(rtot)}")

    print(f"\nUSE   busy {busy/max(len(samples),1)*100:.0f}% of samples · "
          f"concurrency histogram " + " ".join(f"{k}:{v}" for k, v in sorted(conc.items())))
    print(f"      queue peak {max(queue) if queue else 0} · "
          f"queued {sum(1 for q in queue if q > 0)/max(len(samples),1)*100:.0f}% of the time")

    if live_rates:
        print(f"RATE  engine live tok/s: median {f(med(live_rates))} · "
              f"p90 {f(pct(live_rates,0.9))} · peak {f(max(live_rates))}")

    if not reqs:
        print("\nno completed requests in the window")
        return

    out = [r["output_tokens"] or 0 for r in reqs]
    prompt = [r["prompt_tokens"] or 0 for r in reqs]
    reused = [r["reused"] or 0 for r in reqs]
    rates = [r["decode_tok_s"] for r in reqs if r.get("decode_tok_s")]
    ttfts = [r["ttft_s"] for r in reqs if r.get("ttft_s") is not None]
    durs = [r["duration_s"] for r in reqs if r.get("duration_s")]
    d_off = sum(r.get("drafts_offered") or 0 for r in reqs)
    d_acc = sum(r.get("drafts_accepted") or 0 for r in reqs)
    slots = {}
    for r in reqs:
        slots[r.get("slot")] = slots.get(r.get("slot"), 0) + 1
    finishes = {}
    for r in reqs:
        finishes[r.get("finish")] = finishes.get(r.get("finish"), 0) + 1

    t0 = min(r["time"] for r in reqs if r.get("time"))
    t1 = max((r["time"] or 0) + (r.get("duration_s") or 0) for r in reqs)
    wall = max(t1 - t0, 1e-9)

    print(f"\nREQUESTS {len(reqs)} completed · {f(sum(out),0)} output tokens · "
          f"{f(sum(prompt),0)} prompt tokens")
    print(f"  prompt  median {f(med(prompt),0)} · p90 {f(pct(prompt,0.9),0)} · max {f(max(prompt),0)}"
          f" · prefix reuse {sum(reused)/max(sum(prompt),1)*100:.0f}%")
    print(f"  output  median {f(med(out),0)} · p90 {f(pct(out,0.9),0)} · max {f(max(out),0)}")
    print(f"  decode  median {f(med(rates))} tok/s · p10 {f(pct(rates,0.1))} · "
          f"p90 {f(pct(rates,0.9))} · min {f(min(rates) if rates else None)}")
    print(f"  TTFT    median {f(med(ttfts),2,'s')} · p90 {f(pct(ttfts,0.9),2,'s')} · "
          f"max {f(max(ttfts) if ttfts else None,2,'s')}")
    print(f"  drafts  {d_acc}/{d_off} accepted ({d_acc/max(d_off,1)*100:.0f}%)")
    print(f"  realized {f(sum(out)/max(sum(durs),1e-9))} tok/s per request-slot-second · "
          f"{f(sum(out)/wall)} tok/s over the wall window")
    print(f"  slots   " + " ".join(f"s{k}:{v}" for k, v in sorted(slots.items(), key=lambda kv: str(kv[0]))))
    print(f"  finish  " + " ".join(f"{k}:{v}" for k, v in sorted(finishes.items(), key=lambda kv: str(kv[0]))))

    slow = sorted((r for r in reqs if r.get("decode_tok_s")), key=lambda r: r["decode_tok_s"])[:3]
    if slow:
        print("  slowest " + " · ".join(
            f"r{r['id']} {r['decode_tok_s']:.0f}/s (out {r.get('output_tokens')}, "
            f"prompt {r.get('prompt_tokens')}, slot {r.get('slot')})" for r in slow))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:6969")
    ap.add_argument("--minutes", type=float, default=10)
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--jsonl", help="capture path (default sessions/watch-<stamp>.jsonl)")
    ap.add_argument("--report", help="report on an existing capture instead of recording")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.report:
        report(args.report)
        return 0

    os.makedirs(OUTDIR, exist_ok=True)
    # Retention: captures are diagnostic evidence, not a log to keep forever.
    # Keep the newest KEEP files so a habit of 10-minute recordings cannot fill
    # the disk; each one is a couple hundred KB.
    KEEP = 20
    old = sorted(
        (os.path.join(OUTDIR, f) for f in os.listdir(OUTDIR) if f.endswith(".jsonl")),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    )
    for stale in old[KEEP:]:
        try:
            os.remove(stale)
        except OSError:
            pass

    path = args.jsonl or os.path.join(OUTDIR, time.strftime("watch-%Y%m%d-%H%M%S.jsonl"))
    print(f"recording {args.minutes:.0f} min from {args.url} → {path}")
    info = record(args.url, args.minutes, args.interval, path, args.quiet)
    print(f"captured {info['samples']} samples / {info['requests']} requests / {info['misses']} misses")
    report(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
