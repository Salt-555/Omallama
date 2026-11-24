#!/usr/bin/env bash
# Omallama installer: Omarchy bar widget + control plane for llama.cpp servers.
#
# Copies the plugin into ~/.config/omarchy/plugins/salt.llama-server and the
# control-plane config into ~/.config/llama-server, then rescans the shell.
# NOTHING that already exists is overwritten — plugin code, launchers, probe,
# cardmode daemon, units, and config alike are all skipped when present.
# Re-running is always safe; it can never downgrade a live box from a stale
# checkout. To upgrade a file deliberately: delete it and re-run (or cp from
# the checkout yourself).
#
# Per Omarchy semantics this script deliberately does NOT call
# `omarchy plugin enable`: enable goes over IPC to the running shell and
# rewrites shell.json, which can move the widget. Run
#   omarchy plugin enable salt.llama-server
# once yourself if the widget is not already in your bar.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="salt.llama-server"
PLUGIN_DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
CFG_DST="${LLAMA_CFG_DIR:-$HOME/.config/llama-server}"

# Guarded copy: install only when the destination does not exist yet.
# Never overwrite, never downgrade. Usage: install_keep <src> <dst> [chmodx]
install_keep() {
  local src="$1" dst="$2" mode="${3:-}"
  if [[ -e "$dst" ]]; then
    echo "    $(basename "$dst") exists, left untouched"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp -v "$src" "$dst"
  [[ "$mode" == "+x" ]] && chmod +x "$dst"
  return 0
}

echo "==> installing plugin -> $PLUGIN_DST"
mkdir -p "$PLUGIN_DST"
for f in manifest.json BarWidget.qml Panel.qml modelctl.sh monitor.sh modesctl.sh llmlimits.sh llm-door.sh; do
  case "$f" in
    *.sh)  install_keep "$SRC/plugin/$f" "$PLUGIN_DST/$f" +x ;;
    *)     install_keep "$SRC/plugin/$f" "$PLUGIN_DST/$f" ;;
  esac
done

echo "==> installing control plane -> $CFG_DST"
for f in serve.sh serve-gufo.sh serve-sglang.sh serve-basalt.sh probe.sh llm-queue.py; do
  install_keep "$SRC/config/$f" "$CFG_DST/$f" +x
done
install_keep "$SRC/config/presets.example.json" "$CFG_DST/presets.json"
install_keep "$SRC/config/modes.example.json" "$CFG_DST/modes.json"

echo "==> installing cardmode (Blackwell card-mode reconciler + comfy gate)"
install_keep "$SRC/cardmode/cardmode.py" "$HOME/.local/lib/omallama-cardmode/cardmode.py"
install_keep "$SRC/cardmode/nginx.conf" "$HOME/.config/cardmode/nginx.conf"
# The door include ships DISABLED (llm-door.sh enable writes the server block).
# The queueing gateway's state file is created on first run; lanes default to
# unlimited until the operator sets them in the widget.
install_keep "$SRC/cardmode/llm-door-6969.conf" "$HOME/.config/cardmode/llm-door-6969.conf"
install_keep "$SRC/cardmode/cardmode.service" "$HOME/.config/systemd/user/cardmode.service"
install_keep "$SRC/cardmode/cardmode-proxy.service" "$HOME/.config/systemd/user/cardmode-proxy.service"
install_keep "$SRC/config/llm-queue.service" "$HOME/.config/systemd/user/llm-queue.service"

echo "==> systemd user unit"
install_keep "$SRC/config/llama-server.service" "$HOME/.config/systemd/user/llama-server.service"
systemctl --user daemon-reload

echo "==> validating plugin"
omarchy plugin validate "$PLUGIN_DST"

omarchy-shell shell rescanPlugins 2>/dev/null || true

echo
echo "Done. If the widget is not in your bar yet:"
echo "  omarchy plugin enable $PLUGIN_ID"
echo "Then point the dispatcher's routes at your llama.cpp builds (see README)."
