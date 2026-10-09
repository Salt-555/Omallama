#!/usr/bin/env bash
# efficiency-sweep.sh -- measure the perf/watt curve of an NVIDIA GPU on a real
# llama.cpp workload, so the steady-state profile is chosen from data, not vibes.
#
# For each power ceiling it runs a decode-only and a prefill-only llama-bench
# pass, sampling power and temperature throughout, and reports throughput and
# tokens-per-joule. The knee -- the power ceiling past which more watts stop
# buying throughput -- is the point to lock in with apply-profile.sh.
#
# Requires root (it changes the power limit).
#
# Env (all optional except MODEL):
#   MODEL=/path/model.gguf   GGUF to benchmark            (required)
#   BENCH=/path/llama-bench  llama-bench binary           (default: $PATH)
#   GPU=0                    GPU index
#   POWER_LEVELS="300 275 250 225 200 175 150"   watts to sweep
#   PP=512 TG=128            prefill / decode token counts
#   REPS=3                   llama-bench repetitions
#   OUTDIR=~/.local/state/gpu-power
#   SAMPLE_MS=500            power/temp sampling interval
#
# Example:
#   sudo MODEL=~/models/Qwen3-30B-Q4_K_M.gguf \
#        BENCH=~/CodingProjects/llamacpp-mainline/llama.cpp/build/bin/llama-bench \
#        efficiency-sweep.sh
set -euo pipefail

MODEL="${MODEL:-}"
BENCH="${BENCH:-$(command -v llama-bench || true)}"
GPU="${GPU:-0}"
POWER_LEVELS="${POWER_LEVELS:-300 275 250 225 200 175 150}"
PP="${PP:-512}"
TG="${TG:-128}"
REPS="${REPS:-3}"
THREADS="${THREADS:-}"
OUTDIR="${OUTDIR:-$HOME/.local/state/gpu-power}"
SAMPLE_MS="${SAMPLE_MS:-500}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "$MODEL" ]       || die "set MODEL=/path/to/model.gguf"
[ -r "$MODEL" ]       || die "model not readable: $MODEL"
[ -n "$BENCH" ]       || die "llama-bench not found; set BENCH=/path/to/llama-bench"
[ -x "$BENCH" ]       || die "llama-bench not executable: $BENCH"
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found (driver not installed?)"
[ "$(id -u)" -eq 0 ]  || die "must run as root (it sets the GPU power limit)"

mkdir -p "$OUTDIR"
CSV="$OUTDIR/efficiency.csv"
[ -f "$CSV" ] || echo "timestamp,gpu,power_limit_w,mode,tps,avg_w,avg_temp_c,tokens_per_joule" > "$CSV"

sample_start() {  # $1 = logfile ; echoes sampler pid
  nvidia-smi -i "$GPU" --query-gpu=power.draw,temperature.gpu \
    --format=csv,noheader,nounits -lms "$SAMPLE_MS" > "$1" 2>/dev/null &
  echo $!
}
sample_stop() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# avg power (W) and avg temp (C) from a sampler logfile
stats() {
  awk -F', *' '{w+=$1; t+=$2; n++} END{if(n) printf "%.1f %.1f", w/n, t/n; else printf "0 0"}' "$1"
}

# tokens/sec for a phase label (tg128 / pp512) out of llama-bench's table
parse_tps() {
  awk -v t="$2" '
    { for (i=1;i<=NF;i++) if ($i==t) {
        for (j=i+1;j<=NF;j++) if ($j ~ /^[0-9]+(\.[0-9]+)?$/) { print $j; exit }
        exit } }' "$1"
}

echo "[gpu-power] model=$MODEL"
echo "[gpu-power] bench=$BENCH"
echo "[gpu-power] gpu=$GPU  powers=[$POWER_LEVELS]  pp=$PP tg=$TG reps=$REPS"

for PL in $POWER_LEVELS; do
  nvidia-smi -i "$GPU" -pl "$PL" >/dev/null
  printf '\n=== power limit %sW ===\n' "$PL"
  for MODE in decode prefill; do
    if [ "$MODE" = decode ]; then LB_ARGS=(-p 0 -n "$TG"); LABEL="tg$TG"
    else                           LB_ARGS=(-p "$PP" -n 0); LABEL="pp$PP"; fi
    LOG="$OUTDIR/${MODE}-${PL}W.txt"
    SAMP="$OUTDIR/${MODE}-${PL}W.power"
    PID=$(sample_start "$SAMP")
    # shellcheck disable=SC2086
    "$BENCH" -m "$MODEL" "${LB_ARGS[@]}" -r "$REPS" ${THREADS:+-t "$THREADS"} 2>&1 | tee "$LOG" >/dev/null
    sample_stop "$PID"
    TPS=$(parse_tps "$LOG" "$LABEL")
    read -r AVGW AVGT < <(stats "$SAMP")
    TPJ=$(awk -v a="${TPS:-0}" -v w="${AVGW:-0}" 'BEGIN{ if (w>0 && a>0) printf "%.4f", a/w; else print "" }')
    printf '  %-7s %8s t/s @ %6sW %5sC  -> %s tok/J\n' "$MODE" "${TPS:-?}" "$AVGW" "$AVGT" "${TPJ:-?}"
    echo "$(date -Is),$GPU,$PL,$MODE,${TPS:-},$AVGW,$AVGT,${TPJ:-}" >> "$CSV"
  done
done

printf '\nwrote %s\n' "$CSV"
command -v column >/dev/null 2>&1 && column -t -s, "$CSV" || cat "$CSV"
