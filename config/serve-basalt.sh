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
mv "$CFGFILE.tmp" "$CFGFILE"
jq -e . "$CFGFILE" >/dev/null

# The journal is the only forensic trail for a load: print the shape it will
# boot with, exactly as written.
echo "serve-basalt: $CONTAINER from $CONTAINER_PACK on :$PORT"
sed 's/^/serve-basalt:   /' "$CFGFILE"

exec docker run --rm --init --name "$CONTAINER" \
  --gpus all \
  --ulimit memlock=-1 \
  --log-opt max-size=10m --log-opt max-file=3 \
  -p "$PORT:$PORT" \
  -v "$MODELS_DIR:/models:ro" \
  -v "$APPDATA:/data" \
  "$IMAGE"
