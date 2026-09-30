#!/usr/bin/env bash
# Gufo backend launcher for the omarchy llama-server control plane (port 6969).
# Runs gufo-org's Strix Halo runtime the way their quickstart documents it:
# the gufo-runtime OCI image with /dev/kfd + /dev/dri passed through, the
# models root mounted read-only at /models, and unlimited memlock. Same control
# contract as the llama.cpp backends: the active model comes from
# ~/.config/llama-server/model.json ({model, spec?, name?, backend?}); the
# backend and spec rules live ONLY in modelctl.sh.
#
# Gufo-compliant targets (gufo-org curated artifacts):
#   - unsloth/Qwen3.8-Flash-Next-GGUF UD-Q4_K_XL + MTP shared-Q8_0 sidecar
#   - unsloth/Qwen3.8-27B-GGUF UD-Q4_K_XL/Q8_K_XL + DFlash2 Q4_K_M draft
#   - antirez/deepseek-v4-gguf IQ2XXS + DSpark support sidecar
# Spec mapping: non-empty spec means the model's best speculative mode
# (flash-next -> mtp, 27B -> dflash2, deepseek -> dspark); empty spec = AR.
# A missing sidecar degrades to AR with a logged warning, never a crash loop.
#
# The served model name is ALLMIND, matching --alias ALLMIND on the llama.cpp
# backends, so existing clients keep sending the same model id.
set -euo pipefail

MODEL_CONF="$HOME/.config/llama-server/model.json"
MODELS_ROOT="$HOME/.lmstudio/models"
IMAGE="ghcr.io/gufo-org/toolboxes/gufo-runtime:latest"
CONTAINER="gufo-llm"
PORT=6969
SERVED_NAME="ALLMIND"
# Flag spelling verified against `gufo serve llm --help` (docs defer to --help).
SERVED_FLAG="--served-model-name"
# Sessions x context are set per model below (after target resolution).
CACHE_DIR="${GUFO_CACHE_DIR:-$HOME/.cache/gufo}"

# --- active model (same resolution order as the llama.cpp backends) -----------
TARGET=""
if [[ -f "$MODEL_CONF" ]]; then
  TARGET=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
fi
[[ -n "$TARGET" && -f "$TARGET" ]] || \
  TARGET="$MODELS_ROOT/unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_XL.gguf"
if [[ ! -f "$TARGET" ]]; then
  echo "target model not found: $TARGET" >&2
  exit 1
fi

SPEC_MODE=$(jq -r '.spec // empty' "$MODEL_CONF" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
lower="${TARGET,,}"
rel="${TARGET#"$MODELS_ROOT"/}"
CT_MODEL="/models/$rel"

# Base sessions x context per model; GUFO_SESSIONS / GUFO_CONTEXT override.
# Gufo reserves per-session capacity at admission (see SERVER.md), so the
# product is the real memory knob. Flash-Next runs one full-window main
# thread (1 x 250000; native max is 262144). Other gufo models keep the
# generic 4 x 65536 shape until they get their own numbers.
case "$lower" in
  *flash-next*) DEF_SESSIONS=1; DEF_CONTEXT=250000 ;;
  *)            DEF_SESSIONS=4; DEF_CONTEXT=65536 ;;
esac
SESSIONS="${GUFO_SESSIONS:-$DEF_SESSIONS}"
CONTEXT="${GUFO_CONTEXT:-$DEF_CONTEXT}"

# --- speculative sidecars (per gufo docs/models/<model>/README.md) -----------
CT_ARGS=()
case "$lower" in
  *qwen3.8-flash-next-gguf/ud-q4_k_xl/*)
    ROOT="$(dirname "$(dirname "$TARGET")")"
    MTP="$ROOT/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
    MMPROJ="$ROOT/mmproj-BF16.gguf"
    if [[ -n "$SPEC_MODE" && "$SPEC_MODE" != "off" && "$SPEC_MODE" != "none" ]]; then
      if [[ -f "$MTP" ]]; then
        CT_ARGS+=(--speculative mtp --mtp-model "/models/${MTP#"$MODELS_ROOT"/}")
      else
        echo "warn: MTP sidecar missing, running AR: $MTP" >&2
      fi
    fi
    if [[ -f "$MMPROJ" ]]; then
      CT_ARGS+=(--mmproj "/models/${MMPROJ#"$MODELS_ROOT"/}")
    fi
    ;;
  *qwen3.8-27b-gguf/ud-*)
    # Gufo qualifies the z-lab DFlash2 Q4_K_M at their pinned revision; prefer
    # it. The incoai copy on this box predates that cut (different content
    # hash), so it is only a fallback.
    DRAFT="$MODELS_ROOT/z-lab/Qwen3.8-27B-DFlash2-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
    if [[ ! -f "$DRAFT" ]]; then
      DRAFT="$MODELS_ROOT/incoai/Qwen3.8-27B-DFlash2-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
    fi
    if [[ -n "$SPEC_MODE" && "$SPEC_MODE" != "off" && "$SPEC_MODE" != "none" ]]; then
      if [[ -f "$DRAFT" ]]; then
        CT_ARGS+=(--speculative dflash2 --dflash-model "/models/${DRAFT#"$MODELS_ROOT"/}")
      else
        echo "warn: DFlash2 draft missing, running AR: $DRAFT" >&2
      fi
    fi
    ;;
  *antirez/deepseek-v4-gguf/*)
    DSPARK="$(dirname "$TARGET")/DeepSeek-V4-Flash-DSpark-support-0731.gguf"
    if [[ -n "$SPEC_MODE" && "$SPEC_MODE" != "off" && "$SPEC_MODE" != "none" && -f "$DSPARK" ]]; then
      # DSpark selects itself unless --speculative off is explicit.
      CT_ARGS+=(--dspark-model "/models/${DSPARK#"$MODELS_ROOT"/}")
    fi
    ;;
esac

# --- container (toolboxes quickstart: Docker variant) -----------------------
# Docker has no keep-id/keep-groups: pass the numeric GIDs owning the GPU
# device nodes (docs: one --group-add per distinct GID).
GRPS=()
for dev in /dev/kfd /dev/dri/renderD128; do
  g=$(stat -c '%g' "$dev" 2>/dev/null || true)
  if [[ -n "$g" ]] && [[ ! " ${GRPS[*]-} " == *" $g "* ]]; then
    GRPS+=("$g")
  fi
done
GROUP_ARGS=()
for g in ${GRPS[@]+"${GRPS[@]}"}; do
  GROUP_ARGS+=(--group-add "$g")
done

mkdir -p "$CACHE_DIR"

cleanup() {
  docker stop -t 15 "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

exec docker run --rm --init --name "$CONTAINER" --stop-timeout 15 \
  --device /dev/kfd --device /dev/dri \
  ${GROUP_ARGS[@]+"${GROUP_ARGS[@]}"} \
  --ulimit memlock=-1 \
  -p "127.0.0.1:$PORT:$PORT" \
  -v "$MODELS_ROOT:/models:ro" \
  -v "$CACHE_DIR:/cache" \
  "$IMAGE" \
  gufo serve --host 0.0.0.0 --port "$PORT" \
  llm --model "$CT_MODEL" \
  "$SERVED_FLAG" "$SERVED_NAME" \
  --sessions "$SESSIONS" --context "$CONTEXT" \
  --cache-disk /cache \
  --log-progress \
  ${CT_ARGS[@]+"${CT_ARGS[@]}"}
