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
  // .pollstate / .runanchor / .last_tps).
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/salt.llama-server"

  // ---- live state ----------------------------------------------------------
  property string status: "down"        // ok | down
  // idle | encoding | decoding — monitor.sh classifies the in-flight request
  // from requests_processing + the n_decode_total rate (llama-server's token
  // counters only advance at request completion, so phase cannot come from
  // them). See monitor.sh's header for the measured numbers behind this.
  property string activity: "idle"
  property string backend: "llama"          // runtime serving: llama | gufo | sglang
  // Display name for whichever runtime the monitor reports, used by the bar
  // tooltip and the panel header. Kept next to `backend` so a new backend
  // only has to be named once.
  readonly property string backendLabel: backend === "gufo" ? "Gufo"
    : backend === "sglang" ? "SGLang"
    : "llama.cpp"
  property string tpsEnc: ""               // last run: encode (prefill) t/s
  property string ttftMs: ""               // last run: time to first token, ms
  property string reqActive: "0"           // requests on a session right now
  property string reqDeferred: "0"         // requests waiting in the queue
  property string model: ""             // active model path
  property string modelName: ""         // active preset name (empty if set by path)
  property real vramUsed: 0             // bytes
  property real vramTotal: 0            // bytes
  property string tpsLast: ""           // tok/s of the last completed run
  property string powerW: ""            // instantaneous GPU power, watts
  property string avgW: ""              // avg watts over the last completed turn
  property string tokW: ""              // tokens/joule over the last completed turn
  property bool controlRunning: false
  // Service state is separate from health: during a model load the unit is
  // active but /health 503s. Buttons gate on this so a loading server can
  // still be stopped/restarted from the panel.
  // The RAW systemd state as monitor.sh reads it: active | activating |
  // deactivating | failed | inactive. It travels verbatim because the two dead
  // states mean opposite things to whoever is looking: `inactive` is a Stop
  // somebody pressed, `failed` is a server that died with Restart=no and no
  // path back except Start. Collapsing them into one bool is what made a
  // watchdog kill look like a manual stop.
  property string serviceState: ""
  readonly property bool serviceActive: serviceState === "active" || serviceState === "activating"
  readonly property bool serviceFailed: serviceState === "failed"
  // "137/exit-code" while failed, empty otherwise (monitor key "exit").
  property string serviceExit: ""

  // cardmode smart-switch flag (monitor key "smart"): on = comfy prompts are
  // gate-held and the card auto-hands-off between llm/gen modes; off = the
  // gate passes prompts through and the idle revert stands down. Toggling
  // never unloads anything — residency stays llama-server's job (Stop).
  property string smart: "off"
  // Chatterbox TTS on the Blackwell (monitor key "tts"): a separate user
  // unit on :8880 with its own lifecycle, independent of llm/gen cardmode.
  property string tts: "off"
  readonly property bool ttsToggleRunning: ttsProc.running
  // ComfyUI server on the Blackwell (:8189 behind the :8188 gate): a plain
  // user unit with its own lifecycle, exactly like TTS. Off = the whole
  // setup closed; cardmode never resurrects it.
  property string comfy: "off"
  readonly property bool comfyToggleRunning: comfyProc.running

  // cardmode reconciler voice (monitor keys "state"/"resident"/"switching"/
  // "note"): draining = /health not ok but the sglang container still runs
  // (graceful exit, orphan, or a load in progress); note = cardmode's last
  // action or refusal, shown in the panel only when it is news.
  property string state: "down"            // ok | draining | down
  property string resident: ""             // sglang container running: "true"/"false"
  property string cardmodeSwitching: "false"
  property string cardmodeNote: ""
  // Which resident shape owns the card right now: llm | gen | "" (no mode
  // preset loaded = a hand-picked model). Derived in monitor.sh from
  // model.json + modes.json, exactly like cardmode derives it.
  property string mode: ""
  // Display vocabulary. The mode is the card's job, not a model name: "Chat"
  // is the Flash-Next cell, "Images" is the 27B + ComfyUI shape. "Smart" is
  // the arbiter flag that lets cardmode move between them by itself.
  // mode is the SELECTION in model.json, so on its own it keeps claiming
  // "Chat" long after the server died and gave the card back. With nothing
  // resident there is no shape to name; show the dash until it is back.
  readonly property string modeLabel: (state === "down" && !serviceActive) ? "—"
    : mode === "llm" ? "Chat"
    : mode === "gen" ? "Images"
    : (status === "ok" ? "Manual" : "—")
  property string modeTarget: ""           // mode a switch is heading to
  readonly property bool modeSwitchRunning: modeSwitchProc.running

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

  // Theme-driven state colors, matching the first-party pattern
  // (bar.urgent / Color.urgent): urgent for failures, accent while tokens are
  // being produced, foreground while the server is chewing on input, muted for
  // ready-but-idle. Follows the active theme's palette.
  readonly property color urgentColor: bar && bar.urgent ? bar.urgent : Color.urgent
  readonly property color statusColor: status !== "ok" ? urgentColor
    : activity === "decoding" ? Color.accent
    : activity === "encoding" ? Color.foreground
    : Color.muted

  // status down overlays the phase: unit active but /health not ok yet means
  // the server is loading, not offline.
  // Phase glyphs: the bar shows ENC/DEC (the phase colors carry the state);
  // idle keeps its word. phaseWord is the panel's spelled-out variant.
  readonly property string phaseGlyph: activity === "decoding" ? "DEC"
    : activity === "encoding" ? "ENC"
    : activity
  readonly property string phaseWord: activity === "decoding" ? "decoding"
    : activity === "encoding" ? "encoding"
    : activity

  readonly property string activityLabel: state === "draining"
    ? "draining"
    : status === "down"
      ? (serviceFailed ? "crashed" : serviceActive ? "loading" : "offline")
      : phaseWord

  readonly property string vramText: (vramTotal > 0)
    ? (vramUsed / 1073741824).toFixed(0) + "G/" + (vramTotal / 1073741824).toFixed(0) + "G"
    : "—"

  readonly property string powerText: (powerW !== "") ? Number(powerW).toFixed(0) + "W" : ""
  readonly property string avgWText: (avgW !== "") ? Number(avgW).toFixed(0) + "W" : ""
  // tokens per joule over the last whole turn (prefill energy included)
  readonly property string tokWText: (tokW !== "") ? Number(tokW).toFixed(3) + " tok/W" : ""

  function shortModel(id) {
    if (!id) return ""
    var name = String(id).split("/").pop()
    return name.replace(/-\d+-of-\d+\.gguf$/, ".gguf").replace(".gguf", "")
  }

  // Bar label: live phase glyph while the server is working (token counters
  // only update at request completion, so no live t/s exists), else the last
  // completed run's speed, else the offline marker.
  readonly property string barText: {
    if (state === "draining") return "llm ⟳"
    // Three distinct faces, because they lead to different actions: a
    // deliberate stop (✕) is fine to ignore, a crash (⚠) needs a Start, and a
    // load in flight (…) needs patience.
    if (status === "down") return serviceFailed ? "llm ⚠" : serviceActive ? "llm …" : "llm ✕"
    if (activity !== "idle") return phaseGlyph
    if (tpsLast !== "") return tpsLast + " t/s"
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

  // Flip the cardmode smart-switcher (gate hold + auto handoff). Local HTTP,
  // not systemctl: the reconciler owns its own flag and persists it.
  function smartToggle() {
    if (smartProc.running) return
    statusNote = ""
    smartProc.command = ["curl", "-sf", "--max-time", "5", "-X", "POST",
      "http://127.0.0.1:8190/enable?on=" + (root.smart === "on" ? "0" : "1")]
    smartProc.running = true
  }

  // Ask the reconciler to move the card. cardmode owns dwell/drain/handoff,
  // so this call BLOCKS until the switch lands or refuses (up to its cap);
  // the process is async and the poll surfaces switching/note meanwhile.
  function switchMode(target) {
    if (modeSwitchProc.running || controlProc.running || modelSetProc.running) return
    if (target === root.mode) return
    root.modeTarget = target
    root.statusNote = ""
    modeSwitchProc.command = ["curl", "-sS", "--max-time", "900",
      "http://127.0.0.1:8190/switch?mode=" + target]
    modeSwitchProc.running = true
  }

  // TTS is a plain systemd toggle, not an HTTP flag: it's a separate user
  // unit (chatterbox.service) that cardmode bounces around the sglang malloc.
  // No debounce — systemctl's exit is the result; ttsProc re-polls on exit.
  // ComfyUI is a plain systemd toggle like TTS. No debounce -- systemctl's
  // exit is the result; comfyProc re-polls on exit.
  function comfyToggle() {
    if (comfyProc.running) return
    statusNote = ""
    comfyProc.command = ["systemctl", "--user",
      root.comfy === "on" ? "stop" : "start", "comfyui.service"]
    comfyProc.running = true
  }

  function ttsToggle() {
    if (ttsProc.running) return
    statusNote = ""
    ttsProc.command = ["systemctl", "--user",
      root.tts === "on" ? "stop" : "start", "chatterbox.service"]
    ttsProc.running = true
  }

  // sel is a preset name or path; modelctl.sh resolves either.
  function switchModel(sel) {
    if (modelSetProc.running || controlProc.running) return
    currentModel = sel
    // Clear the polled preset name so the dropdown reflects the optimistic
    // selection during the switch instead of the previous model.
    modelName = ""
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
        else if (k === "backend") root.backend = v
        else if (k === "tps_last") root.tpsLast = v
        else if (k === "tps_enc") root.tpsEnc = v
        else if (k === "ttft") root.ttftMs = v
        else if (k === "power_w") root.powerW = v
        else if (k === "avg_w") root.avgW = v
        else if (k === "tok_w") root.tokW = v
        else if (k === "req_active") root.reqActive = v
        else if (k === "req_deferred") root.reqDeferred = v
        else if (k === "model") { root.model = v; root.currentModel = v }
        else if (k === "name") root.modelName = v
        else if (k === "vram") root.vramUsed = parseFloat(v) || 0
        else if (k === "vram_total") root.vramTotal = parseFloat(v) || 0
        else if (k === "service") root.serviceState = v
        else if (k === "exit") root.serviceExit = v
        else if (k === "smart") root.smart = v
        else if (k === "tts") root.tts = v
        else if (k === "comfy") root.comfy = v
        else if (k === "state") root.state = v
        else if (k === "mode") root.mode = v
        else if (k === "resident") root.resident = v
        else if (k === "switching") root.cardmodeSwitching = v
        else if (k === "note") root.cardmodeNote = v
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
    // modelctl.sh reports why a switch failed on stderr; capture it so the
    // panel can show the reason instead of just silently unsticking.
    stderr: StdioCollector { id: modelSetErr; waitForEnd: true }
    onExited: function(code) {
      if (code === 0) {
        root.serverControl("restart")
      } else {
        root.modelSwitching = false
        var msg = String((modelSetErr.text || "")).trim()
        root.statusNote = msg !== "" ? msg : "model switch failed (exit " + code + ")"
        Qt.callLater(root.loadModels)
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

  Process {
    id: comfyProc
    onExited: function(code) {
      // systemctl's exit is the failure signal: a start that fails to bind
      // or load must say so instead of silently reverting the toggle.
      if (code !== 0) root.statusNote = "comfy " + (root.comfy === "on" ? "stop" : "start") + " failed (exit " + code + ")"
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: modeSwitchProc
    // cardmode answers "ok: ..." (200) or "failed: ..." (503) as the body, so
    // the reply text IS the result -- no status parsing needed, and a refusal
    // ("llm still busy after 600s") lands in statusNote verbatim.
    stdout: StdioCollector { id: modeOut; waitForEnd: true }
    onExited: function(code) {
      var out = String((modeOut.text || "")).trim()
      root.modeTarget = ""
      if (out.indexOf("ok:") !== 0) {
        root.statusNote = out !== "" ? out.replace(/^failed:\s*/, "")
          : "mode switch failed (exit " + code + ")"
      }
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: smartProc
    onExited: function(code) {
      if (code !== 0) root.statusNote = "cardmode unreachable (exit " + code + ")"
      Qt.callLater(root.refresh)
    }
  }

  Process {
    id: ttsProc
    onExited: function(code) {
      // systemctl's exit is the failure signal: a start that fails to bind or
      // load must say so instead of silently reverting the optimistic toggle.
      if (code !== 0) root.statusNote = "tts " + (root.tts === "on" ? "stop" : "start") + " failed (exit " + code + ")"
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
    tooltipText: root.modeLabel + " · " + root.backendLabel + " · " + root.activityLabel
      + (root.model ? " · " + root.shortModel(root.model) : "")
      + (root.powerText ? " · " + root.powerText : "")
      + (root.tokWText ? " · " + root.tokWText : "")
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
