#!/bin/bash
# Capture the amdgpu devcoredump the moment it appears, before it expires.
# Triggered by 99-amdgpu-devcoredump.rules on the "devcoredump" uevent.
set -u
OUT=/var/log/amdgpu-devcoredump
mkdir -p "$OUT"
TS=$(date +%Y%m%d-%H%M%S)
# Grab the coredump data as fast as possible; it self-deletes after ~10 min.
DUMP="$OUT/devcoredump-$TS.bin"
cat "$DEVPATH/data" > "$DUMP" 2>/dev/null
# Small metadata sidecar with current GPU/memory state
{
  echo "timestamp: $(date -Is)"
  echo "devpath: $DEVPATH"
  echo "gpu_vram_used: $(cat /sys/class/drm/card1/device/mem_info_vram_used 2>/dev/null)"
  echo "gpu_vram_total: $(cat /sys/class/drm/card1/device/mem_info_vram_total 2>/dev/null)"
  echo "gpu_gtt_used: $(cat /sys/class/drm/card1/device/mem_info_gtt_used 2>/dev/null)"
  echo "gpu_gtt_total: $(cat /sys/class/drm/card1/device/mem_info_gtt_total 2>/dev/null)"
  echo "loadavg: $(cat /proc/loadavg)"
  echo "meminfo: $(grep -E 'MemAvailable|SwapTotal|SwapFree|Committed_AS' /proc/meminfo | tr '\n' ' ')"
  echo "llama-server: $(systemctl --user is-active llama-server.service 2>/dev/null)"
} > "$DUMP.meta"
# Keep the last 20 dumps
ls -1t "$OUT"/devcoredump-*.bin 2>/dev/null | tail -n +21 | xargs -r rm -f
logger -t gpu-hang-capture "amdgpu devcoredump captured: $DUMP"
