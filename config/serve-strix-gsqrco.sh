#!/usr/bin/env bash
# DFlash2 speculative-decoding server for Qwen3.8-27B on Strix Halo (Vulkan).
# Build: llama.cpp PR #27342, built with -DGGML_VULKAN=ON.
# Measured on Ryzen AI MAX+ 395 / Radeon 8060S: 11.87 -> 22.34 tok/s (1.9x).
#
# The active model is read from ~/.config/llama-server/model.json (written by
# the omarchy llama-server plugin via modelctl.sh). When unset/empty it falls
# back to the default target below. The spec mode is whatever modelctl.sh
# wrote into model.json's "spec" (accepts legacy DFlash2/MTP spellings); the
# filename-inference rule lives ONLY in modelctl.sh.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$DIR/target-qwen3.8-27b-q4.gguf"
DRAFT="$DIR/draft-dflash2-q8.gguf"
BIN="$DIR/llama.cpp/build/bin/llama-server"
# Prefer current mainline (DFlash2 merged upstream 2026-08-27, PR #27342);
# fall back to the PR-pinned build. Mainline lives at ../llamacpp-mainline.
MAINLINE_BIN="$DIR/../llamacpp-mainline/build/bin/llama-server"
if [[ -x "$MAINLINE_BIN" ]]; then
  BIN="$MAINLINE_BIN"
fi
MODEL_CONF="$HOME/.config/llama-server/model.json"

# Optional active-model override from the plugin.
if [[ -f "$MODEL_CONF" ]]; then
  cfg_model=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
  if [[ -n "$cfg_model" && -f "$cfg_model" ]]; then
    TARGET="$cfg_model"
  fi
fi

# Spec mode. Authoritative source is model.json's "spec" field (written by
# modelctl.sh set from the preset's "spec"). Empty spec = no speculation.
# dflash needs the DFlash2 draft GGUF; mtp uses the model's built-in nextn
# head (no separate draft).
SPEC_MODE=$(jq -r '.spec // empty' "$MODEL_CONF" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
SPEC=""
DRAFT=""
case "${SPEC_MODE,,}" in
  *dflash*)
    # Q4_K_M draft: A/B'd vs BF16/Q8 - same acceptance, faster. n_max=4 is the
    # measured throughput optimum (+15% vs 7); see strix-halo-llm-speed skill.
    DRAFT="/home/salt/.lmstudio/models/incoai/Qwen3.8-27B-DFlash2-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
    SPEC="--spec-type draft-dflash --spec-draft-n-max 4"
    ;;
  mtp)
    # n-max 2 is the community-verified APU optimum (sudoingX/qwen38-mtp:
    # Strix Halo 11.5 -> 23.7 t/s at n-max 2; DASLab's own chart expects
    # ~54% acceptance for GSQ-RCO quants). Wide drafts reject too much.
    SPEC="--spec-type draft-mtp --spec-draft-n-max 2"
    ;;
esac

# GSQ-RCO quants of the 27B serve on the RTX PRO 6000 (CUDA build, built in
# the sglang dev container against sm_120) - fully on the dGPU per the
# dual-device serving rule. CUDA enumerates only the card, so no ICD pin
# applies here. Flash-Next stays on the APU (qwen-next gsq build via the
# dispatcher) even though its paths contain gsq-rco too; the 27B q4 fallback
# and everything else keep the APU Vulkan builds.
CUDA_BIN="$DIR/../llamacpp-mainline/build-cuda/bin/llama-server"
if [[ "${TARGET,,}" == *"gsq-rco"* && "${TARGET,,}" != *"flash-next"* && -x "$CUDA_BIN" ]]; then
  BIN="$CUDA_BIN"
  # Container-built binary: ggml/cudart/cublas/nccl libs ship in bin/.
  export LD_LIBRARY_PATH="$DIR/../llamacpp-mainline/build-cuda/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Vision projector when the quant ships one next to the target (GSQ-RCO).
MM=()
MMPROJ="$(dirname "$TARGET")/mmproj-Qwen3.8-27B-BF16.gguf"
if [[ -f "$MMPROJ" ]]; then
  MM=(--mmproj "$MMPROJ")
fi

if [[ ! -e "$TARGET" ]]; then
  echo "target model not found: $TARGET" >&2; exit 1
fi
if [[ -n "$DRAFT" && ! -e "$DRAFT" ]]; then
  echo "draft model not found: $DRAFT" >&2; exit 1
fi

# Lane shape comes from the active preset through model.json (modelctl.sh set
# propagates n_parallel / kv_unified_per_slot). A preset without them keeps the
# 2-slot default that predates per-preset lane counts, so this is a no-op for
# every preset already in presets.json.
#
# --kv-unified-per-slot N (with -c omitted) sizes the shared KV pool to
# n_parallel*N and caps each slot at N, so every lane keeps full 262144 context
# under one unified buffer (verified on the build's own README:
# tools/server/README.md, --kv-unified-per-slot). The old -np 1 --kv-unified
# setup split one 262144 pool across slots and killed long concurrent requests;
# per-slot sizing removes that split entirely.
#
# That shape costs memory LINEARLY in n_parallel. This file reserves 8.25 GiB of
# q8_0 KV + ~150 MiB GDN state per 262144 lane, so -np 2 parks ~17 GiB and -np 8
# parks ~67 GiB on top of ~13 GiB of weights. The 8-lane preset is a whole-card
# shape (llm mode); it cannot coexist with a ComfyUI working set, so lane count
# is a mode decision here, not a runtime one.
NPAR=$(jq -r '.n_parallel // 2' "$MODEL_CONF" 2>/dev/null || echo 2)
PERSLOT=$(jq -r '.kv_unified_per_slot // 262144' "$MODEL_CONF" 2>/dev/null || echo 262144)
[[ "$NPAR" =~ ^[1-9][0-9]*$ ]] || NPAR=2
[[ "$PERSLOT" =~ ^[1-9][0-9]*$ ]] || PERSLOT=262144

exec "$BIN" \
  -m "$TARGET" \
  "${MM[@]}" \
  --alias ALLMIND \
  ${DRAFT:+-md "$DRAFT"} \
  ${SPEC:+$SPEC} \
  --host 0.0.0.0 --port 6969 \
  -ngl 999 --load-mode none -fa 1 \
  --no-cache-idle-slots \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --metrics \
  -np "$NPAR" --kv-unified \
  --kv-unified-per-slot "$PERSLOT"
