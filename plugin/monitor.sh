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
# tok/W is a per-TURN number, and the turn is the whole request: encode + decode.
# It is generated tokens / joules, where joules is the integral of sampled power
# across the busy window -- so the prefill (encoding) cost is charged against the
# tokens it helped produce instead of being ignored. Power is read from the
# NVIDIA card when present, else the iGPU hwmon node. Each interval is a
# trapezoid (mean of its two endpoint samples) and the busy wall-clock span is
# accumulated with it, so AVGW is that integral over the SAME window -- not
# energy over the server's prefill+decode seconds, a different clock that read
# the average high.
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
TOKW="$CFG/.last_tokw"     # tokens/joule over the last completed turn
AVGW="$CFG/.last_avgw"     # average watts over the last completed turn
ENERGY="$CFG/.energy"      # "<joules> <busy_secs> <last_ts> <last_busy> <last_pwr>"
TANCHOR="$CFG/.turnanchor" # counters at the last idle: "<pred> <psec> <prom> <promsec>"

# Which runtime is configured, read once here because the health probe below
# differs per backend: SGLang answers /health with 200 and an EMPTY body.
cfg_backend=$(jq -r '.backend // empty' "$CFG/model.json" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)

# --- GPU power (watts) --------------------------------------------------------
# Prefer a discrete NVIDIA card when present (nvidia-smi), else the Strix Halo
# iGPU via its hwmon node. Prints watts, or nothing when unknown.
read_power() {
  local p="" f
  if command -v nvidia-smi >/dev/null 2>&1; then
    p=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    # power.draw comes back as [N/A] when the card is idle, in MIG, or blocked
    # by permissions; accept only a real number, else fall back to the iGPU.
    [[ "$p" =~ ^[0-9]+([.][0-9]+)?$ ]] || p=""
  fi
  if [[ -z "$p" ]]; then
    for f in /sys/class/drm/card*/device/hwmon/hwmon*/power1_average; do
      [[ -r "$f" ]] || continue
      p=$(awk '{printf "%.1f", $1/1000000}' "$f" 2>/dev/null)
      [[ -n "$p" ]] && break
    done
  fi
  printf '%s' "${p:-}"
}

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
if [[ "$cfg_backend" == "sglang" ]]; then
  # SGLang's /health is 200 with an EMPTY body, so the llama.cpp
  # `grep -q '"ok"'` test can never match it and the widget would read
  # "offline" forever. Gate on the status code: 503 while a model loads.
  _code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$BASE/health" 2>/dev/null || echo 000)
  [[ "$_code" == "200" ]] && st="ok"
elif curl -sf --max-time 2 "$BASE/health" 2>/dev/null | grep -q '"ok"'; then
  st="ok"
fi
unit_state=$(systemctl --user is-active llama-server.service 2>/dev/null || true)
[[ "$unit_state" == "active" ]] || unit_state="inactive"

# Instantaneous GPU power for this poll (also the raw sample fed to the peak
# tracker below).
pwr="$(read_power)"

pred=0; psec=0; ndec=0; proc=0; defer=0; prom=0; promsec=0
if [[ "$st" == "ok" ]]; then
  metrics=$(curl -sf --max-time 2 "$BASE/metrics" 2>/dev/null)
  if [[ "$cfg_backend" == "sglang" ]]; then
    # SGLang exposes sglang:* with verbose labels, so match on the family name
    # and take the last field. Values are floats (122.0, 15.198226951000834);
    # never feed them to $(( )) -- see the fcmp note above.
    # NB: counters SPLIT by the is_streaming label (measured 2026-10-15):
    # streaming clients (Hermes) land on a different series than plain curls.
    # A first-match 'print $NF; exit' read silently sees only one series --
    # the tok/s math then divides a near-empty counter. SUM all matching lines.
    pred=$(awk '/^sglang:generation_tokens_total\{/{s+=$NF} END{printf "%.1f", s+0}' <<<"$metrics")
    prom=$(awk '/^sglang:prompt_tokens_total\{/{s+=$NF} END{printf "%.1f", s+0}' <<<"$metrics")
    proc=$(awk '/^sglang:num_running_reqs\{/{s+=$NF} END{printf "%.0f", s+0}' <<<"$metrics")
    defer=$(awk '/^sglang:num_queue_reqs\{/{s+=$NF} END{printf "%.0f", s+0}' <<<"$metrics")
    # SGLang publishes no decode-seconds counter (forward_execution_seconds_total
    # is absent from the exposition), so the rate pair is total request latency.
    # pred/psec is therefore tokens per second of REQUEST time, prefill
    # included -- a different quantity from llama.cpp's
    # tokens_predicted_seconds_total. Do not read the two as equivalent.
    psec=$(awk '/^sglang:e2e_request_latency_seconds_sum\{/{s+=$NF} END{printf "%.6f", s+0}' <<<"$metrics")
    # Prefill pair. prompt_tokens is NOT the prefill work: radix-cache hits
    # land in the same counter (measured: 5.1M device_hit vs ~350k actually
    # computed). For an honest encode rate use the prefill-COMPUTE counter
    # over prefill seconds ~= TTFT minus queue time. The anchor layout stays
    # "pred psec prom promsec" for all backends; only the sglang branch
    # redefines what prom/promsec hold.
    promsec=$(awk '/^sglang:time_to_first_token_seconds_sum\{/{s+=$NF} END{printf "%.6f", s+0}' <<<"$metrics")
    peff=$(awk '/^sglang:prefill_effective_tokens_total\{.*mode="input"/{s+=$NF} END{printf "%.1f", s+0}' <<<"$metrics")
    tq=$(awk '/^sglang:queue_time_seconds_sum\{/{s+=$NF} END{printf "%.6f", s+0}' <<<"$metrics")
    prom="${peff:-0}"
    promsec=$(awk -v t="${promsec:-0}" -v q="${tq:-0}" 'BEGIN{d=t-q; if(d<0)d=0; printf "%.6f", d}')
    # Phase discriminator. There is no per-iteration decode counter, so reuse
    # the generated-token counter: its rate is tokens/s, which straddles the
    # same 2.0/s line below (generating ~150/s, chunked prefill ~0/s).
    ndec="$pred"
  else
    pred=$(awk '/^llamacpp:tokens_predicted_total /{print $2; exit}' <<<"$metrics")
    psec=$(awk '/^llamacpp:tokens_predicted_seconds_total /{print $2; exit}' <<<"$metrics")
    ndec=$(awk '/^llamacpp:n_decode_total /{print $2; exit}' <<<"$metrics")
    proc=$(awk '/^llamacpp:requests_processing /{print $2; exit}' <<<"$metrics")
    defer=$(awk '/^llamacpp:requests_deferred /{print $2; exit}' <<<"$metrics")
    prom=$(awk '/^llamacpp:prompt_tokens_total /{print $2; exit}' <<<"$metrics")
    promsec=$(awk '/^llamacpp:prompt_seconds_total /{print $2; exit}' <<<"$metrics")
  fi
  pred=${pred:-0}; psec=${psec:-0}; ndec=${ndec:-0}; proc=${proc:-0}; defer=${defer:-0}
  prom=${prom:-0}; promsec=${promsec:-0}
fi

# Gufo (serve-gufo.sh) serves /metrics under llamacpp: names but only exposes
# completion-batched token counters plus the latest speed gauges: no
# n_decode_total and no live request counters. Detect the shape and use its
# own signals (journal request events) in the branch below.
GUFO=0; SGLANG=0
if [[ "$cfg_backend" == "sglang" ]]; then
  SGLANG=1
elif [[ "$st" == "ok" ]] && ! grep -q '^llamacpp:n_decode_total ' <<<"${metrics:-}"; then
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
    # Full invocation journal, not a tail window: --log-progress floods the
    # journal (hundreds of lines per request), and a capped tail scrolls out a
    # request's received event while keeping its completed pair — inflight goes
    # negative, clamps to zero, and the phase display dies. Filtered at capture
    # to the two tags this profile actually reads.
    jl=$(journalctl --user -u llama-server.service "_SYSTEMD_INVOCATION_ID=$invid" --no-pager -o cat 2>/dev/null | grep -E '\[http\]|\[progress\]' || true)
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
    # Phase lines after the latest received event describe the in-flight
    # request; earlier ones are a finished run's leftovers and would mislabel
    # the gap before the first prefill chunk logs.
    start=$(grep -n 'event=received .*path=/v1/chat/completions' <<<"$jl" | tail -1 | cut -d: -f1)
    ph=""
    if [[ -n "$start" ]]; then
      ph=$(tail -n "+$start" <<<"$jl" | grep -o 'phase=[a-z]*' | tail -1 | cut -d= -f2 || true)
    fi
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
  rm -f "$STATE" "$ANCHOR" "$LASTTPS" "$LASTENC" "$LASTTTFT" "$TOKW" "$AVGW" "$CFG/.genstate" "$CFG/.genanchor"
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
      if [[ "$SGLANG" == 1 ]]; then
        # SGLang is the one backend whose /metrics carries TTFT directly:
        # sum/count is the mean over all requests served this session.
        # Sum across is_streaming series like the counter block above.
        _ts=$(awk '/^sglang:time_to_first_token_seconds_sum\{/{s+=$NF} END{print s+0}' <<<"${metrics:-}")
        _tc=$(awk '/^sglang:time_to_first_token_seconds_count\{/{s+=$NF} END{print s+0}' <<<"${metrics:-}")
        awk -v s="${_ts:-0}" -v c="${_tc:-0}" 'BEGIN{ if (c>0) printf "%.0f\n", 1000*s/c }' > "$LASTTTFT.tmp"
        if [[ -s "$LASTTTFT.tmp" ]]; then mv "$LASTTTFT.tmp" "$LASTTTFT"; else rm -f "$LASTTTFT.tmp"; fi
      else
        # llama-server /metrics carries no time-to-first-token; leave the panel
        # cell empty rather than inventing one from prefill time.
        rm -f "$LASTTTFT"
      fi
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

# --- turn efficiency: tokens/joule over the whole turn (encode + decode) -----
# A turn runs idle -> idle: one request, or a back-to-back burst with no idle
# gap. Energy is the integral of sampled power across the busy window, so the
# prefill (encoding) cost is inside the denominator, not ignored; averaging the
# integral, not a peak sample, is what makes it a turn figure.
nowf=$(date +%s.%N)
read -r e_j e_t e_ts e_busy e_pwr < <(cat "$ENERGY" 2>/dev/null || echo "0 0 0 0 ")
e_j=${e_j:-0}; e_t=${e_t:-0}; e_ts=${e_ts:-0}; e_busy=${e_busy:-0}; e_pwr=${e_pwr:-}
if [[ "$st" == "ok" ]] && awk -v b="$e_ts" 'BEGIN{exit !(b>0)}' && [[ -n "${pwr:-}" ]]; then
  # Only integrate across a sane gap; a sleep/hiccup must not inject energy.
  dte=$(awk -v a="$nowf" -v b="$e_ts" 'BEGIN{ printf "%.3f", a-b }')
  if awk -v d="$dte" 'BEGIN{ exit !(d>0 && d<=10) }'; then
    if [[ "$busy" == 1 || "$e_busy" == 1 ]]; then
      # Trapezoid: half the previous sample's power plus half this one's. This
      # is what stops the idle tail at each turn boundary being charged at the
      # full busy power.
      if [[ -n "$e_pwr" ]]; then
        e_j=$(awk -v a="$e_j" -v p="$e_pwr" -v q="$pwr" -v s="$dte" 'BEGIN{ printf "%.4f", a + (p+q)/2*s }')
      else
        e_j=$(awk -v a="$e_j" -v q="$pwr" -v s="$dte" 'BEGIN{ printf "%.4f", a + q*s }')
      fi
      e_t=$(awk -v a="$e_t" -v s="$dte" 'BEGIN{ printf "%.3f", a+s }')
    fi
  fi
fi

if [[ "$st" == "ok" ]]; then
  # Anchor = counters at the last idle. Both backends advance
  # tokens_predicted_total at request completion, so one rule covers llama + gufo.
  read -r t_pred t_psec t_prom t_promsec < <(cat "$TANCHOR" 2>/dev/null || echo "$pred $psec $prom $promsec")
  t_pred=${t_pred:-$pred}
  if fcmp "$pred" "$t_pred" ">"; then
    outtok=$(awk -v a="$pred" -v b="$t_pred" 'BEGIN{ printf "%.0f", a-b }')
    if fcmp "$outtok" 0 ">" && fcmp "$e_j" 0 ">"; then
      awk -v n="$outtok" -v e="$e_j" 'BEGIN{ printf "%.4f\n", n/e }' > "$TOKW.tmp" && mv "$TOKW.tmp" "$TOKW"
      awk -v e="$e_j" -v t="$e_t" 'BEGIN{ if (t>0) printf "%.1f\n", e/t }' > "$AVGW.tmp" && mv "$AVGW.tmp" "$AVGW"
    fi
    printf '%s %s %s %s\n' "$pred" "$psec" "$prom" "$promsec" > "$TANCHOR"
    e_j=0; e_t=0
  fi
  if [[ "$busy" == 0 ]]; then
    printf '%s %s %s %s\n' "$pred" "$psec" "$prom" "$promsec" > "$TANCHOR"
    e_j=0; e_t=0
  fi
else
  e_j=0; e_t=0
fi
printf '%s %s %s %s %s\n' "$e_j" "$e_t" "$nowf" "$busy" "${pwr:-}" > "$ENERGY"

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
  if [[ "$SGLANG" == 1 ]]; then backend="sglang"
  elif [[ "$GUFO" == 1 ]]; then backend="gufo"
  else backend="llama"; fi
fi

# --- GPU VRAM ------------------------------------------------------------------
# Which GPU's memory is meaningful depends on the backend. The GGUF backends
# serve on the Strix Halo iGPU, so the Radeon's carve is the right number there
# (take the first DRM card that reports VRAM rather than assuming card1). The
# SGLang backend runs on the discrete card behind the USB4 tunnel, so read the
# NVIDIA card for it -- the power sample already comes from that card, and
# pairing it with the idle iGPU's 32 GB carve made the panel incoherent.
vram=""; vtotal=""
if [[ "$cfg_backend" == "sglang" ]] && command -v nvidia-smi >/dev/null 2>&1; then
  # nvidia-smi reports MiB; the widget renders bytes / 1073741824.
  read -r _used _total < <(nvidia-smi --query-gpu=memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | tr ',' ' ')
  if [[ "$_used" =~ ^[0-9]+$ && "$_total" =~ ^[0-9]+$ ]]; then
    vram=$(( _used * 1048576 )); vtotal=$(( _total * 1048576 ))
  fi
fi
if [[ -z "$vram" ]]; then
  for f in /sys/class/drm/card*/device/mem_info_vram_used; do
    if [[ -r "$f" ]]; then vram=$(cat "$f"); break; fi
  done
  for f in /sys/class/drm/card*/device/mem_info_vram_total; do
    if [[ -r "$f" ]]; then vtotal=$(cat "$f"); break; fi
  done
fi

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
printf 'power_w=%s\n' "${pwr:-}"
printf 'avg_w=%s\n' "$(cat "$AVGW" 2>/dev/null || true)"
printf 'tok_w=%s\n' "$(cat "$TOKW" 2>/dev/null || true)"
