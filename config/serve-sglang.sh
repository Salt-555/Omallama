#!/usr/bin/env bash
# SGLang backend launcher for the omarchy llama-server control plane (port 6969).
#
# Same control contract as the llama.cpp and gufo backends: the active model
# comes from ~/.config/llama-server/model.json, the served model name is
# ALLMIND so existing clients keep sending the same id, and the widget drives
# this through `systemctl --user restart llama-server.service`.
#
# Differences from the GGUF backends, both forced by the runtime:
#   - model.json".model" is a HuggingFace REPO ID for this backend, not a file
#     path. serve.sh dispatches on `backend` before its file-exists test.
#   - SGLang's /health returns 200 with an EMPTY body, and /metrics is off
#     unless --enable-metrics is passed. monitor.sh has a matching branch.
#
# The flag set is the SGLang cookbook's verified RTX PRO 6000 (1x 96 GB, TP=1)
# low-latency cell, plus --enable-metrics which the cell does not carry:
#   https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-Flash-Next
# "all the ways the plugin wants to be connected" is why --enable-metrics is
# here: the widget's idle/encoding/decoding phase and its t/s readout are built
# entirely on /metrics counters, so a server without it would look dead.
# The cookbook's cell sets --reasoning-parser but NOT --tool-call-parser.
# Without it SGLang auto-DETECTS qwen3_coder from the chat template (it
# logs that) but never applies it, so the model's correct Qwen XML tool
# calls go out as plain `content` and any OpenAI-style client that reads
# `tool_calls` sees nothing. Confirmed on this box: finish_reason=stop,
# tool_calls=null, content='<tool_call><function=...>'. Added on purpose.
set -euo pipefail

MODEL_CONF="$HOME/.config/llama-server/model.json"
HF_CACHE_DIR="${SGLANG_HF_CACHE:-$HOME/.cache/huggingface}"
IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:dev-qwen38-next-local}"
CONTAINER="sglang-llm"
PORT="${SGLANG_PORT:-6969}"
SERVED_NAME="${SGLANG_SERVED_NAME:-ALLMIND}"
# The port the plugin polls; keep BASE_URL in monitor.sh in step with $PORT.
RUNTIME_FILE="$HOME/.config/llama-server/.sglang_runtime"

# --- active model: an HF repo id, not a path --------------------------------
TARGET=""
[[ -f "$MODEL_CONF" ]] && TARGET=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
[[ -n "$TARGET" ]] || TARGET="${SGLANG_DEFAULT_MODEL:-RadixArk/Qwen3.8-Flash-Next-NVFP4}"
# --- full-context profile (one RTX PRO 6000 Blackwell 96 GB) -----------------
# The cookbook's low-latency cell (bf16 KV, mamba cache 48, 16 request slots)
# sized the KV pool at 57,216 tokens against a 262,144-token context, so any
# request whose input+output crossed ~57k came back finish_reason=length and
# Hermes reported a truncated reply. The published profile for this exact card
# (SSHdotCodes/qwen-3.8-flash-next-pro6000) runs FP8 E4M3 KV, an explicit
# large KV pool, a small mamba state pool and a 2-request decode graph.
MAXRUN=$(jq -r '.max_running_requests // 2' "$MODEL_CONF" 2>/dev/null || echo 2)
MEMFRAC=$(jq -r '.mem_fraction_static // 0.98' "$MODEL_CONF" 2>/dev/null || echo 0.98)
CTX=$(jq -r '.context_length // 262144' "$MODEL_CONF" 2>/dev/null || echo 262144)
# bf16 KV costs ~24.2 KB/token. A 262,144-token pool (6.34 GB) plus weights
# 81.9 GB left <400 MB free at runtime, and the vision tower OOM'd during a
# multimodal prefill with 2 requests at 114k pool tokens (2026-10-14 20:49).
# fp8 KV costs ~12.1 KB/token: 262,144 tokens is ~3.2 GB. Measured on the
# running fp8 server: ~5.8 GiB free of 95.5 GiB after weights+pool+runtime
# allocations — ample for the vision-tower transient that OOM'd the bf16
# 262k pool on 2026-10-14 20:49 (<400 MB free then).
TOTALTOK=$(jq -r '.max_total_tokens // 262144' "$MODEL_CONF" 2>/dev/null || echo 262144)
MAMBACACHE=$(jq -r '.max_mamba_cache_size // 14' "$MODEL_CONF" 2>/dev/null || echo 14)
# fp8_e4m3 KV requires the QSA fp8 tile-dequant fix (gabrielolympie
# sglang-flashnext-sm120 patch 0002): the stock QSA sparse-prefill Triton
# kernel feeds fp8 straight into tl.dot and dies with "Unsupported rhs dtype
# fp8e4nv". The patched sparse_attn.py is bind-mounted read-only into the
# container below; the overlay lives in ~/egpu-nvidia-setup/sglang/qsa-fp8-overlay.
KVDTYPE=$(jq -r '.kv_cache_dtype // "fp8_e4m3"' "$MODEL_CONF" 2>/dev/null || echo fp8_e4m3)
# Speculative (NEXTN/MTP) decoding: on unless the preset disables it. The
# YaRN long-context preset turns it off -- draft acceptance collapses past
# ~131k (observed on gufo with this model family), and rejected drafts cost
# 4x verify compute at deep positions, making decode SLOWER than pure AR.
# NB: '.speculative // true' would be WRONG here -- jq's // treats false as
# empty and would silently re-enable it.
SPECULATIVE=$(jq -r 'if .speculative == null then true else .speculative end' "$MODEL_CONF" 2>/dev/null || echo true)
if [[ "$SPECULATIVE" == "true" ]]; then
  SPEC_FLAGS=(--speculative-algorithm NEXTN --speculative-num-steps 3
              --speculative-eagle-topk 1 --speculative-num-draft-tokens 4
              --speculative-use-rejection-sampling)
else
  SPEC_FLAGS=()
fi
# YaRN context extension, exactly per the model card's SGLang recipe
# (https://huggingface.co/Qwen/Qwen3.8-Flash-Next): static yarn via
# --json-model-override-args, factor tuned to the target window (2.0 for
# 524,288). This build has no --rope-scaling flag; config-layer override is
# the documented path. Static yarn taxes short-context quality, so keep the
# normal preset for everyday serving.
ROPE_JSON=$(jq -c '.rope_parameters // empty' "$MODEL_CONF" 2>/dev/null || echo "")
YARN_FLAGS=()
if [[ -n "$ROPE_JSON" ]]; then
  YARN_FLAGS=(--json-model-override-args "{\"text_config\": {\"rope_parameters\": $ROPE_JSON}}")
fi
# context-length beyond the model's native 262,144 needs sglang's guard
# lifted (documented in the same recipe).
NATIVE_CTX=262144
LONGCTX_ENV=()
if (( CTX > NATIVE_CTX )); then
  LONGCTX_ENV=(--env SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1)
fi

# --- card handoff guard -------------------------------------------------------
# SGLang reserves the card at --mem-fraction-static (~94 of 96 GiB), so the
# card must actually be empty when this starts. ComfyUI on this box is
# loopback :8189 behind the cardmode gate; ask it to evict (documented:
# returns VRAM to ~0.7 GB in seconds), then wait for nvidia-smi to agree
# BEFORE launching -- at 0.98 a starved startup malloc dies with Restart=no
# and a dead unit in the widget. Thresholds live in modes.json
# (sglang_min_free_mib); this guard covers EVERY path into llm mode, manual
# widget switch included. Best-effort: a missing comfy must not block serving.
COMFY_URL="${COMFY_URL:-http://127.0.0.1:8189}"
MIN_FREE_MIB=$(jq -r '.sglang_min_free_mib // 90000' "$HOME/.config/llama-server/modes.json" 2>/dev/null || echo 90000)
curl -sf --max-time 10 -X POST "$COMFY_URL/free" \
  -H 'content-type: application/json' \
  -d '{"unload_models": true, "free_memory": true}' >/dev/null 2>&1 || true
for _ in $(seq 1 18); do
  FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
  [[ -z "$FREE_MIB" ]] && break                      # no card/no nvidia-smi: proceed
  (( FREE_MIB >= MIN_FREE_MIB )) && break
  echo "sglang: card handoff: free ${FREE_MIB} MiB < ${MIN_FREE_MIB} MiB, waiting" >&2
  sleep 5
done

# A stale container from a previous run would hold the port and 94 GB of VRAM.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "removing leftover container $CONTAINER" >&2
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

mkdir -p "$HF_CACHE_DIR"
printf 'backend=sglang\nmodel=%s\nport=%s\nserved=%s\nmax_running_requests=%s\n' \
  "$TARGET" "$PORT" "$SERVED_NAME" "$MAXRUN" > "$RUNTIME_FILE"

# --- watchdog: the documented mitigation, and the reason this box survives ---
# Cookbook: "a host-side watchdog that kills the server when MemAvailable drops
# below a few GiB, because a unified-memory exhaustion can take the whole box
# down and needs a power cycle to recover." The container holds ~64 GiB of shmem
# for its lifetime while the pinned PLE table also lives in host RAM.
WATCHDOG_MEM_GIB="${WATCHDOG_MEM_GIB:-3}"
(
  while :; do
    avail=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1048576 ))
    if (( avail < WATCHDOG_MEM_GIB )); then
      echo "WATCHDOG: MemAvailable ${avail} GiB < ${WATCHDOG_MEM_GIB} GiB -- stopping $CONTAINER" >&2
      docker stop "$CONTAINER" >/dev/null 2>&1 || docker kill "$CONTAINER" >/dev/null 2>&1
      exit 0
    fi
    sleep 5
  done
) &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null' EXIT

echo "sglang: serving $TARGET as $SERVED_NAME on :$PORT" >&2

# Foreground so the unit tracks the server, as the GGUF backends do.
exec docker run --rm --init --name "$CONTAINER" --gpus all \
  --shm-size 32g \
  --ulimit memlock=-1 \
  -p "$PORT:$PORT" \
  -v "$HF_CACHE_DIR:/root/.cache/huggingface" \
  -v "$HOME/egpu-nvidia-setup/sglang/qsa-fp8-overlay/python/sglang/srt/layers/attention/qsa/sparse_attn.py:/sgl-workspace/sglang/python/sglang/srt/layers/attention/qsa/sparse_attn.py:ro" \
  --env PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,pinned_max_round_threshold_mb:128 \
  --env SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=1 \
  "${LONGCTX_ENV[@]}" \
  --ipc=host \
  "$IMAGE" \
  sglang serve \
    --model-path "$TARGET" \
    --served-model-name "$SERVED_NAME" \
    --tp 1 \
    --quantization modelopt_fp4 \
    --fp4-gemm-backend flashinfer_cutlass \
    --moe-runner-backend flashinfer_cutlass \
    --page-size 64 \
    --mamba-track-interval 64 \
    --chunked-prefill-size 4096 \
    "${YARN_FLAGS[@]}" \
    --context-length "$CTX" \
    --max-total-tokens "$TOTALTOK" \
    --kv-cache-dtype "$KVDTYPE" \
    --linear-attn-prefill-backend triton \
    --linear-attn-decode-backend flashinfer \
    "${SPEC_FLAGS[@]}" \
    --mamba-radix-cache-strategy extra_buffer \
    --max-running-requests "$MAXRUN" \
    --max-mamba-cache-size "$MAMBACACHE" \
    --cuda-graph-max-bs-decode 2 \
    --mamba-ssm-dtype bfloat16 \
    --reasoning-parser qwen3 \
    --tool-call-parser qwen3_coder \
    --mem-fraction-static "$MEMFRAC" \
    --ple-offload-embedding \
    --enable-metrics \
    --host 0.0.0.0 \
    --port "$PORT"
