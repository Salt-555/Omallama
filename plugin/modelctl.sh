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
# spec rule AND the backend rule live; serve.sh consumes whatever spec/backend
# values land in model.json (it accepts legacy DFlash2/MTP spellings too).
#
# Backend (backend_for/resolve_backend): gufo-compliant artifacts (gufo-org's
# curated targets: unsloth Flash-Next UD-Q4_K_XL, unsloth 27B UD-*, antirez
# deepseek-v4) run on the Gufo runtime via ~/.config/llama-server/serve-gufo.sh;
# everything else runs a llama.cpp build. A preset may pin {"backend":"gufo"} or
# {"backend":"llama"} to override the path rule.
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
    *gsq-rco*)     echo "mtp" ;;
    *qwen3.8-27b*) echo "dflash" ;;
    *rocmfp4*)     echo "mtp" ;;
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

# backend_for <model-path> -> gufo|llama|basalt. SGLang is never reached here:
# it is always chosen by an explicit preset "backend", since its target is a
# repo id rather than a path. Gufo runs gufo-org's curated
# artifacts on their own Strix Halo runtime; a .basalt pack runs the Basalt
# engine; every other quant/fork stays on a llama.cpp build. Keep this list in
# sync with gufo's docs/models table.
backend_for() {
  local p="${1,,}"
  case "$p" in
    *.basalt)                                      echo "basalt" ;;
    *unsloth/qwen3.8-flash-next-gguf/ud-q4_k_xl/*) echo "gufo" ;;
    *unsloth/qwen3.8-27b-gguf/ud-*)                echo "gufo" ;;
    */antirez/deepseek-v4-gguf/*)                  echo "gufo" ;;
    *)                                             echo "llama" ;;
  esac
}

# resolve_backend <name|path> [<resolved-path>] -> gufo|llama|sglang|basalt.
# The preset's explicit "backend" wins; else the path rule from backend_for.
resolve_backend() {
  local sel="${1:-}" path="${2:-${1:-}}" ov=""
  ov=$(jq -r --arg n "$sel" --arg p "$path" \
    '.[] | select(.exclude != true and (.name == $n or .model == $n or .model == $p)) | (.backend // "")' \
    "$PRESETS" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]')
  case "$ov" in
    gufo|llama|sglang|basalt) echo "$ov"; return ;;
  esac
  backend_for "$path"
}

# is_excluded <path> -> 0 when presets.json marks the path exclude:true
is_excluded() {
  jq -e --arg p "$1" 'any(.[]; .exclude == true and .model == $p)' "$PRESETS" >/dev/null 2>&1
}

# discover_models -> name<TAB>path<TAB>spec per servable model on disk
# (.basalt packs are discovered too: a Basalt preset must be selectable from
# the widget, and backend_for routes a bare pack to the Basalt engine by
# extension, never to a llama.cpp build).
discover_models() {
  find "$DISCOVER_ROOT" -type f \( -name '*.gguf' -o -name '*.basalt' \) 2>/dev/null | sort | while read -r f; do
    base="${f##*/}"
    case "$base" in
      mmproj-*|*-draft.gguf|mtp-*) continue ;;
      *-00001-of-*) : ;;          # first shard of a split model: keep
      *-of-*.gguf) continue ;;    # later shards: llama.cpp finds them
    esac
    is_excluded "$f" && continue
    name="${base%.gguf}"
    name=$(printf '%s' "$name" | sed -E 's/-00001-of-[0-9]+$//')
    # One row per preset that names this file, not one row per file: two
    # presets can share one GGUF with different shapes (the 27B serves a 2-slot
    # gen shape and an 8-slot llm shape from the same file), and keeping only
    # the first label made the second unselectable from the widget. Safe
    # because the dropdown's selector is parts[0] -- the preset NAME -- so
    # duplicated paths never collide, and model.json records .name for the
    # round-trip. A file no preset claims still gets a bare-filename row.
    claims=$(jq -r --arg p "$f" \
      '.[] | select(.model == $p and (.exclude != true))
       | [(.name // ""), (.spec // "")] | @tsv' "$PRESETS" 2>/dev/null)
    if [[ -n "$claims" ]]; then
      while IFS=$'\t' read -r oname ospec; do
        [[ -n "$oname$ospec" ]] || continue
        printf '%s\t%s\t%s\n' "${oname:-$name}" "$f" "${ospec:-$(spec_for "$f")}"
      done <<< "$claims"
    else
      printf '%s\t%s\t%s\n' "$name" "$f" "$(spec_for "$f")"
    fi
  done
  # Presets whose target is not a file here never match the find above, so they
  # would be invisible in the widget's dropdown -- which is exactly the case for
  # the SGLang preset, whose "model" is a HuggingFace repo id the container
  # pulls itself. Emit those from the preset list directly.
  jq -r '.[] | select(.exclude != true) | select((.backend // "") != "")
         | [ (.name // ""), .model, (.spec // "") ] | @tsv' "$PRESETS" 2>/dev/null \
  | while IFS=$'\t' read -r l m sp; do
      [[ -n "$l" && -n "$m" ]] || continue
      # A real file UNDER THE DISCOVERY ROOT was already emitted by the find
      # above. Anything else is reachable only from its preset: SGLang's repo
      # id, and a .basalt pack outside the root (ours lives in
      # ~/egpu-nvidia-setup/basalt/models, which the find never walks).
      [[ -f "$m" && "$m" == "$DISCOVER_ROOT"/* ]] && continue
      printf '%s\t%s\t%s\n' "$l" "$m" "${sp:-}"
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
    # The preset's declared backend decides whether the target must exist as a
    # file here. The SGLang preset's "model" is a HuggingFace repo id that the
    # container pulls for itself, so BOTH the file test and the on-disk
    # discovery fallback are skipped for it -- checking after the fact is too
    # late, because the discovery fallback has already overwritten the id with
    # an empty hit. Every GGUF backend keeps the strict path check.
    sel_backend=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | (.backend // "")' "$PRESETS" 2>/dev/null | head -1)
    resolved=""
    if [[ -f "$sel" ]]; then
      resolved="$sel"
    else
      # override name first, then a generated discovery name
      resolved=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | .model' "$PRESETS" 2>/dev/null | head -1)
      if [[ "$sel_backend" != "sglang" ]]; then
        [[ -n "$resolved" && -f "$resolved" ]] || \
          resolved=$(discover_models | awk -F'\t' -v n="$sel" '$1 == n {print $2; exit}')
      fi
    fi
    if [[ "$sel_backend" == "sglang" ]]; then
      [[ -n "$resolved" ]] || { echo "sglang preset has no model id: $sel" >&2; exit 1; }
    elif [[ -z "$resolved" || ! -f "$resolved" ]]; then
      echo "model not found: $sel" >&2; exit 1
    fi
    # The selection (preset name when given) carries the intent; the path alone
    # cannot tell a dflash preset from an mtp one of the same model.
    spec=$(resolve_spec "$sel")
    backend=$(resolve_backend "$sel" "$resolved")
    # Record the preset name too so the UI can round-trip the selection even
    # when two presets share one path with different specs.
    name=$(jq -r --arg n "$sel" '.[] | select(.name == $n) | .name' "$PRESETS" 2>/dev/null | head -1)
    jq -n --arg m "$resolved" --arg s "$spec" --arg n "$name" --arg b "$backend" \
      '{model: $m, spec: $s, backend: $b} + (if $n != "" then {name: $n} else {} end)' > "$MODEL"
    # Preset tuning keys (SGLang: context_length, max_total_tokens,
    # max_running_requests, max_mamba_cache_size, mem_fraction_static,
    # kv_cache_dtype, speculative, rope_parameters; llama.cpp: n_parallel,
    # kv_unified_per_slot) must survive into model.json: the launchers read
    # them from THERE, not from presets. A preset without them keeps the
    # launcher's own defaults. cardmode.ready_for compares the running
    # server's /props total_slots against the preset's n_parallel, so these
    # two keys have to propagate like the SGLang ones do.
    # Every preset key rides along EXCEPT the control keys (name, model,
    # backend, exclude) and the llama.cpp drafter kind, which resolve_spec
    # derives. This used to be a whitelist of 19 names, and a knob nobody
    # remembered to add was dropped SILENTLY: the launcher reads model.json,
    # so the only symptom was a flag that never took effect.
    jq --arg n "$sel" -s '
      .[0] as $model | .[1] as $presets
      | ($presets | map(select(.name == $n))[0] // {}) as $p
      | reduce ($p | keys_unsorted[]) as $k
        ($model;
         if ($k == "name" or $k == "model" or $k == "backend"
             or $k == "exclude" or $k == "spec")
         then . else .[$k] = $p[$k] end)
    ' "$MODEL" "$PRESETS" > "$MODEL.tmp" && mv "$MODEL.tmp" "$MODEL"
    echo "$resolved"
    ;;
  resolve-backend)
    ensure_config
    resolve_backend "${2:-}" "${3:-${2:-}}"
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
    echo "usage: modelctl.sh {presets|current|set <name|path>|add <path> [name]|resolve-backend <name|path> [path]}" >&2
    exit 1
    ;;
esac
