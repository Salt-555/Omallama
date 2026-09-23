import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// llama.cpp server monitor (port 6969) bar widget.
// Polls monitor.sh (health + /metrics activity + VRAM), exposes start/stop and
// model switch via modelctl.sh + systemctl, and hosts Panel.qml via a Loader.
BarWidget {
  id: root
  moduleName: "salt.llama-server"

  // Plugin ships its own scripts; ~/.config/llama-server is runtime state only
  // (model.json, presets.json, serve.sh, and monitor.sh's per-session files
  // .genstate / .genanchor / .last_tps).
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/salt.llama-server"

  // ---- live state ----------------------------------------------------------
  property string status: "down"        // ok | down
  property string activity: "idle"      // idle | generating
  property string model: ""             // active model path
  property string modelName: ""         // active preset name (empty if set by path)
  property real vramUsed: 0             // bytes
  property real vramTotal: 0            // bytes
  property string tpsLast: ""           // tok/s of the last completed run
  property bool controlRunning: false

  // ---- model selector ------------------------------------------------------
  property var modelOptions: []          // [{value,label,description}]
  // Written by the poll (model.json's path) and optimistically by switchModel
  // (a preset name), so it carries either. dropdownValue below reconciles the
  // two: recorded name first, then a back-map through modelOptions' paths.
  property string currentModel: ""
  property bool modelSwitching: false
  // Set when a control op fails or a switch never reaches "ok", so the panel
  // can say why instead of pinning "Switching model…" forever.
  property string statusNote: ""
  property string controlAction: ""
  readonly property int switchTimeoutMs: 180000

  readonly property color statusColor: status === "ok"
    ? (activity === "generating" ? "#ffb300" : "#4caf50")
    : "#ef5350"

  readonly property string activityLabel: status === "down" ? "offline"
    : activity === "generating" ? "generating"
    : "idle"

  readonly property string vramText: (vramTotal > 0)
    ? (vramUsed / 1073741824).toFixed(0) + "G/" + (vramTotal / 1073741824).toFixed(0) + "G"
    : "—"

  function shortModel(id) {
    if (!id) return ""
    var name = String(id).split("/").pop()
    return name.replace(/-\d+-of-\d+\.gguf$/, ".gguf").replace(".gguf", "")
  }

  // Bar label: last-run speed, activity pulse, offline marker.
  readonly property string barText: {
    if (status === "down") return "llm ✕"
    if (tpsLast !== "") return tpsLast + " t/s"
    if (activity === "generating") return "generating…"
    return "llm"
  }

  function serverControl(action) {
    if (controlProc.running) return
    controlRunning = true
    controlAction = action
    statusNote = ""
    controlProc.command = ["systemctl", "--user", action, "llama-server.service"]
    controlProc.running = true
  }

  // sel is a preset name or path; modelctl.sh resolves either.
  function switchModel(sel) {
    if (modelSetProc.running || controlProc.running) return
    currentModel = sel
    statusNote = ""
    modelSwitching = true
    modelSetProc.command = ["bash", root.pluginDir + "/modelctl.sh", "set", sel]
    modelSetProc.running = true
  }

  // Dropdown selection key: the preset name straight from model.json when the
  // active model was picked from a preset; the path-back-map only covers
  // presets never selected through the dropdown and path-set models.
  readonly property string dropdownValue: {
    if (modelName !== "") return modelName
    for (var i = 0; i < modelOptions.length; i++)
      if (modelOptions[i].path === currentModel) return modelOptions[i].value
    return currentModel
  }

  function loadModels() {
    if (!modelListProc.running) modelListProc.running = true
    if (!modelCurrentProc.running) modelCurrentProc.running = true
  }

  // ---- panel lifecycle -----------------------------------------------------
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function open() {
    root.loadModels()
    if (panelLoader.item) panelLoader.item.open()
  }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() {
    root.loadModels()
    if (panelLoader.item) panelLoader.item.toggle()
  }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (!monitorProc.running) monitorProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: root.loadModels()

  IpcHandler {
    target: "salt.llama-server"
    function refresh() { root.broadcast("refresh") }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.togglePanel() }
  }

  // ---- polling -------------------------------------------------------------
  Timer {
    id: pollTimer
    interval: root.setting("pollIntervalMs", 2500)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: monitorProc
    command: ["bash", root.pluginDir + "/monitor.sh"]
    stdout: SplitParser {
      onRead: function(line) {
        var s = String(line).trim()
        var eq = s.indexOf("=")
        if (eq < 0) return
        var k = s.substring(0, eq)
        var v = s.substring(eq + 1)
        if (k === "status") {
          root.status = v
          // model.json is written before the restart, so the first "ok" once
          // the control op has settled means the new model is serving. Both
          // guards matter: while `modelctl set` runs one of them is always
          // true, so a poll landing mid-switch cannot clear the flag early.
          if (v === "ok" && root.modelSwitching
              && !root.modelSetProc.running && !root.controlRunning) {
            root.modelSwitching = false
            root.statusNote = ""
          }
        }
        else if (k === "activity") root.activity = v
        else if (k === "tps_last") root.tpsLast = v
        else if (k === "model") { root.model = v; root.currentModel = v }
        else if (k === "name") root.modelName = v
        else if (k === "vram") root.vramUsed = parseFloat(v) || 0
        else if (k === "vram_total") root.vramTotal = parseFloat(v) || 0
      }
    }
  }

  Process {
    id: modelListProc
    command: ["bash", root.pluginDir + "/modelctl.sh", "presets"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (parts.length >= 2 && parts[0] !== "") {
            out.push({ value: parts[0], label: parts[0], path: parts[1], description: parts.length >= 3 && parts[2] ? "spec: " + parts[2] : "" })
          }
        }
        root.modelOptions = out
      }
    }
  }

  Process {
    id: modelCurrentProc
    command: ["bash", root.pluginDir + "/modelctl.sh", "current"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").trim()
        if (m) root.currentModel = m
      }
    }
  }

  Process {
    id: modelSetProc
    onExited: function(code) {
      if (code === 0) {
        root.serverControl("restart")
      } else {
        root.modelSwitching = false
      }
    }
  }

  Process {
    id: controlProc
    onExited: function(code) {
      root.controlRunning = false
      // systemctl's exit is the failure signal: without this the switch latch
      // would survive a failed restart and pin the UI on "Switching model…".
      if (code !== 0) {
        root.modelSwitching = false
        root.statusNote = "systemctl " + root.controlAction + " failed (exit " + code + ")"
      } else if (root.modelSwitching) {
        root.statusNote = ""
      }
      Qt.callLater(root.refresh)
    }
  }

  // A switch that never reaches "ok" (serve.sh dies, port busy, OOM) must not
  // keep the panel saying "Switching model…" forever.
  Timer {
    id: switchWatchdog
    interval: root.switchTimeoutMs
    running: root.modelSwitching
    onTriggered: {
      root.modelSwitching = false
      // Only blame the load when the server isn't actually serving: a model
      // that takes longer than the timeout to load is slow, not broken.
      if (root.status !== "ok") root.statusNote = "model did not come up"
    }
  }

  // ---- bar button ----------------------------------------------------------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    dimmed: root.status !== "ok"
    tooltipText: "llama.cpp · " + root.activityLabel
      + (root.model ? " · " + root.shortModel(root.model) : "")
      + " · click for controls"
    onPressed: function(b) {
      if (b === Qt.RightButton) { root.refresh(); root.loadModels() }
      else root.togglePanel()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
