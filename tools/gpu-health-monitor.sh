#!/bin/bash
# Lightweight GPU health sampler for llama-server diagnosis.
# One line every 10s (only while llama-server is active) to a rotating log.
# Answers, after a crash: was VRAM/GTT saturated? was swap growing? was a
# big prefill in flight when the ring timed out?
set -u
STATE_DIR="$HOME/.local/state/llama-server"
mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/gpu-health.log"
MAX_BYTES=$((20 * 1024 * 1024))   # ~20 MB, then rotate (10s x ~3.5 days)

rotate() {
  [ -f "$LOG" ] || return 0
  sz=$(stat -c %s "$LOG")
  if [ "$sz" -gt "$MAX_BYTES" ]; then
    mv "$LOG" "$LOG.1"
  fi
}

CARD=/sys/class/drm/card1/device
while true; do
  if [ "$(systemctl --user is-active llama-server.service 2>/dev/null)" = "active" ]; then
    rotate
    VRAM_USED=$(cat "$CARD/mem_info_vram_used" 2>/dev/null || echo 0)
    VRAM_TOTAL=$(cat "$CARD/mem_info_vram_total" 2>/dev/null || echo 0)
    GTT_USED=$(cat "$CARD/mem_info_gtt_used" 2>/dev/null || echo 0)
    GTT_TOTAL=$(cat "$CARD/mem_info_gtt_total" 2>/dev/null || echo 0)
    TEMP=$(cat "$CARD/hwmon/hwmon*/temp1_input" 2>/dev/null | head -1)
    PWR=$(cat "$CARD/hwmon/hwmon*/power1_average" 2>/dev/null | head -1)
    SWAP_USED=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print (t-f)/1024}' /proc/meminfo)
    COMMITTED=$(awk '/Committed_AS/{print $2}' /proc/meminfo)
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    # Server-side activity signals
    PORT_UP=$(ss -Htln 2>/dev/null | grep -c ':6969 ')
    echo "$(date +%s)|$(date -Is)|vram=${VRAM_USED}/${VRAM_TOTAL}|gtt=${GTT_USED}/${GTT_TOTAL}|temp_millic=${TEMP:-?}|power_uw=${PWR:-?}|swap_mb=${SWAP_USED:-?}|committed_kb=${COMMITTED:-?}|load1=${LOAD}|port6969=${PORT_UP}" >> "$LOG"
  fi
  sleep 10
done
