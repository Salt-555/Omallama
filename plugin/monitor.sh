#!/usr/bin/env bash
# Poll the llama.cpp server (port 6969) + GPU VRAM for the omarchy widget.
# Emits key=value lines consumed by BarWidget.qml.
#
# Last-run tok/s: llama-server /metrics exposes cumulative predicted-tokens and
# predicted-seconds counters. The predicted_tokens_seconds gauge is a lifetime
# average (useless here), so monitor.sh tracks counter deltas between polls.
# When a generation is observed ending (the previous poll saw activity, this
# one sees none), the accumulated tokens and seconds of that run are committed
# to .last_tps — one number per run, no live tracking.
#
# State files are all scoped to ONE server session: the counters reset with the
# process, so any snapshot taken before the current session started is
# meaningless arithmetic.
#   .genstate   "<tok> <psec> <was_generating>" — the last poll's snapshot
#   .genanchor  "<tok> <psec>" — the last known-idle snapshot, the baseline a
#               finished run is measured from
#   .last_tps   tok/s of the last completed run
# A poll that finds no .genstate seeds all of them from the live counters
# rather than reading a missing baseline as 0 (which would mistake a whole
# session's counter for one enormous generation).
set -u

BASE="${LLAMA_BASE_URL:-http://127.0.0.1:6969}"
CFG="${LLAMA_CFG_DIR:-$HOME/.config/llama-server}"
STATE="$CFG/.genstate"      # "<tok> <psec> <was_generating>"
ANCHOR="$CFG/.genanchor"    # "<tok> <psec>"
LASTTPS="$CFG/.last_tps"

# --- server up/down -----------------------------------------------------------
# Two separate facts: health (can it serve now) and unit state (is it running,
# including mid model-load when /health 503s). The widget shows "loading" and
# keeps Stop/Restart available between "unit active" and "health not ok".
st="down"
if curl -sf --max-time 2 "$BASE/health" 2>/dev/null | grep -q '"ok"'; then
  st="ok"
fi
unit_state=$(systemctl --user is-active llama-server.service 2>/dev/null || true)
[[ "$unit_state" == "active" ]] || unit_state="inactive"

tok=0
psec=0
if [[ "$st" == "ok" ]]; then
  metrics=$(curl -sf --max-time 2 "$BASE/metrics" 2>/dev/null)
  tok=$(awk '/^llamacpp:tokens_predicted_total/{print $2}' <<<"$metrics" | head -1)
  psec=$(awk '/^llamacpp:tokens_predicted_seconds_total/{print $2}' <<<"$metrics" | head -1)
  tok=${tok:-0}; psec=${psec:-0}
fi

activity="idle"
if [[ "$st" == "ok" ]]; then
  if [[ ! -f "$STATE" ]]; then
    # First poll of a server session: there is no earlier snapshot to compare
    # against, so seed the baselines and report idle. The counters belong to
    # the process that just started; nothing has been generated yet.
    printf '%s %s 0\n' "$tok" "$psec" > "$STATE"
    printf '%s %s\n' "$tok" "$psec" > "$ANCHOR"
  else
    read -r ltok lpsec lgen <<< "$(cat "$STATE" 2>/dev/null || echo '0 0 0')"
    # Counters are floats and can print in scientific notation once they get
    # big (e.g. 1.6e+06), so compare with awk, not bash arithmetic ($(( ))
    # errors on decimals and would silently read as 0 = never generating).
    gen_now=false
    if awk -v a="$tok" -v b="$ltok" 'BEGIN{exit !(a > b)}'; then
      gen_now=true
      activity="generating"
    fi

    # Run boundary: previous poll was generating, this one isn't. Measure the
    # finished run from the last idle anchor to the last generating snapshot.
    if [[ "${lgen:-0}" == "1" && "$gen_now" == false ]]; then
      read -r atok apsec <<< "$(cat "$ANCHOR" 2>/dev/null || echo "$ltok $lpsec")"
      awk -v tok_g="$ltok" -v sec_g="$lpsec" -v tok_a="$atok" -v sec_a="$apsec" \
        'BEGIN{ dt=tok_g-tok_a; ds=sec_g-sec_a; if (dt>0 && ds>0.001) printf "%.1f\n", dt/ds }' > "$LASTTPS"
    fi
    # An idle poll re-anchors, so the next run is measured from a known-idle snapshot.
    if [[ "$gen_now" == false ]]; then
      printf '%s %s\n' "$tok" "$psec" > "$ANCHOR"
    fi

    printf '%s %s %s\n' "$tok" "$psec" "$([[ $gen_now == true ]] && echo 1 || echo 0)" > "$STATE"
  fi
else
  # A stopped server has no valid baseline and no last run worth showing: drop
  # all three so a restart cannot compare across process boundaries or display
  # a dead session's speed. (tps_last is still emitted, empty, so the widget
  # clears its readout instead of keeping the stale number.)
  rm -f "$STATE" "$ANCHOR" "$LASTTPS"
fi

last=$(cat "$LASTTPS" 2>/dev/null || true)

# --- active model from config --------------------------------------------------
model=$(jq -r '.model // empty' "$CFG/model.json" 2>/dev/null || true)
# Preset name, when the active model was set via a preset (see modelctl set).
name=$(jq -r '.name // empty' "$CFG/model.json" 2>/dev/null || true)

# --- GPU VRAM (Radeon 8060S) ---------------------------------------------------
vram=$(cat /sys/class/drm/card1/device/mem_info_vram_used 2>/dev/null)
vtotal=$(cat /sys/class/drm/card1/device/mem_info_vram_total 2>/dev/null)

printf 'status=%s\n' "$st"
printf 'service=%s\n' "$unit_state"
printf 'activity=%s\n' "$activity"
# Always emitted, empty when there is no run to report, so the widget has a
# single rule for "no value": absent-from-the-server means clear it.
printf 'tps_last=%s\n' "$last"
printf 'model=%s\n' "$model"
printf 'name=%s\n' "$name"
printf 'vram=%s\n' "${vram:-0}"
printf 'vram_total=%s\n' "${vtotal:-0}"
