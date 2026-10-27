#!/usr/bin/env bash
# Manage cardmode policy knobs in ~/.config/llama-server/modes.json.
# Backs the salt.llama-server omarchy widget's config panel (the gear icon).
#
# cardmode.service re-reads modes.json every loop (load_cfg in cardmode.py),
# so a written file takes effect on the next iteration -- no restart needed.
# The reconciler only ever WRITES its own state file (.cardmode.json); modes.json
# is the operator's policy file, so writing it here is safe.
#
# Commands:
#   modesctl.sh show                 -> print current modes.json verbatim
#   modesctl.sh save '<json>'        -> deep-merge <json> into modes.json
#   modesctl.sh set <key> <jsonval>  -> set one top-level key (json value)
#
# Every write is atomic and drops a timestamped backup next to the file.
set -euo pipefail

CFG_DIR="${LLAMA_CFG_DIR:-$HOME/.config/llama-server}"
MODES="$CFG_DIR/modes.json"

ensure_config() {
  mkdir -p "$CFG_DIR"
  [[ -f "$MODES" ]] || echo '{}' > "$MODES"
}

backup() { cp -a "$MODES" "$MODES.bak.$(date +%Y%m%d%H%M%S)"; }

atomic_write() {
  # atomic_write <src-json-file>  (moves src onto MODES after backup)
  backup
  mv "$1" "$MODES"
}

case "${1:-}" in
  show)
    ensure_config
    cat "$MODES"
    ;;
  save)
    ensure_config
    blob="${2:-}"
    [[ -n "$blob" ]] || { echo "usage: modesctl.sh save '<json>'" >&2; exit 1; }
    # Validate the incoming blob before it touches disk.
    echo "$blob" | jq empty 2>/dev/null || { echo "invalid json" >&2; exit 1; }
    tmp="$MODES.tmp.$$"
    # Deep merge: existing first, incoming overrides (modes.{llm,gen} nest through).
    jq -s '.[0] * .[1]' "$MODES" <(echo "$blob") > "$tmp"
    atomic_write "$tmp"
    echo "saved"
    ;;
  set)
    ensure_config
    key="${2:-}"; val="${3:-}"
    [[ -n "$key" ]] || { echo "usage: modesctl.sh set <key> <json-value>" >&2; exit 1; }
    echo "$val" | jq empty 2>/dev/null || { echo "invalid json value" >&2; exit 1; }
    tmp="$MODES.tmp.$$"
    jq --arg key "$key" --argjson v "$val" '.[$key] = $v' "$MODES" > "$tmp"
    atomic_write "$tmp"
    echo "set $key"
    ;;
  *)
    echo "usage: modesctl.sh {show|save '<json>'|set <key> <json-value>}" >&2
    exit 1
    ;;
esac
