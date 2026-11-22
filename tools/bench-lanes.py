#!/usr/bin/env python3
"""Measure per-lane and cumulative decode speed on an OpenAI-style endpoint.

Why client-side: the engine's own counters are completion-batched and its
`live.tok_s` is a whole-server number. Neither tells you what one conversation
gets. This drives N streaming requests at once, times each lane from its first
token to its last, and reports both the per-lane rate and the sum.

Stdlib only, so it runs anywhere the server does.

  ./bench-lanes.py                      # lanes 1,2,4 · 128 tokens each
  ./bench-lanes.py --lanes 1,2,3,4,6 --tokens 256 --runs 3
  ./bench-lanes.py --lanes 4 --url http://127.0.0.1:6969 --json out.json

Each request carries a distinct session header, so Basalt's session affinity
pins each lane to its own slot instead of piling them onto one. Slots the
engine lacks show up as queue_depth in the sampler output, so a run that
queued is not silently reported as concurrent.
"""

import argparse
import json
import statistics
import sys
import threading
import time
import urllib.request

# A prompt that reads like real work but stays cheap to prefill: prefill is
# measured separately (TTFT), and a long prompt would drown the decode signal.
PROMPT = (
    "Write a technical explanation of how a mixture-of-experts transformer "
    "routes tokens to experts. Cover the router, top-k selection, load "
    "balancing, and what happens to expert weights that live outside VRAM. "
    "Be concrete and continuous: do not use headings, lists, or bullet points, "
    "and do not stop until you reach the length limit."
)


def stream_one(url, model, session, max_tokens, temperature, timeout, out):
    """One streaming request. Records first-token time, last-token time, tokens."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
        "temperature": temperature,
    }).encode()

    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-session-id": session,          # slot affinity, not a suggestion
            "Accept": "text/event-stream",
        },
        method="POST",
    )

    t0 = time.perf_counter()
    t_first = None
    chunks = 0
    usage_tokens = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.strip()
                if not line.startswith(b"data:"):
                    continue
                payload = line[5:].strip()
                if payload == b"[DONE]":
                    break
                try:
                    event = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                if event.get("usage"):
                    usage_tokens = event["usage"].get("completion_tokens")
                for choice in event.get("choices") or []:
                    delta = choice.get("delta") or {}
                    # Reasoning models stream the thinking in reasoning_content
                    # before any answer text. Counting only content would set
                    # TTFT after the thinking and then divide by a span that
                    # excludes it, inflating the rate.
                    if delta.get("content") or delta.get("reasoning_content"):
                        if t_first is None:
                            t_first = time.perf_counter()
                        chunks += 1
    except Exception as exc:                       # noqa: BLE001 - reported, not raised
        out.update(ok=False, error=f"{type(exc).__name__}: {exc}")
        return

    t_end = time.perf_counter()
    tokens = usage_tokens or chunks
    decode_span = (t_end - t_first) if t_first else 0.0
    out.update(
        ok=True,
        ttft_s=(t_first - t0) if t_first else None,
        total_s=t_end - t0,
        tokens=tokens,
        chunks=chunks,
        # (tokens-1): the first token costs prefill, not decode. With a usage
        # count the last chunk lands before the stream closes, so the span is
        # an upper bound; with chunk counting it is exact.
        tok_s=((tokens - 1) / decode_span) if decode_span > 0 and tokens > 1 else None,
    )


def sample_metrics(url, stop, peak):
    """Poll /metrics during the run: what the engine thinks is happening."""
    endpoint = url.rstrip("/") + "/metrics"
    while not stop.is_set():
        try:
            with urllib.request.urlopen(endpoint, timeout=2) as resp:
                m = json.loads(resp.read())
            live = m.get("live") or {}
            slots = live.get("slots") or {}
            active = slots.get("active") or 0
            peak["active"] = max(peak.get("active", 0), active)
            peak["queue"] = max(peak.get("queue", 0), slots.get("queue_depth") or 0)
            peak["total_slots"] = slots.get("total") or peak.get("total_slots")
            if live.get("tok_s"):
                peak["tok_s"] = max(peak.get("tok_s") or 0, float(live["tok_s"]))
        except Exception:                          # noqa: BLE001 - sampling is best effort
            pass
        stop.wait(0.2)


def engine_totals(url):
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/metrics", timeout=3) as resp:
            totals = (json.loads(resp.read()).get("totals") or {})
        return totals.get("written") or 0, totals.get("decode_ms") or 0
    except Exception:                              # noqa: BLE001
        return None, None


def run_batch(url, model, lanes, tokens, temperature, timeout, metrics):
    results = [dict(lane=i + 1) for i in range(lanes)]
    stamp = int(time.time() * 1000)

    stop = threading.Event()
    peak = {}
    sampler = None
    if metrics:
        sampler = threading.Thread(target=sample_metrics, args=(url, stop, peak), daemon=True)
        sampler.start()

    w0, d0 = engine_totals(url) if metrics else (None, None)
    wall0 = time.perf_counter()

    threads = [
        threading.Thread(
            target=stream_one,
            args=(url, model, f"bench-{stamp}-{i}", tokens, temperature, timeout, results[i]),
            daemon=True,
        )
        for i in range(lanes)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    wall = time.perf_counter() - wall0
    stop.set()
    if sampler:
        sampler.join(timeout=3)
    w1, d1 = engine_totals(url) if metrics else (None, None)

    ok = [r for r in results if r.get("ok")]
    rates = [r["tok_s"] for r in ok if r.get("tok_s")]
    total_tokens = sum(r.get("tokens") or 0 for r in ok)

    summary = {
        "lanes": lanes,
        "ok": len(ok),
        "failed": len(results) - len(ok),
        "per_lane_tok_s": rates,
        "lane_mean": statistics.mean(rates) if rates else None,
        "lane_min": min(rates) if rates else None,
        "lane_max": max(rates) if rates else None,
        "cumulative_tok_s": sum(rates) if rates else None,
        "wall_s": wall,
        "wall_tok_s": (total_tokens / wall) if wall > 0 else None,
        "ttft_s": [r["ttft_s"] for r in ok if r.get("ttft_s")],
        "tokens": total_tokens,
        "engine_peak_live_tok_s": peak.get("tok_s"),
        "engine_peak_active": peak.get("active"),
        "engine_peak_queue": peak.get("queue"),
        "engine_slots": peak.get("total_slots"),
        "engine_tok_s_check": ((w1 - w0) / (d1 - d0) * 1000.0)
        if (w0 is not None and w1 is not None and d1 and d0 is not None and d1 > d0) else None,
        "requests": results,
    }
    return summary


def fmt(v, nd=1):
    return "—" if v is None else (f"{v:.{nd}f}" if isinstance(v, float) else str(v))


def main():
    ap = argparse.ArgumentParser(description="Per-lane and cumulative decode speed")
    ap.add_argument("--url", default="http://127.0.0.1:6969")
    ap.add_argument("--model", default="ALLMIND")
    ap.add_argument("--lanes", default="1,2,4", help="comma-separated lane counts")
    ap.add_argument("--tokens", type=int, default=128, help="max output tokens per lane")
    ap.add_argument("--temperature", type=float, default=0.7)
    ap.add_argument("--runs", type=int, default=1, help="runs per lane count (median reported)")
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--no-metrics", action="store_true", help="skip /metrics sampling")
    ap.add_argument("--json", help="write the raw results here")
    args = ap.parse_args()

    lane_counts = [int(x) for x in args.lanes.split(",") if x.strip()]
    print(f"target {args.url}  model {args.model}  tokens/lane {args.tokens}  temp {args.temperature}")
    print(f"{'lanes':>5}  {'per-lane tok/s':>22}  {'cumulative':>10}  {'wall':>8}  {'ttft s':>7}  {'peak act/queue/slots':>20}")
    print("-" * 84)

    all_runs = []
    for lanes in lane_counts:
        summaries = []
        for _ in range(args.runs):
            summaries.append(run_batch(
                args.url, args.model, lanes, args.tokens,
                args.temperature, args.timeout, not args.no_metrics,
            ))
        all_runs.extend(summaries)

        def med(key):
            vals = [s[key] for s in summaries if s.get(key) is not None]
            return statistics.median(vals) if vals else None

        rates = [r for s in summaries for r in s["per_lane_tok_s"]]
        lane_txt = f"mean {fmt(med('lane_mean'))} min {fmt(min(rates) if rates else None)} max {fmt(max(rates) if rates else None)}"
        ttfts = [t for s in summaries for t in s["ttft_s"]]
        peak_txt = (f"{fmt(med('engine_peak_active'))}/{fmt(med('engine_peak_queue'))}"
                    f"/{fmt(med('engine_slots'))}")
        print(f"{lanes:>5}  {lane_txt:>22}  {fmt(med('cumulative_tok_s')):>10}  "
              f"{fmt(med('wall_s'), 2):>8}  {fmt(statistics.median(ttfts) if ttfts else None, 2):>7}  {peak_txt:>20}")

        if summaries[0]["failed"]:
            for s in summaries:
                for r in s["requests"]:
                    if not r.get("ok"):
                        print(f"        lane {r['lane']}: {r.get('error')}")

    # A run that queued is not a concurrency measurement: say so plainly.
    for s in all_runs:
        if s["engine_peak_queue"]:
            print(f"\nWARNING: lanes={s['lanes']} hit queue_depth={s['engine_peak_queue']} — "
                  f"the engine served fewer lanes at once than were asked for.")
            break

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(all_runs, fh, indent=2)
        print(f"\nraw results: {args.json}")


if __name__ == "__main__":
    sys.exit(main())
