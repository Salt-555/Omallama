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
# No built-in default model: a silent fallback to a checkpoint nobody selected
# costs a full re-download. SGLANG_DEFAULT_MODEL still works; with neither,
# refuse and say why.
TARGET="${TARGET:-${SGLANG_DEFAULT_MODEL:-}}"
if [[ -z "$TARGET" ]]; then
  echo "serve-sglang: model.json names no model and SGLANG_DEFAULT_MODEL is unset" >&2
  exit 1
fi
# --- full-context profile (one RTX PRO 6000 Blackwell 96 GB) -----------------
# The cookbook's low-latency cell (bf16 KV, mamba cache 48, 16 request slots)
# sized the KV pool at 57,216 tokens against a 262,144-token context, so any
# request whose input+output crossed ~57k came back finish_reason=length and
# Hermes reported a truncated reply. The published profile for this exact card
# (SSHdotCodes/qwen-3.8-flash-next-pro6000) runs FP8 E4M3 KV, an explicit
# large KV pool, a small mamba state pool and a 2-request decode graph.
MAXRUN=$(jq -r '.max_running_requests // 2' "$MODEL_CONF" 2>/dev/null || echo 2)
# Decode CUDA-graph batch size must cover the request slots, or requests past
# bs=2 decode through the eager path. Follow max_running_requests; a preset can
# still pin it with "cuda_graph_max_bs_decode".
CGRAPH=$(jq -r '.cuda_graph_max_bs_decode // empty' "$MODEL_CONF" 2>/dev/null || echo "")
# --ple-offload-embedding is Qwen4-Exp-only; sglang hard-errors on anything else
# ("only supports Qwen4ExpForConditionalGeneration"). Follow the preset, and
# otherwise keep it on just for the Flash-Next family the flag was added for.
PLE=$(jq -r 'if .ple_offload_embedding == null then empty else .ple_offload_embedding end' "$MODEL_CONF" 2>/dev/null || echo "")
if [[ -z "$PLE" ]]; then
  case "$TARGET" in *Flash-Next*) PLE=true ;; *) PLE=false ;; esac
fi
PLE_FLAGS=()
[[ "$PLE" == "true" ]] && PLE_FLAGS=(--ple-offload-embedding)
[[ -n "$CGRAPH" ]] || CGRAPH="$MAXRUN"
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
# mamba state slots. LEFT UNSET sglang jointly solves the slot count against
# --mamba-full-memory-ratio (kv_cache_configurator.py: ~2133). Pinning it
# forces a fixed budget and then caps max_running_requests (observed: 14 slots
# -> 3 lanes at 4 slots/request). Set "max_mamba_cache_size" in the preset to
# pin it; leave it out to let sglang size it.
MAMBACACHE=$(jq -r '.max_mamba_cache_size // empty' "$MODEL_CONF" 2>/dev/null || echo "")
MAMBA_FLAGS=()
[[ -n "$MAMBACACHE" ]] && MAMBA_FLAGS=(--max-mamba-cache-size "$MAMBACACHE")
# fp8_e4m3 KV requires the QSA fp8 tile-dequant fix (gabrielolympie
# sglang-flashnext-sm120 patch 0002): the stock QSA sparse-prefill Triton
# kernel feeds fp8 straight into tl.dot and dies with "Unsupported rhs dtype
# fp8e4nv". The patched sparse_attn.py is bind-mounted read-only into the
# container below; the overlay lives in ~/egpu-nvidia-setup/sglang/qsa-fp8-overlay.
#
# Second overlay, same mechanism: managers/mm_utils.py, from
# ~/egpu-nvidia-setup/sglang/mm-offload-overlay. Stock code offloads multimodal
# features with feature.to("cpu", non_blocking=True) (mm_utils.py:704) and on
# long chunked multimodal prefills that copy raised
# "torch.AcceleratorError: CUDA error: invalid argument", SIGQUITing the
# scheduler and killing the server twice (2026-10-16 17:43, 2026-10-19 14:18).
# The overlay keeps a contiguous check, retries synchronously on failure, and
# degrades to leaving the feature on device rather than dying. Remove the -v
# line to fall back to the image's own file.
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

# --- multimodal (vision) flags ----------------------------------------------
# Vision DOES work on this card as of 2026-10-19: 64-token, 3,600-token and
# 8,160-token images, an 8k image spanning three prefill chunks, and a 148k
# prompt carrying an image all returned 200. Earlier "vision has never
# completed a request" notes are obsolete. What still breaks is the mm feature
# CPU offload in a long chunked prefill (see the mm-offload-overlay below).
#
# The two preprocessing candidates, both aimed at the same 4.7 GB of card
# headroom that a 0.98 mem-fraction leaves for the vision transient:
#   * image preprocessing on the GPU. 'auto' lets Transformers pick, which means
#     the torchvision fast path. Penny Royal (jpezzulli/sglang-rtxpro6000) is the
#     only SM120 RTX PRO 6000 setup with documented passing image validation and
#     it runs pil + cpu preprocessing; its community notes record
#     "image-preprocessing OOM when GPU memory was full".
#   * blast radius. The checkpoint's preprocessor_config allows
#     longest_edge=16777216 px, so one inbound image can be enormous.
# Both flags are verified consumed in THIS build (image_processor_backend via
# resolve_image_processor_backend in scheduler.py/tokenizer_manager.py;
# limit_mm_data_per_request in tokenizer_manager.py). Set MM_DISABLE=1 to revert
# to the pre-change launch line without editing this file.
#
# NOT set, on purpose: a pixel cap via --mm-process-config. It is wired through
# multimodal/processors/base_processor.py, but the correct key names in
# transformers 5.x are unverified (Qwen2VLImageProcessor exposes no max_pixels
# kwarg; the modern budget is size.longest_edge). A wrong key here can fail the
# load, so it stays out until checked.
MM_FLAGS=()
MM_XPORT_FLAGS=()
if [[ "${MM_DISABLE:-0}" != "1" ]]; then
  MM_FLAGS+=( --image-processor-backend pil )
  MM_FLAGS+=( --limit-mm-data-per-request '{"image": 1}' )
  # Feature transport. Unset means "cpu": every image feature round-trips
  # through host RAM per prefill chunk over the caching pinned allocator. That
  # async D2H copy is what raised "CUDA error: invalid argument" twice
  # (2026-10-16 17:43, 2026-10-19 14:18) and killed the scheduler.
  # "cuda_ipc" keeps features in a bounded device-resident pool
  # (SGLANG_MM_FEATURE_CACHE_MB, default 1024 MiB) and falls back to CPU when
  # the pool is full. Documented in server_args.py:2879 / `sglang serve --help`.
  # MM_TRANSPORT=cpu reverts to the old behaviour without editing this file.
  MM_XPORT_FLAGS+=( --mm-feature-transport "${MM_TRANSPORT:-cuda_ipc}" )
fi

# --- idle CPU ---------------------------------------------------------------
# The scheduler loop calls recv_requests() NON-blocking, so with nothing in
# flight it spins: one core pinned at 100% for the whole life of the container,
# measured 2026-10-17 at 100.1% of one core (= 3.1% of 32) with every sglang
# queue metric at zero. Upstream reports it as sgl-project/sglang#1730 ("caused
# by a non-blocking ZMQ receive operation in the recv_requests function").
# scheduler.py only builds the IdleSleeper when get_device().sleep_on_idle is
# set, and that attribute is this server arg, whose default is False:
#   server_args.py: sleep_on_idle: A[bool, "Reduce CPU usage when sglang is
#     idle.", NS("device")] = False
#   sglang serve --help: --sleep-on-idle  Reduce CPU usage when sglang is idle.
# With the flag on, on_idle() ends in IdleSleeper.maybe_sleep() ->
# zmq.Poller.poll(1000) on recv_from_tokenizer + recv_from_rpc, so it parks on
# the sockets and returns the moment a request lands: idling costs no wake-up
# latency. Set IDLE_SPIN=1 to restore the busy loop without editing this file.
SLEEP_FLAGS=(--sleep-on-idle)
if [[ "${IDLE_SPIN:-0}" == "1" ]]; then SLEEP_FLAGS=(); fi

echo "sglang: serving $TARGET as $SERVED_NAME on :$PORT" >&2

# Foreground so the unit tracks the server, as the GGUF backends do.
exec docker run --rm --init --name "$CONTAINER" --gpus all \
  --shm-size 32g \
  --ulimit memlock=-1 \
  -p "$PORT:$PORT" \
  -v "$HF_CACHE_DIR:/root/.cache/huggingface" \
  -v "$HOME/egpu-nvidia-setup/sglang/qsa-fp8-overlay/python/sglang/srt/layers/attention/qsa/sparse_attn.py:/sgl-workspace/sglang/python/sglang/srt/layers/attention/qsa/sparse_attn.py:ro" \
  -v "$HOME/egpu-nvidia-setup/sglang/mm-offload-overlay/python/sglang/srt/managers/mm_utils.py:/sgl-workspace/sglang/python/sglang/srt/managers/mm_utils.py:ro" \
  --cap-add SYS_PTRACE \
  --env PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,pinned_max_round_threshold_mb:128 \
  --env CUDA_ENABLE_USER_TRIGGERED_COREDUMP=1 \
  --env CUDA_LOG_FILE=stderr \
  --env SGLANG_MM_FEATURE_CACHE_MB="${MM_POOL_MB:-1024}" \
  --env SGLANG_ENABLE_HEALTH_ENDPOINT_GENERATION=false \
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
    "${MAMBA_FLAGS[@]}" \
    --cuda-graph-max-bs-decode "$CGRAPH" \
    --mamba-ssm-dtype bfloat16 \
    --reasoning-parser qwen3 \
    --tool-call-parser qwen3_coder \
    --mem-fraction-static "$MEMFRAC" \
    "${PLE_FLAGS[@]}" \
    --enable-metrics \
    "${MM_FLAGS[@]}" \
    "${MM_XPORT_FLAGS[@]}" \
    "${SLEEP_FLAGS[@]}" \
    --host 0.0.0.0 \
    --port "$PORT"
