#!/usr/bin/env bash
# Omallama installer: Omarchy bar widget + control plane for llama.cpp servers.
#
# Copies the plugin into ~/.config/omarchy/plugins/salt.llama-server and the
# control-plane config into ~/.config/llama-server, then rescans the shell.
# Existing config (presets.json, model.json, serve.sh) is NEVER overwritten —
# re-running is safe and only refreshes plugin code.
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

echo "==> installing plugin -> $PLUGIN_DST"
mkdir -p "$PLUGIN_DST"
cp -v "$SRC/plugin/"{manifest.json,BarWidget.qml,Panel.qml,modelctl.sh,monitor.sh} "$PLUGIN_DST/"
chmod +x "$PLUGIN_DST/modelctl.sh" "$PLUGIN_DST/monitor.sh"

echo "==> installing config -> $CFG_DST"
mkdir -p "$CFG_DST"
if [[ ! -f "$CFG_DST/serve.sh" ]]; then
  cp -v "$SRC/config/serve.sh" "$CFG_DST/"
  chmod +x "$CFG_DST/serve.sh"
else
  echo "    serve.sh exists, left untouched"
fi
if [[ ! -f "$CFG_DST/presets.json" ]]; then
  cp -v "$SRC/config/presets.example.json" "$CFG_DST/presets.json"
else
  echo "    presets.json exists, left untouched"
fi

echo "==> systemd user unit"
mkdir -p "$HOME/.config/systemd/user"
cp -v "$SRC/config/llama-server.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload

echo "==> validating plugin"
omarchy plugin validate "$PLUGIN_DST"

omarchy-shell shell rescanPlugins 2>/dev/null || true

echo
echo "Done. If the widget is not in your bar yet:"
echo "  omarchy plugin enable $PLUGIN_ID"
echo "Then point the dispatcher's routes at your llama.cpp builds (see README)."
