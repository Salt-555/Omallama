#!/usr/bin/env bash
# Dispatcher for the omarchy llama-server control plane (port 6969).
# Reads the active model from ~/.config/llama-server/model.json and launches
# the right backend for it:
#   - backend "sglang"           -> SGLang (serve-sglang.sh, containerized)
#   - gufo-compliant artifacts   -> Gufo runtime (serve-gufo.sh, containerized)
#   - Qwen3.8-Flash-Next (qwen4exp) -> qwen-next build: mmap, f16 KV, PLE offload
#   - anything else (27B, etc.)     -> strix-halo build: DFlash2/MTP, q8_0 KV
# Run by the llama-server.service user unit. The widget calls
# `systemctl --user restart llama-server.service` after a model switch.
#
# Backend dispatch order matters: the SGLang and Gufo backends take an
# identifier or an artifact path that need not exist as a file on this host
# (SGLang's is a HuggingFace repo id), so they are resolved from `.backend`
# BEFORE the file-exists fallback below.
set -euo pipefail

# Diagnostics: RADV writes a full GPU hang report (shader state, queue dumps)
# to ~/.local/share/radv/ when the device resets. Pair with the devcoredump
# udev capture for kernel-side evidence.
export RADV_DEBUG="${RADV_DEBUG:+$RADV_DEBUG,}hang"

MODEL_CONF="$HOME/.config/llama-server/model.json"
DEFAULT_STRIX="${LLAMA_STRIX_SERVE:-$HOME/CodingProjects/llamacpp-strix-halo/serve.sh}"
QWEN_NEXT_DIR="${LLAMA_QWEN_NEXT_DIR:-$HOME/CodingProjects/llamacpp-qwen-next}"
MODELCTL="$HOME/.config/omarchy/plugins/salt.llama-server/modelctl.sh"

# Resolve the active model and the backend, in that order, so an explicit
# `backend` in model.json always wins over the path rules.
TARGET=""
BACKEND=""
NAME=""
if [[ -f "$MODEL_CONF" ]]; then
  TARGET=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
  BACKEND=$(jq -r '.backend // empty' "$MODEL_CONF" 2>/dev/null || true)
  NAME=$(jq -r '.name // empty' "$MODEL_CONF" 2>/dev/null || true)
fi

# An explicit backend that takes a non-path target, dispatched before any
# file test. modelctl.sh owns the backend rules; model.json carries the
# resolved value from `modelctl.sh set`.
if [[ "${BACKEND,,}" == "sglang" ]]; then
  exec "$HOME/.config/llama-server/serve-sglang.sh"
fi

# Basalt takes a .basalt pack path that does exist, but the dispatcher has to
# choose it BEFORE the GGUF build rules below, which would otherwise claim a
# Flash-Next-named pack for a llama.cpp build. The pack is read where it lies
# (see serve-basalt.sh for the /models mount contract).
if [[ "${BACKEND,,}" == "basalt" ]]; then
  exec "$HOME/.config/llama-server/serve-basalt.sh"
fi

# No silent substitution: booting a hardcoded default because the selected
# file vanished serves a model nobody chose, under the selected preset's
# widget label, aliasing as ALLMIND so identity checks pass. serve-sglang and
# serve-basalt already refuse this; so does the plane everywhere else.
# LLAMA_DEFAULT_MODEL stays an explicit opt-in override, never a guess.
if [[ -z "$TARGET" || ! -f "$TARGET" ]]; then
  if [[ -n "${LLAMA_DEFAULT_MODEL:-}" && -f "$LLAMA_DEFAULT_MODEL" ]]; then
    TARGET="$LLAMA_DEFAULT_MODEL"
  else
    echo "serve: selected model file missing: '${TARGET:-<none in model.json>}'" >&2
    echo "       pick a model in the panel or fix model.json; not booting a default." >&2
    exit 1
  fi
fi

# Gufo-compliant artifacts run on gufo-org's own Strix Halo runtime instead of
# a llama.cpp build. The backend rule lives in modelctl.sh (resolve-backend);
# a preset's explicit "backend" override wins there. model.json carries the
# resolved value from `modelctl.sh set`, recomputed here as a fallback for
# configs written before the backend field existed.
if [[ -z "$BACKEND" && -x "$MODELCTL" ]]; then
  # Pass the preset NAME as the selector: a preset that pins "backend" by
  # name is otherwise invisible to the recompute, and the path rule silently
  # decides. Falls back to the path for nameless legacy files.
  BACKEND=$("$MODELCTL" resolve-backend "${NAME:-$TARGET}" "$TARGET" 2>/dev/null || true)
fi
if [[ "${BACKEND,,}" == "gufo" ]]; then
  exec "$HOME/.config/llama-server/serve-gufo.sh"
fi

# Flash-Next (qwen4exp arch) needs a qwen4exp-capable build. Two variants:
#   - ROCmFP4 quants -> LaurentZuijdwijk fork (vulkan/qwen4exp-rocmfpx)
#   - mainline quants (Q3_K_XL etc.) -> mainline + PR27742 build
if [[ "${TARGET,,}" == *"rocmfp4"* ]]; then
  exec "${LLAMA_ROCMFPX_SERVE:-$HOME/CodingProjects/llamacpp-rocmfpx/serve.sh}"
fi
# GSQ-RCO quants of Flash-Next (qwen4exp arch) need the qwen-next build; the
# 27B GSQ-RCO (qwen35 arch) runs on the strix-halo build below.
if [[ "${TARGET,,}" == *"gsq-rco"* && "${TARGET,,}" == *"flash-next"* ]]; then
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
