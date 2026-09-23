#!/usr/bin/env bash
# Manage the llama.cpp server (port 6969) active model + presets.
# Backs the omarchy salt.llama-server widget. Reads/writes
#   ~/.config/llama-server/presets.json   (overrides for discovered models:
#                                          {name?, spec?, model} to rename or
#                                          pin a spec, {model, exclude: true}
#                                          to hide a file from the picker)
#   ~/.config/llama-server/model.json     (active {model, spec?, name?}; name
#                                          records the chosen preset's name)
#
# The model list is DISCOVERED from disk (~/.lmstudio/models) on every call, so
# the widget's dropdown always matches what is actually present:
#   modelctl.sh presets              -> name<TAB>path<TAB>spec (spec empty if none)
#   modelctl.sh current              -> print active model path
#   modelctl.sh resolve-spec <sel>   -> dflash|mtp|(empty) for a name or path
#   modelctl.sh set <name|path>      -> write active model + spec (+name) to model.json
#   modelctl.sh add <path> [name]    -> record a name/spec override for a path
#
# Discovery skips projector and draft files (mmproj-*, *-draft, mtp-*) and
# keeps only the first shard of a split model. This file is the ONLY place the
# spec rule lives; serve.sh consumes whatever spec value lands in model.json
# (it accepts legacy DFlash2/MTP spellings too).
set -u

CFG_DIR="${LLAMA_CFG_DIR:-$HOME/.config/llama-server}"
PRESETS="$CFG_DIR/presets.json"
MODEL="$CFG_DIR/model.json"
DISCOVER_ROOT="${LLAMA_MODELS_DIR:-$HOME/.lmstudio/models}"

ensure_config() {
  mkdir -p "$CFG_DIR"
  [[ -f "$PRESETS" ]] || echo '[]' > "$PRESETS"
  [[ -f "$MODEL" ]]   || echo '{}'  > "$MODEL"
}

spec_for() {
  # spec_for <model-path> -> dflash|mtp|(empty). Last-resort filename guess,
  # used only when the preset names no spec of its own.
  local p="${1,,}"
  case "$p" in
    *dflash2*)     echo "dflash" ;;
    *qwen3.8-27b*) echo "dflash" ;;
    *rocmfp4*)     echo "mtp" ;;
    *gsq-rco*)     echo "mtp" ;;
    *)             echo "" ;;
  esac
}

resolve_spec() {
  # resolve_spec <name|path> -> the preset's own spec wins; else filename guess.
  local sel="$1" spec=""
  spec=$(jq -r --arg n "$sel" \
    '.[] | select(.name == $n or .model == $n) | (.spec // "")' "$PRESETS" 2>/dev/null \
    | head -1 | tr '[:upper:]' '[:lower:]')
  case "$spec" in
    dflash|*dflash2*) echo dflash; return ;;
    mtp)                      echo mtp;    return ;;
  esac
  spec_for "$sel"
}

# is_excluded <path> -> 0 when presets.json marks the path exclude:true
is_excluded() {
  jq -e --arg p "$1" 'any(.[]; .exclude == true and .model == $p)' "$PRESETS" >/dev/null 2>&1
}

# discover_models -> name<TAB>path<TAB>spec per servable model on disk
discover_models() {
  find "$DISCOVER_ROOT" -name '*.gguf' -type f 2>/dev/null | sort | while read -r f; do
    base="${f##*/}"
    case "$base" in
      mmproj-*|*-draft.gguf|mtp-*) continue ;;
      *-00001-of-*) : ;;          # first shard of a split model: keep
      *-of-*.gguf) continue ;;    # later shards: llama.cpp finds them
    esac
    is_excluded "$f" && continue
    name="${base%.gguf}"
    name=$(printf '%s' "$name" | sed -E 's/-00001-of-[0-9]+$//')
    IFS=$'\t' read -r oname ospec < <(jq -r --arg p "$f" \
      '.[] | select(.model == $p and (.exclude != true)) | [(.name // ""), (.spec // "")] | @tsv' \
      "$PRESETS" 2>/dev/null | head -1)
    label="${oname:-$name}"
    spec="${ospec:-$(spec_for "$f")}"
    printf '%s\t%s\t%s\n' "$label" "$f" "$spec"
  done
}

case "${1:-}" in
  presets)
    ensure_config
    discover_models
    ;;
  current)
    ensure_config
    m=$(jq -r '.model // empty' "$MODEL" 2>/dev/null || true)
    if [[ -z "$m" || ! -f "$m" ]]; then
      # fall back to the first discovered model on disk
      m=$(discover_models | head -1 | cut -f2)
    fi
    echo "$m"
    ;;
  set)
    ensure_config
    sel="${2:-}"
    [[ -n "$sel" ]] || { echo "usage: modelctl.sh set <name|path>" >&2; exit 1; }
    resolved=""
    if [[ -f "$sel" ]]; then
      resolved="$sel"
    else
      # override name first, then a generated discovery name
      resolved=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | .model' "$PRESETS" 2>/dev/null | head -1)
      [[ -n "$resolved" && -f "$resolved" ]] || \
        resolved=$(discover_models | awk -F'\t' -v n="$sel" '$1 == n {print $2; exit}')
    fi
    if [[ -z "$resolved" || ! -f "$resolved" ]]; then
      echo "model not found: $sel" >&2; exit 1
    fi
    # The selection (preset name when given) carries the intent; the path alone
    # cannot tell a dflash preset from an mtp one of the same model.
    spec=$(resolve_spec "$sel")
    # Record the preset name too so the UI can round-trip the selection even
    # when two presets share one path with different specs.
    name=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | .name' "$PRESETS" 2>/dev/null | head -1)
    jq -n --arg m "$resolved" --arg s "$spec" --arg n "$name" \
      '{model: $m, spec: $s} + (if $n != "" then {name: $n} else {} end)' > "$MODEL"
    echo "$resolved"
    ;;
  resolve-spec)
    ensure_config
    resolve_spec "${2:-}"
    ;;
  add)
    ensure_config
    path="${2:-}"
    name="${3:-}"
    [[ -f "$path" ]] || { echo "model file not found: $path" >&2; exit 1; }
    [[ -n "$name" ]] || name="$(basename "$path" .gguf)"
    spec=$(spec_for "$path")
    # dedupe by model path
    if jq -e --arg p "$path" 'any(.[]; .model == $p)' "$PRESETS" >/dev/null 2>&1; then
      jq --arg n "$name" --arg p "$path" --arg s "$spec" \
        'map(if .model == $p then .name = $n | .spec = $s else . end)' "$PRESETS" > "$PRESETS.tmp" && mv "$PRESETS.tmp" "$PRESETS"
    else
      jq --arg n "$name" --arg p "$path" --arg s "$spec" \
        '. + [{name: $n, model: $p, spec: $s}]' "$PRESETS" > "$PRESETS.tmp" && mv "$PRESETS.tmp" "$PRESETS"
    fi
    echo "added: $name -> $path (spec: ${spec:-none})"
    ;;
  *)
    echo "usage: modelctl.sh {presets|current|set <name|path>|add <path> [name]}" >&2
    exit 1
    ;;
esac
