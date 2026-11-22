#!/usr/bin/env bash
# Basalt backend launcher for the omallama control plane (port 6969).
#
# Same control contract as the other backends: the active model comes from
# ~/.config/llama-server/model.json, the served name is ALLMIND so existing
# clients keep sending the same id, and the widget drives this through
# `systemctl --user restart llama-server.service`.
#
# Differences forced by the runtime:
#   - model.json ".model" is the path of a .basalt pack, read where it lies
#     (the engine mmaps it; nothing is copied). It has to sit under the
#     models/ directory that is bind-mounted at /models.
#   - Basalt is configured by ONE JSON file. It is regenerated from model.json
#     on every launch into <root>/appdata/basalt_config.json, which is both
#     the /data mount and the container's HOME (the server keeps its engine
#     log and conversation disk tier under $HOME/.cache/basalt).
#   - /health answers 200 with a JSON body while a pack is still loading
#     ("loaded": false), so monitor.sh gates on that flag instead of the
#     status code. /metrics is JSON, not Prometheus text, so the widget shows
#     no tok/s for this backend until monitor.sh learns that shape.
#
# Image: upstream's Dockerfile (docs/platforms.md#container-image), built
# locally with the build stage capped at -j10 for this host's RAM budget. See
# <root>/Dockerfile.omallama. One tag per engine version on disk: v0.3.3 (the
# first Basalt here) and v0.4.0 (which added the F8_E4M3 / NVFP4_PLANES tensor
# types the dense 27B pack needs). The .basalt format is v2 in both, so a
# preset names the image it needs with `basalt_image` and the MoE packs can
# stay on whichever engine last proved itself.
#
# A pack larger than the card (NVFP4-DQ6_K is 131.7 GB against 95.6 GiB of
# VRAM) leaves the remainder of the experts to the RAM tier and the SSD; the
# engine decides that itself from free RAM at load. --ulimit memlock=-1 is
# there because that tier is page-locked host memory and the container's
# default 64 MiB memlock limit would cap it.
set -euo pipefail

MODEL_CONF="$HOME/.config/llama-server/model.json"
BASALT_ROOT="${BASALT_ROOT:-$HOME/egpu-nvidia-setup/basalt}"
# BASALT_IMAGE (env) beats the preset's basalt_image, which beats the current
# engine. So a bad upgrade is one variable away from being undone, and a pack
# needing a newer engine does not force every other pack onto it.
IMAGE="${BASALT_IMAGE:-$(jq -r '.basalt_image // empty' "$MODEL_CONF" 2>/dev/null || true)}"
IMAGE="${IMAGE:-basalt:v0.5.5}"
CONTAINER="basalt-llm"
PORT="${BASALT_PORT:-6969}"
SERVED_NAME="${BASALT_SERVED_NAME:-ALLMIND}"
MODELS_DIR="$BASALT_ROOT/models"
APPDATA="$BASALT_ROOT/appdata"
CFGFILE="$APPDATA/basalt_config.json"

DEFAULT_PACK="$MODELS_DIR/Qwen3.8-FN-NVFP4-DQ6_K.basalt"

# --- active pack ------------------------------------------------------------
TARGET=$(jq -r '.model // empty' "$MODEL_CONF" 2>/dev/null || true)
[[ -n "$TARGET" ]] || TARGET="$DEFAULT_PACK"
if [[ ! -f "$TARGET" ]]; then
  echo "serve-basalt: pack not found: $TARGET" >&2
  exit 1
fi
case "$TARGET" in
  "$MODELS_DIR"/*) CONTAINER_PACK="/models/${TARGET#"$MODELS_DIR"/}" ;;
  *)
    echo "serve-basalt: pack is outside the /models mount: $TARGET" >&2
    echo "              move it under $MODELS_DIR or set BASALT_ROOT" >&2
    exit 1
    ;;
esac

# --- config v2, generated from the preset keys modelctl propagated ----------
# Only keys the preset actually declares are written: Basalt's defaults are
# its own fastest machine-agnostic settings, and a wrong block or unknown name
# stops the start.
mkdir -p "$APPDATA"
jq --arg model "$CONTAINER_PACK" --arg alias "$SERVED_NAME" --argjson port "$PORT" '
  . as $m
  | {
      version: 2,
      models: [ { model: $model, alias: $alias }
        + (if $m.kv             != null then { kv: $m.kv } else {} end)
        + (if $m.parallel       != null then { parallel: $m.parallel } else {} end)
        + (if $m.vision         != null then { vision: $m.vision } else {} end)
        + (if $m.slot_full_context != null then { "slot-full-context": $m.slot_full_context } else {} end)
        + (if $m.fit_max_tokens != null then { "fit-max-tokens": $m.fit_max_tokens } else {} end) ],
      engine: ( {}
        + (if $m.max_context         != null then { "max-context": $m.max_context } else {} end)
        + (if $m.kv                  != null then { kv: $m.kv } else {} end)
        + (if $m.parallel            != null then { parallel: $m.parallel } else {} end)
        + (if $m.expert_cache        != null then { "expert-cache": $m.expert_cache } else {} end)
        + (if $m.prefill             != null then { prefill: $m.prefill } else {} end)
        + (if $m.spec_window         != null then { spec: $m.spec_window } else {} end)
        + (if $m.resident_experts    != null then { "resident-experts": $m.resident_experts } else {} end)
        + (if $m.resident_budget_gib != null then { "resident-budget-gib": $m.resident_budget_gib } else {} end)
        + (if $m.ram_reserve_mib     != null then { "ram-reserve-mib": $m.ram_reserve_mib } else {} end)
        + (if $m.vram_reserve_mib    != null then { "vram-reserve-mib": $m.vram_reserve_mib } else {} end)
        + (if $m.kv_resident         != null then { "kv-resident": $m.kv_resident } else {} end)
        + (if $m.prompt_cache        != null then { "prompt-cache": $m.prompt_cache } else {} end) ),
      server: { port: $port }
    }' "$MODEL_CONF" > "$CFGFILE.tmp"
# Validate the render BEFORE replacing the previous good config: cardmode
# reads basalt_config.json as the running pack's identity, so a malformed
# render must never displace the good file. jq -e exits non-zero here and
# set -e aborts the boot with the old config intact.
jq -e . "$CFGFILE.tmp" >/dev/null
mv "$CFGFILE.tmp" "$CFGFILE"

# The journal is the only forensic trail for a load: print the shape it will
# boot with, exactly as written.
echo "serve-basalt: $CONTAINER from $CONTAINER_PACK on :$PORT"
sed 's/^/serve-basalt:   /' "$CFGFILE"

# --- card handoff backstop: same contract as serve-sglang.sh ------------------
# cardmode's gate covers reconciler-driven switches; this covers the MANUAL
# widget path into the llm shape, which otherwise loads a basalt pack onto a
# card ComfyUI still holds: starved malloc + Restart=no = dead unit.
# Which boots are the llm shape? cardmode itself derives the card's mode from
# the preset NAME in model.json, so use the same name-match. No name (bare
# path selection) or a nameless modes.json fail toward gating (the card's side).
CFG_DIR="$HOME/.config/llama-server"
LLM_PRESET=$(jq -r '.modes.llm.preset // empty' "$CFG_DIR/modes.json" 2>/dev/null || true)
SEL_NAME=$(jq -r '.name // empty' "$MODEL_CONF" 2>/dev/null || true)
if [[ -z "$LLM_PRESET" || -z "$SEL_NAME" || "$SEL_NAME" == "$LLM_PRESET" ]]; then
  COMFY_URL="${COMFY_URL:-http://127.0.0.1:8189}"
  MIN_FREE_MIB=$(jq -r '.sglang_min_free_mib // 90000' "$CFG_DIR/modes.json" 2>/dev/null || echo 90000)
  curl -sf --max-time 10 -X POST "$COMFY_URL/free" \
    -H 'content-type: application/json' \
    -d '{"unload_models": true, "free_memory": true}' >/dev/null 2>&1 || true
  for _ in $(seq 1 18); do
    FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
    [[ -z "$FREE_MIB" ]] && break                    # no card/no nvidia-smi: proceed
    (( FREE_MIB >= MIN_FREE_MIB )) && break
    echo "serve-basalt: card handoff: free ${FREE_MIB} MiB < ${MIN_FREE_MIB} MiB, waiting" >&2
    sleep 5
  done
else
  echo "serve-basalt: '$SEL_NAME' is not the llm preset ('$LLM_PRESET'): gen shape, no handoff needed" >&2
fi

# A stale container from a previous run would hold the port and the card, and
# the name clash fails the unit with a container name in the journal, not the
# cause (serve-sglang/serve-gufo pre-clean the same way).
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "serve-basalt: removing leftover container $CONTAINER" >&2
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
fi

exec docker run --rm --init --name "$CONTAINER" \
  --gpus all \
  --ulimit memlock=-1 \
  --log-opt max-size=10m --log-opt max-file=3 \
  -p "$PORT:$PORT" \
  -v "$MODELS_DIR:/models:ro" \
  -v "$APPDATA:/data" \
  "$IMAGE"
