#!/usr/bin/env bash
# apply-profile.sh -- pin an NVIDIA GPU to a steady, cool, efficient operating point.
#
# Longevity logic: Linux exposes no core-voltage control, but a fixed core-clock
# ceiling together with a power ceiling makes the card's PMU settle at a lower
# voltage for that clock, holds temperature down and removes P-state churn
# (thermal cycling). A steady operating point ages slower than a moving one.
#
# Requires root: power limits and clock locks are privileged.
#
# Env (all optional):
#   GPU=0                    GPU index
#   POWER_LIMIT_W=250        total board power ceiling, watts
#   CORE_CLOCK_MIN=          core clock floor, MHz (blank = leave)
#   CORE_CLOCK_MAX=          core clock ceiling, MHz (blank = leave unlocked)
#   DRY_RUN=0                set 1 to only print what would run
#
# Examples:
#   sudo POWER_LIMIT_W=250 CORE_CLOCK_MAX=1700 apply-profile.sh
#   DRY_RUN=1 POWER_LIMIT_W=250 CORE_CLOCK_MAX=1700 apply-profile.sh
set -euo pipefail

GPU="${GPU:-0}"
POWER_LIMIT_W="${POWER_LIMIT_W:-250}"
CORE_CLOCK_MIN="${CORE_CLOCK_MIN:-}"
CORE_CLOCK_MAX="${CORE_CLOCK_MAX:-}"
DRY_RUN="${DRY_RUN:-0}"

info() { printf '[gpu-power] %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found (driver not installed?)"

have_root=0
[ "$(id -u)" -eq 0 ] && have_root=1

run() {
  printf '  + %s\n' "$*"
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}

info "GPU $GPU -> power ${POWER_LIMIT_W}W, core clock ${CORE_CLOCK_MIN:-any}..${CORE_CLOCK_MAX:-unlocked}${DRY_RUN:+, DRY_RUN=$DRY_RUN}"

if [ "$have_root" -eq 1 ]; then
  # Persistence mode keeps the driver resident: no per-context init churn.
  run nvidia-smi -i "$GPU" -pm 1
  run nvidia-smi -i "$GPU" -pl "$POWER_LIMIT_W"
  if [ -n "$CORE_CLOCK_MAX" ]; then
    run nvidia-smi -i "$GPU" -lgc "${CORE_CLOCK_MIN:-0},${CORE_CLOCK_MAX}"
  else
    info "no CORE_CLOCK_MAX set; leaving clocks to the default governor"
  fi
else
  info "not root: skipping power/clock changes (need root). Showing current state only."
fi

info "current state:"
nvidia-smi -i "$GPU" \
  --query-gpu=name,power.limit,power.draw,clocks.sm,clocks.max.sm,temperature.gpu,persistence_mode \
  --format=csv,noheader 2>/dev/null || info "(could not query GPU state)"
