#!/usr/bin/env bash
# Runtime semantics for whatever serves :6969, in ONE place.
#
# Two consumers used to know this independently -- monitor.sh (bash, for the
# widget) and cardmode.py (python, for drain/identity gates) -- and each had
# rediscovered the same failure modes: a scrape that fails must never read as
# "nothing in flight", a loading engine must never read as "ready", and every
# runtime reports those two facts in a different shape. That duplication is
# what this file removes: the shapes live here, the policy stays with the
# consumer (monitor fails OPEN for display, cardmode fails CLOSED for
# transitions).
#
#   probe.sh label  <backend>
#   probe.sh health <backend> <base>                  -> ok | loading | down
#   probe.sh counts <backend> <base> [metrics_body]   -> "<active> <deferred>" | nothing
#   probe.sh ready  <backend> <base> [n_parallel]     -> yes | no
#
# "counts" prints NOTHING when the scrape fails or the body does not parse: the
# caller decides what unknown means. "ready" is identity, not liveness -- every
# branch demands the ALLMIND id, so an orphan or a half-booted engine cannot
# satisfy it (the 2026-10-16 zombie answered /v1/models with ALLMIND while
# holding the card).
#
# Backends: sglang (prometheus text), basalt (JSON), llama/gufo (prometheus
# text under llamacpp: names). Anything unrecognised falls back to the
# llamacpp: shape, which is what a hand-picked GGUF build serves.
set -u

BASE_DEFAULT="http://127.0.0.1:6969"

probe_label() {
  case "${1,,}" in
    sglang) printf 'SGLang' ;;
    gufo)   printf 'Gufo' ;;
    basalt) printf 'Basalt' ;;
    *)      printf 'llama.cpp' ;;
  esac
}

probe_health() {
  local backend="${1,,}" base="${2:-$BASE_DEFAULT}" code body
  case "$backend" in
    sglang)
      # 200 with an EMPTY body; 503 while a model loads.
      code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$base/health" 2>/dev/null || echo 000)
      [[ "$code" == "200" ]] && printf 'ok' || printf 'down'
      ;;
    basalt)
      # Binds its HTTP server BEFORE the pack loads: 200 with
      # {"loaded": false} for the whole load. Trusting the status code alone
      # paints the bar green over an engine that cannot answer yet.
      body=$(curl -sf -m 2 "$base/health" 2>/dev/null || true)
      if [[ -z "$body" ]]; then
        printf 'down'
      elif grep -q '"loaded": *true' <<<"$body"; then
        printf 'ok'
      else
        printf 'loading'
      fi
      ;;
    *)
      if curl -sf -m 2 "$base/health" 2>/dev/null | grep -q '"ok"'; then
        printf 'ok'
      else
        printf 'down'
      fi
      ;;
  esac
}

probe_counts() {
  local backend="${1,,}" base="${2:-$BASE_DEFAULT}" body="${3:-}"
  if [[ -z "$body" ]]; then
    body=$(curl -sf -m 3 "$base/metrics" 2>/dev/null) || return 0
  fi
  [[ -n "$body" ]] || return 0
  case "$backend" in
    sglang)
      # Verbose labels and one series per is_streaming value: SUM every line.
      # `seen` is the fail-open guard: a page or a proxy error that answers 200
      # must yield NOTHING, not "0 0" -- zero reads as idle and a drain check
      # would stop a server mid-generation.
      awk '/^sglang:num_running_reqs\{/{r+=$NF; seen=1}
           /^sglang:num_queue_reqs\{/{q+=$NF; seen=1}
           END{ if (seen) printf "%.0f %.0f", r+0, q+0 }' <<<"$body"
      ;;
    basalt)
      jq -r 'if (.live.slots // null) == null then empty
             else [(.live.slots.active // 0),
                   (.live.slots.queue_depth // .live.queued // 0)] | @tsv
             end' <<<"$body" 2>/dev/null || true
      ;;
    *)
      awk '/^llamacpp:requests_processing /{a=$2; seen=1}
           /^llamacpp:requests_deferred /{d=$2; seen=1}
           END{ if (seen) printf "%.0f %.0f", a+0, d+0 }' <<<"$body"
      ;;
  esac
}

# ready_of <backend> <base> [n_parallel] -- identity of the shape, not liveness.
probe_ready() {
  local backend="${1,,}" base="${2:-$BASE_DEFAULT}" want="${3:-}" body models
  case "$backend" in
    sglang)
      body=$(curl -sf -m 3 "$base/metrics" 2>/dev/null) || { printf 'no'; return; }
      grep -q '^sglang:' <<<"$body" && printf 'yes' || printf 'no'
      ;;
    basalt)
      body=$(curl -sf -m 3 "$base/health" 2>/dev/null) || { printf 'no'; return; }
      if ! grep -q '"model": *"ALLMIND"' <<<"$body" || ! grep -q '"loaded": *true' <<<"$body"; then
        printf 'no'
        return
      fi
      models=$(curl -sf -m 3 "$base/v1/models" 2>/dev/null) || { printf 'no'; return; }
      grep -q 'ALLMIND' <<<"$models" || { printf 'no'; return; }
      if [[ -n "$want" ]]; then
        # Every basalt shape serves as ALLMIND, so the id proves nothing about
        # WHICH pack holds the card. The preset's lane count does: /metrics
        # reports engine.batch_slots exactly as configured at boot. Without
        # this, ready_for(gen) answers yes for an llm boot and vice versa --
        # the same double-identity hole the llama branch closes with
        # /props total_slots.
        local slots
        slots=$(curl -sf -m 3 "$base/metrics" 2>/dev/null | jq -r '.engine.batch_slots // empty' 2>/dev/null || true)
        [[ -n "$slots" && "$slots" == "$want" ]] && printf 'yes' || printf 'no'
        return
      fi
      printf 'yes'
      ;;
    *)
      body=$(curl -sf -m 3 "$base/metrics" 2>/dev/null) || { printf 'no'; return; }
      grep -q '^llamacpp:' <<<"$body" || { printf 'no'; return; }
      models=$(curl -sf -m 3 "$base/v1/models" 2>/dev/null) || { printf 'no'; return; }
      grep -q 'ALLMIND' <<<"$models" || { printf 'no'; return; }
      if [[ -n "$want" ]]; then
        # One llama.cpp build serves both 27B shapes, so the metric family
        # cannot tell them apart: the preset's lane count is the identity.
        local slots
        slots=$(curl -sf -m 3 "$base/props" 2>/dev/null | jq -r '.total_slots // empty' 2>/dev/null || true)
        [[ -n "$slots" && "$slots" == "$want" ]] && printf 'yes' || printf 'no'
        return
      fi
      printf 'yes'
      ;;
  esac
}

# Dispatch only when EXECUTED. monitor.sh sources this file for the functions,
# and an unguarded case would run with monitor's (absent) $1 and exit 2.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    label)  probe_label "${2:-}" ;;
    health) probe_health "${2:-}" "${3:-$BASE_DEFAULT}" ;;
    counts) probe_counts "${2:-}" "${3:-$BASE_DEFAULT}" "${4:-}" ;;
    ready)  probe_ready "${2:-}" "${3:-$BASE_DEFAULT}" "${4:-}" ;;
    *)
      printf 'usage: probe.sh {label <backend> | health <backend> <base> | counts <backend> <base> [body] | ready <backend> <base> [n_parallel]}\n' >&2
      exit 2
      ;;
  esac
  printf '\n'
fi
