#!/usr/bin/env bash
# Dispatcher for the omarchy llama-server control plane (port 6969).
# Reads the active model from ~/.config/llama-server/model.json and launches
# the right llama.cpp server for it:
#   - Qwen3.8-Flash-Next (qwen4exp) -> qwen-next build: mmap, f16 KV, PLE offload
#   - anything else (27B, etc.)     -> strix-halo build: DFlash2/MTP, q8_0 KV
# Run by the llama-server.service user unit. The widget calls
# `systemctl --user restart llama-server.service` after a model switch.
set -euo pipefail

MODEL_CONF="$HOME/.config/llama-server/model.json"
DEFAULT_STRIX="${LLAMA_STRIX_SERVE:-/home/salt/CodingProjects/llamacpp-strix-halo/serve.sh}"
QWEN_NEXT_DIR="${LLAMA_QWEN_NEXT_DIR:-/home/salt/CodingProjects/llamacpp-qwen-next}"

# Resolve the active model (default to the strix-halo Q4).
TARGET=""
if [[ -f "$MODEL_CONF" ]]; then
  TARGET=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
fi
[[ -n "$TARGET" && -f "$TARGET" ]] || TARGET="${LLAMA_DEFAULT_MODEL:-/home/salt/.lmstudio/models/unsloth/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_XL.gguf}"

# Flash-Next (qwen4exp arch) needs a qwen4exp-capable build. Two variants:
#   - ROCmFP4 quants -> LaurentZuijdwijk fork (vulkan/qwen4exp-rocmfpx)
#   - mainline quants (Q3_K_XL etc.) -> mainline + PR27742 build
if [[ "${TARGET,,}" == *"rocmfp4"* ]]; then
  exec "${LLAMA_ROCMFPX_SERVE:-/home/salt/CodingProjects/llamacpp-rocmfpx/serve.sh}"
fi
if [[ "${TARGET,,}" == *"gsq-rco"* ]]; then
  exec "$QWEN_NEXT_DIR/serve-gsqrco.sh"
fi
if [[ "${TARGET,,}" == *"flash-next"* ]]; then
  if [[ "${TARGET,,}" == *"uncensored"* ]]; then
    exec "$QWEN_NEXT_DIR/serve-uncensored.sh"
  fi
  exec "$QWEN_NEXT_DIR/serve.sh"
fi

# Everything else runs through the strix-halo serve.sh (reads model.json itself).
exec "$DEFAULT_STRIX"
