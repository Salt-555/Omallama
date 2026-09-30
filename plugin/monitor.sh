#!/usr/bin/env bash
# Poll the llama.cpp server (port 6969) + GPU VRAM for the omarchy widget.
# Emits key=value lines consumed by BarWidget.qml.
#
# --- what /metrics actually gives you (measured on this box, llama-server) ----
# llama-server batches its token counters at REQUEST COMPLETION, not live:
#   prompt_tokens_total, prompt_seconds_total, tokens_predicted_total,
#   tokens_predicted_seconds_total, spec_decode_* all advance in ONE step the
#   moment a request finishes. Measured here: a 41 s prefill of 18196 prompt
#   tokens and a 13.5 s decode of 500 tokens each looked completely idle to
#   those counters until the instant they ended. Classifying "is it generating"
#   off a predicted-token delta therefore reports idle for the entire duration
#   of every request — that was the bug in the previous version of this file.
#
# Only two things move live:
#   requests_processing   >0 while a request is in flight; flips within ~1 s of
#                         the request arriving and stays 1 through prefill.
#                         requests_deferred covers a queued request awaiting a
#                         slot: busy on the encoding side of the line.
#   n_decode_total        +1 per scheduler decode() iteration.
# The RATE of n_decode_total separates the two kinds of work, because decode()
# is called differently in each phase (measured with -ub 2048, MTP on):
#   prefill/encoding  -> one call per ub-sized chunk: 9 iterations for 18196
#                        tokens = ~0.2/s
#   decode/generating -> one call per token/draft: ~5-21/s
# That ~50-80x gap is the classifier. Idle bookkeeping ticks n_decode_total at
# ~0.4/s; it never coincides with requests_processing > 0, and a prefill is
# never mislabeled decoding because the previous phase entering a request is
# idle/encoding, not decoding.
#
# Consequence for the UI: a LIVE tok/s does not exist. tok/s is a per-completed
# run number, measured from the completion-batched predicted counters over the
# run window that begins at the last known-idle anchor.
#
# --- state (all scoped to ONE server session) ---------------------------------
# The counters reset with the process, so any snapshot older than the current
# process is meaningless arithmetic. A poll with no state seeds from the live
# counters instead of reading a missing baseline as 0 (which would mistake a
# whole session's counters for one enormous generation).
#   .pollstate   last poll: "<pred> <psec> <ndec> <busy> <phase> <epoch>"
#   .runanchor   baseline of the current measurement window: "<pred> <psec>"
#                re-anchored whenever a run is committed or the server is idle,
#                so each tok/s belongs to one run instead of accumulating drift
#   .last_tps    tok/s of the last completed run
# Polls serialize on .monitor.lock: two bar surfaces (one per monitor) host the
# widget and poll independently; unguarded read-modify-write lets one poller
# consume the other's baseline and reclassify against a stale snapshot.
set -u

BASE="${LLAMA_BASE_URL:-http://127.0.0.1:6969}"
CFG="${LLAMA_CFG_DIR:-$HOME/.config/llama-server}"
STATE="$CFG/.pollstate"
ANCHOR="$CFG/.runanchor"
LASTTPS="$CFG/.last_tps"
LASTENC="$CFG/.last_tps_enc"
LASTTTFT="$CFG/.last_ttft"

mkdir -p "$CFG" 2>/dev/null || true
exec 9>"$CFG/.monitor.lock" && flock -w 5 9 || true

# fcmp A B OP -> float comparison. $(( )) cannot parse these values: they are
# floats and print in scientific notation once large (e.g. 1.61136e+06), which
# under set -u aborts the whole poll.
fcmp() { awk -v a="$1" -v b="$2" -v op="$3" \
  'BEGIN{ if(op=="<") exit !(a<b); if(op=="<=") exit !(a<=b); if(op==">") exit !(a>b); if(op==">=") exit !(a>=b); exit 1 }'; }

# --- server up/down: health (can it serve) vs unit state (is it running) ------
# During a model load the unit is active while /health is not ok yet; the
# widget needs both to show "loading" and to keep Stop/Restart reachable.
st="down"
if curl -sf --max-time 2 "$BASE/health" 2>/dev/null | grep -q '"ok"'; then
  st="ok"
fi
unit_state=$(systemctl --user is-active llama-server.service 2>/dev/null || true)
[[ "$unit_state" == "active" ]] || unit_state="inactive"

pred=0; psec=0; ndec=0; proc=0; defer=0; prom=0; promsec=0
if [[ "$st" == "ok" ]]; then
  metrics=$(curl -sf --max-time 2 "$BASE/metrics" 2>/dev/null)
  pred=$(awk '/^llamacpp:tokens_predicted_total /{print $2; exit}' <<<"$metrics")
  psec=$(awk '/^llamacpp:tokens_predicted_seconds_total /{print $2; exit}' <<<"$metrics")
  ndec=$(awk '/^llamacpp:n_decode_total /{print $2; exit}' <<<"$metrics")
  proc=$(awk '/^llamacpp:requests_processing /{print $2; exit}' <<<"$metrics")
  defer=$(awk '/^llamacpp:requests_deferred /{print $2; exit}' <<<"$metrics")
  prom=$(awk '/^llamacpp:prompt_tokens_total /{print $2; exit}' <<<"$metrics")
  promsec=$(awk '/^llamacpp:prompt_seconds_total /{print $2; exit}' <<<"$metrics")
  pred=${pred:-0}; psec=${psec:-0}; ndec=${ndec:-0}; proc=${proc:-0}; defer=${defer:-0}
  prom=${prom:-0}; promsec=${promsec:-0}
fi

# Gufo (serve-gufo.sh) serves /metrics under llamacpp: names but only exposes
# completion-batched token counters plus the latest speed gauges: no
# n_decode_total and no live request counters. Detect the shape and use its
# own signals (journal request events) in the branch below.
GUFO=0
if [[ "$st" == "ok" ]] && ! grep -q '^llamacpp:n_decode_total ' <<<"${metrics:-}"; then
  GUFO=1
fi

busy=0
if fcmp "$proc" 0 ">" || fcmp "$defer" 0 ">"; then busy=1; fi

now=$(date +%s)
activity="idle"
commit=0

if [[ "$GUFO" == 1 ]]; then
  # Gufo profile: its counters only move at request completion, but its journal
  # logs one received/completed event per request and a measured decode_tps on
  # completion. Scope counts to this service invocation so a restart cannot
  # leak a half-open request into the next session.
  invid=$(systemctl --user show -p InvocationID --value llama-server.service 2>/dev/null || true)
  jl=""
  if [[ -n "$invid" ]]; then
    jl=$(journalctl --user -u llama-server.service "_SYSTEMD_INVOCATION_ID=$invid" -n 400 --no-pager -o cat 2>/dev/null || true)
  fi
  nrecv=$(grep -c 'event=received .*path=/v1/chat/completions' <<<"$jl" || true)
  ncomp=$(grep -c 'event=completed .*path=/v1/chat/completions' <<<"$jl" || true)
  proc=$(( ${nrecv:-0} - ${ncomp:-0} ))
  [[ "$proc" -lt 0 ]] && proc=0
  busy=0
  if [[ "$proc" -gt 0 ]]; then busy=1; fi
  # Queue accounting: gufo exports no requests_deferred, but its admission
  # model is exact for this split — at most <sessions> requests run (bounded
  # executor pool, SERVER.md), the rest wait in kQueued. Split the
  # journal-derived inflight count accordingly. llama.cpp reports both
  # natively through the metrics path above.
  sess=$(awk -F= '/^sessions=/{print $2; exit}' "$CFG/.gufo_runtime" 2>/dev/null || true)
  sess=${sess:-1}
  defer=0
  if [[ "$proc" -gt "$sess" ]]; then
    defer=$((proc - sess))
    proc=$sess
  fi
  # Live phase from gufo's --log-progress events: the latest phase= field names
  # prefill or decode per in-flight request. No progress line yet means the
  # request just landed — prefill always comes first, so "encoding" is the
  # honest default until the first chunk logs.
  activity="idle"
  if [[ "$busy" == 1 ]]; then
    ph=$(grep -o 'phase=[a-z]*' <<<"$jl" | tail -1 | cut -d= -f2 || true)
    case "$ph" in
      decode) activity="decoding" ;;
      *)      activity="encoding" ;;
    esac
  fi
  lastc=$(grep 'event=completed .*path=/v1/chat/completions' <<<"$jl" | tail -1 || true)
  dt=$(grep -o 'decode_tps=[0-9.]*' <<<"$lastc" | head -1 | cut -d= -f2 || true)
  et=$(grep -o 'prefill_tps=[0-9.]*' <<<"$lastc" | head -1 | cut -d= -f2 || true)
  tt=$(grep -o 'ttft_ms=[0-9.]*' <<<"$lastc" | head -1 | cut -d= -f2 || true)
  # Decode stays the headline number (the bar shows only it); encode and TTFT
  # feed the panel's last-run rows. Gufo logs all three measured per request.
  if [[ -n "$dt" ]]; then printf '%s\n' "$dt" > "$LASTTPS"; else rm -f "$LASTTPS"; fi
  if [[ -n "$et" ]]; then printf '%s\n' "$et" > "$LASTENC"; else rm -f "$LASTENC"; fi
  if [[ -n "$tt" ]]; then printf '%s\n' "$tt" > "$LASTTTFT"; else rm -f "$LASTTTFT"; fi
  # The llama.cpp run-window state is meaningless here; keep it cleared so a
  # later switch back to a llama.cpp backend starts from a clean baseline.
  rm -f "$STATE" "$ANCHOR" "$CFG/.genstate" "$CFG/.genanchor" 2>/dev/null || true
elif [[ "$st" != "ok" ]]; then
  # A stopped server has no valid baseline and no last run worth showing: drop
  # the state so a restart cannot compare across process boundaries or display
  # a dead session's speed. (.last_tps is still emitted, empty, so the widget
  # clears its readout instead of keeping the stale number.)
  rm -f "$STATE" "$ANCHOR" "$LASTTPS" "$LASTENC" "$LASTTTFT" "$CFG/.genstate" "$CFG/.genanchor"
else
  if [[ ! -f "$STATE" ]]; then
    # First poll of a server session: the counters belong to the process that
    # just started, so they are a baseline, not evidence of an in-flight run.
    # If the server is already busy we cannot classify the phase yet —
    # encoding is the honest label until the n_decode rate is observable on
    # the next poll.
    if [[ "$busy" == 1 ]]; then activity="encoding"; fi
    printf '%s %s %s %s %s %s\n' "$pred" "$psec" "$ndec" "$busy" "$activity" "$now" > "$STATE"
    printf '%s %s %s %s\n' "$pred" "$psec" "$prom" "$promsec" > "$ANCHOR"
  else
    read -r p_pred p_psec p_ndec p_busy p_phase p_ts <<< "$(cat "$STATE" 2>/dev/null || echo '0 0 0 0 idle 0')"
    read -r a_pred a_psec a_prom a_promsec <<< "$(cat "$ANCHOR" 2>/dev/null || echo "$pred $psec $prom $promsec")"
    a_pred=${a_pred:-$pred}; a_psec=${a_psec:-$psec}
    a_prom=${a_prom:-$prom}; a_promsec=${a_promsec:-$promsec}

    # Poll spacing varies (two pollers share the state, timers drift), so the
    # classifier is a rate over the real gap, floored so a near-zero gap
    # cannot fabricate a huge rate.
    dt=$(awk -v a="$now" -v b="$p_ts" 'BEGIN{ d=a-b; if(d<0.25) d=0.25; printf "%.3f", d }')
    drate=$(awk -v a="$ndec" -v b="$p_ndec" -v t="$dt" 'BEGIN{ printf "%.3f", (a-b)/t }')

    if [[ "$busy" == 1 ]]; then
      # 2.0 decode-iterations/s separates generating from chunked prefill.
      # Measured on this server: real generation bursts run 5-21/s (MTP),
      # prefill chunks ~0.2/s, and request arrival itself ticks once (BOS
      # decode) — which lands on the encoding side, as it should: the first
      # chunk has not finished yet. Hysteresis at 1.0/s keeps a genuinely
      # slow generation from flickering between labels mid-run.
      if fcmp "$drate" 2.0 ">=" || \
         { [[ "$p_phase" == "decoding" ]] && fcmp "$drate" 1.0 ">="; }; then
        activity="decoding"
      else
        activity="encoding"
      fi
    fi

    # Run boundary: an in-flight request ended (busy fell 1->0), or the
    # completion-batched predicted counter moved since the window anchor (a
    # run began and finished entirely between two polls).
    pred_moved=0
    fcmp "$pred" "$a_pred" ">" && pred_moved=1
    if { [[ "$p_busy" == 1 ]] && [[ "$busy" == 0 ]]; } || [[ "$pred_moved" == 1 ]]; then
      commit=1
    fi

    if [[ "$commit" == 1 ]]; then
      awk -v a="$pred" -v b="$a_pred" -v x="$psec" -v y="$a_psec" \
        'BEGIN{ dt=a-b; ds=x-y; if (dt>0 && ds>0.001) printf "%.1f\n", dt/ds }' > "$LASTTPS.tmp"
      if [[ -s "$LASTTPS.tmp" ]]; then mv "$LASTTPS.tmp" "$LASTTPS"; else rm -f "$LASTTPS.tmp"; fi
      # Encode (prefill) rate over the same window: prompt tokens / prompt
      # seconds, both completion-batched like the decode counters.
      awk -v a="$prom" -v b="$a_prom" -v x="$promsec" -v y="$a_promsec" \
        'BEGIN{ dt=a-b; ds=x-y; if (dt>0 && ds>0.001) printf "%.1f\n", dt/ds }' > "$LASTENC.tmp"
      if [[ -s "$LASTENC.tmp" ]]; then mv "$LASTENC.tmp" "$LASTENC"; else rm -f "$LASTENC.tmp"; fi
      # llama-server /metrics carries no time-to-first-token; leave the panel
      # cell empty rather than inventing one from prefill time.
      rm -f "$LASTTTFT"
    fi
    # Re-anchor whenever a run was measured or the server is idle, so the next
    # window starts from known-idle counters instead of inheriting a finished
    # run's tokens.
    if [[ "$commit" == 1 || "$busy" == 0 ]]; then
      printf '%s %s %s %s\n' "$pred" "$psec" "$prom" "$promsec" > "$ANCHOR"
    fi

    printf '%s %s %s %s %s %s\n' "$pred" "$psec" "$ndec" "$busy" "$activity" "$now" > "$STATE"
  fi
fi

last=$(cat "$LASTTPS" 2>/dev/null || true)

# --- active model from config --------------------------------------------------
model=$(jq -r '.model // empty' "$CFG/model.json" 2>/dev/null || true)
# Preset name, when the active model was set via a preset (see modelctl set).
name=$(jq -r '.name // empty' "$CFG/model.json" 2>/dev/null || true)

# --- backend actually serving --------------------------------------------------
# Truth from the running runtime when up (gufo's llamacpp: metric set lacks
# n_decode_total, see the GUFO probe above), else the configured backend from
# model.json so a loading or offline server still names the right runtime.
cfg_backend=$(jq -r '.backend // empty' "$CFG/model.json" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
backend="${cfg_backend:-llama}"
if [[ "$st" == "ok" ]]; then
  if [[ "$GUFO" == 1 ]]; then backend="gufo"; else backend="llama"; fi
fi

# --- GPU VRAM (Radeon 8060S) ---------------------------------------------------
# Take the first DRM card that reports VRAM rather than assuming card1.
vram=""; vtotal=""
for f in /sys/class/drm/card*/device/mem_info_vram_used; do
  if [[ -r "$f" ]]; then vram=$(cat "$f"); break; fi
done
for f in /sys/class/drm/card*/device/mem_info_vram_total; do
  if [[ -r "$f" ]]; then vtotal=$(cat "$f"); break; fi
done

printf 'status=%s\n' "$st"
printf 'service=%s\n' "$unit_state"
printf 'activity=%s\n' "$activity"
printf 'req_active=%s\n' "$proc"
printf 'req_deferred=%s\n' "$defer"
# Always emitted, empty when there is no completed run to report, so the widget
# has a single rule for "no value": absent means clear it.
printf 'tps_last=%s\n' "$last"
printf 'tps_enc=%s\n' "$(cat "$LASTENC" 2>/dev/null || true)"
printf 'ttft=%s\n' "$(cat "$LASTTTFT" 2>/dev/null || true)"
printf 'model=%s\n' "$model"
printf 'name=%s\n' "$name"
printf 'backend=%s\n' "$backend"
printf 'vram=%s\n' "${vram:-0}"
printf 'vram_total=%s\n' "${vtotal:-0}"
