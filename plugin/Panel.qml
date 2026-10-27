import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dropdown panel for the llama.cpp (port 6969) monitor. Reads live state off
// the owning BarWidget (hostWidget) and drives start/stop / model switch via
// the same widget's control path.
Panel {
  id: root
  moduleName: "salt.llama-server"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var s: hostWidget || root

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // ---- cardmode config (gear icon, bottom-right) ---------------------------
  // Edits ~/.config/llama-server/modes.json, cardmode.service's policy file.
  // The reconciler re-reads it every loop, so a save takes effect with no
  // restart. Only the knobs we surface are written; modesctl.sh deep-merges
  // the patch over the existing file, so unseen keys (urls, ports, tts_*)
  // survive.
  property bool configOpen: false
  property var cfg: ({})                 // parsed modes.json, loaded on open
  property string configNote: ""
  property bool configBusy: false
  // flat copies of the knobs we edit, set when cfg loads.
  // Trimmed 2026-10-26 to what Salt uses: idle timer + per-mode presets.
  // The timing/memory knobs (drain cap, dwell, min-free MiBs, ready
  // timeouts) still live in modes.json and are preserved by modesctl.sh's
  // deep merge -- the panel just no longer writes them. Restore from the
  // .bak.cfgtrim backup if they're ever wanted back.
  property int cIdle: 30
  property string cLlmPreset: ""
  property string cGenPreset: ""

  function intOf(v, d) { var n = Number(v); return (v === null || v === undefined || isNaN(n)) ? d : n }
  function presetOf(mode, d) {
    var modes = cfg.modes || {}
    var m = modes[mode]
    return (m && m.preset) ? String(m.preset) : d
  }
  function loadConfig() {
    if (configShowProc.running) return
    configShowProc.running = true
  }
  function openConfig() {
    root.loadConfig()
    root.configOpen = true
  }
  function closeConfig() {
    configPresetLlm.close()
    configPresetGen.close()
    root.configOpen = false
  }
  function saveConfig() {
    if (configSaveProc.running) return
    // modesctl.sh deep-merges, so keys we no longer surface (ready_timeout,
    // drain/dwell/min-free) keep their current file values.
    var patch = {
      gen_idle_minutes: cIdle,
      modes: {
        llm: { preset: cLlmPreset },
        gen: { preset: cGenPreset }
      }
    }
    configBusy = true
    configNote = ""
    configSaveProc.command = ["bash", s.pluginDir + "/modesctl.sh", "save", JSON.stringify(patch)]
    configSaveProc.running = true
    // Deliberately NOT closing: the save result ("saved" / the error) is
    // rendered inside the config view, which is invisible once closed. The
    // old close-on-save made both outcomes silent.
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(root.configOpen ? configColumn.implicitHeight : content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the dropdown popup owns the keys (search field + result list),
      // freeze the panel cursor: PanelKeyCatcher runs with Keys.BeforeItem and
      // accepts arrows/Escape/Return, so without this the filter would swallow
      // j/k/h/l/x and Escape would close the panel instead of the popup.
      blocked: modelDropdown.popupOpen || configPresetLlm.popupOpen || configPresetGen.popupOpen
      onCloseRequested: { if (root.configOpen) root.closeConfig(); else root.close() }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.controlGap
        visible: !root.configOpen

        // ---- header --------------------------------------------------------
        Row {
          id: headerRow
          width: parent.width
          spacing: Style.space(8)
          Rectangle {
            id: statusDot
            width: 8; height: 8; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: s.statusColor || root.barForeground
          }
          Text {
            id: titleText
            text: (s.backend === "gufo" ? "Gufo"
                   : s.backend === "sglang" ? "SGLang"
                   : "llama.cpp")
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            id: modeText
            // The card's job, in the user's words (Chat / Images / Manual).
            text: s.modeLabel || ""
            anchors.verticalCenter: parent.verticalCenter
            color: root.barForeground
            opacity: 0.85
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            id: actText
            // activityLabel first: phaseWord is always defined on the host
            // ("idle"), so reading it first pinned this to "idle" even when the
            // dot went urgent for loading/offline/draining.
            text: s.activityLabel || s.phaseWord || "…"
            anchors.verticalCenter: parent.verticalCenter
            color: s.statusColor || root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          // Config gear, parked right. Row has no fillWidth, so the spacer is
          // computed from the other items' widths (six items, five gaps).
          Item {
            width: Math.max(0, parent.width - statusDot.width
                                  - titleText.implicitWidth
                                  - modeText.implicitWidth
                                  - actText.implicitWidth
                                  - gearBox.width
                                  - parent.spacing * 5)
            height: 1
          }
          Rectangle {
            id: gearBox
            width: Style.space(18)
            height: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            radius: Math.min(4, Style.cornerRadius)
            color: gearArea.containsMouse
                   ? Style.hoverFillFor(root.barForeground, Commons.Color.accent)
                   : "transparent"

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "⚙"
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: gearArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openConfig()
            }
          }
        }

        // ---- card mode ------------------------------------------------------
        // The one choice that matters: what the GPU is set up for. Both
        // buttons ask cardmode, which owns drain/dwell/handoff, so they never
        // race it; progress shows up in the note line below.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap
          Button {
            text: "Chat"
            leftAlign: true
            width: (parent.width - parent.spacing) / 2
            selected: s.mode === "llm"
            enabled: !!s.switchMode && !s.modeSwitchRunning
                     && s.cardmodeSwitching !== "true" && !s.controlRunning
            opacity: enabled ? 1.0 : 0.35
            foreground: root.barForeground
            onClicked: s.switchMode("llm")
          }
          Button {
            text: "Images"
            leftAlign: true
            width: (parent.width - parent.spacing) / 2
            selected: s.mode === "gen"
            enabled: !!s.switchMode && !s.modeSwitchRunning
                     && s.cardmodeSwitching !== "true" && !s.controlRunning
            opacity: enabled ? 1.0 : 0.35
            foreground: root.barForeground
            onClicked: s.switchMode("gen")
          }
        }

        // ---- status --------------------------------------------------------
        // One dense telemetry line plus a second line that only exists when
        // something is true (queue backed up, fresh TTFT). Exceptions, not
        // zeros: the old seven-row table showed four dashes while idle.
        Column {
          width: parent.width
          spacing: Style.space(4)
          Text {
            width: parent.width
            elide: Text.ElideRight
            text: (s.tpsLast !== "" ? "dec " + s.tpsLast : "dec —")
                  + " · " + (s.tpsEnc !== "" ? "enc " + s.tpsEnc : "enc —")
                  + " t/s · " + (s.vramText || "VRAM —")
            color: root.barForeground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            // Deferred requests (queue backed up) and TTFT (only meaningful
            // in the first seconds of a stream) share this line; hidden
            // entirely when both are quiet.
            readonly property string ttft: (s.ttftMs || "") ? "ttft " + s.ttftMs + " ms" : ""
            readonly property string deferred: Number(s.reqDeferred) > 0 ? "queue " + s.reqDeferred : ""
            width: parent.width
            visible: ttft !== "" || deferred !== ""
            elide: Text.ElideRight
            text: [ttft, deferred].filter(function(x) { return x !== "" }).join(" · ")
            color: root.barForeground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- model selector -------------------------------------------------
        SearchableDropdown {
          id: modelDropdown
          width: parent.width
          label: "Model"
          value: s.dropdownValue || ""
          options: s.modelOptions || []
          triggerLabel: s.modelSwitching ? "Switching model…" : "Select model"
          placeholderText: "Type to filter…"
          onChanged: function(path) { if (s.switchModel) s.switchModel(path) }
        }
        // ---- note line -------------------------------------------------------
        // ONE slot, priority-ordered: dead server > control-op failure >
        // model switch > generic control op > cardmode's voice. The old layout
        // gave each of these its own conditional text, so the panel height
        // jumped between states and two could compete for attention.
        Text {
          readonly property bool cardmodeTalking: (s.cardmodeSwitching === "true") || s.modeSwitchRunning
                   || /blocked|aborted|failed|unloaded|timed out/.test(String(s.cardmodeNote || ""))
          readonly property string note: s.serviceFailed === true
              ? "llama-server died (" + (s.serviceExit || "?") + ") — nothing restarts it, press Start"
              : !!s.statusNote ? s.statusNote
              : s.modelSwitching
              ? "Reloading " + (s.currentModel ? String(s.currentModel).split("/").pop() : "…")
              : s.controlRunning ? "Working…"
              : cardmodeTalking
              ? (s.cardmodeNote || (s.modeSwitchRunning ? "asking cardmode to switch…" : ""))
              : ""
          visible: note !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: note
          color: (s.serviceFailed === true || !!s.statusNote)
                 ? (s.urgentColor || root.barForeground)
                 : (s.statusColor || root.barForeground)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // ---- controls --------------------------------------------------------
        // Buttons gate on the systemd unit state, not health: while a model is
        // loading (unit active, /health not yet ok) Stop/Restart must stay
        // reachable. Start gates on health so a loading server isn't offered
        // a no-op start.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Button {
            text: "Start"
            leftAlign: true
            // Three per row: "Smart: off" needs more than a quarter of 320px.
            width: (parent.width - parent.spacing * 2) / 3
            foreground: root.barForeground
            // qs.Ui.Button has no disabled visual — dim it explicitly so an
            // unavailable action reads as unavailable (house pattern:
            // PanelActionButton dims to Qt.darker when !enabled).
            opacity: enabled ? 1.0 : 0.35
            // Never offer Start while cardmode owns the handoff: the unit
            // reads "deactivating" mid-switch, which used to light this button
            // up exactly when pressing it could start a second owner.
            enabled: s.status !== "ok" && !s.serviceActive
                     && s.cardmodeSwitching !== "true" && !s.modeSwitchRunning
            onClicked: s.serverControl("start")
          }
          Button {
            text: "Restart"
            leftAlign: true
            width: (parent.width - parent.spacing * 2) / 3
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            enabled: s.serviceActive && s.cardmodeSwitching !== "true"
            onClicked: s.serverControl("restart")
          }
          Button {
            text: "Stop"
            leftAlign: true
            width: (parent.width - parent.spacing * 2) / 3
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            enabled: s.serviceActive && s.cardmodeSwitching !== "true"
            onClicked: s.serverControl("stop")
          }
        }

        // Chatterbox TTS on the Blackwell (:8880) — its own row because it's
        // a separate service with its own lifecycle, not a llama-server
        // control. Starts in seconds (weights page-cached), first call ~9 s.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          // Smart mode: cardmode's arbiter flag. On = the gate holds comfy
          // prompts until the card is handed over and gen-mode idles back to
          // llm; off = prompts pass straight through and the idle revert
          // stands down. Residency is still llama-server's job (Stop).
          Button {
            text: s.smart === "on" ? "Smart: on" : "Smart: off"
            leftAlign: true
            width: (parent.width - parent.spacing * 2) / 3
            selected: s.smart === "on"
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            enabled: !!s.smartToggle
            onClicked: s.smartToggle()
          }

          Button {
            text: s.comfy === "on" ? "Comfy: on" : "Comfy: off"
            leftAlign: true
            // Third of the row minus the two gaps: `parent.width` here made the
            // row twice the panel wide and painted this pair past the card edge.
            width: (parent.width - parent.spacing * 2) / 3
            selected: s.comfy === "on"
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            enabled: !!s.comfyToggle && !s.comfyToggleRunning
            onClicked: s.comfyToggle()
          }

          Button {
            text: s.tts === "on" ? "TTS: on" : "TTS: off"
            leftAlign: true
            width: (parent.width - parent.spacing) / 2
            selected: s.tts === "on"
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            enabled: !!s.ttsToggle && !s.ttsToggleRunning
            onClicked: s.ttsToggle()
          }
        }

        // Config entry is the header's ⚙ now; the bottom gear row is gone.
      }

      // cardmode config overlay (the gear's view). A sibling of `content`, so
      // it lands in the same contentHolder; contentHeight binds to its implicit
      // height while open. Declared after `content`, so it paints on top.
      Column {
        id: configColumn
        width: parent.width
        spacing: Style.spacing.controlGap
        visible: root.configOpen

        // ---- header -------------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            id: cfgTitleText
            text: "cardmode config"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          // Pushes the ✕ to the right edge. A Row has no fillWidth, so the
          // spacer is computed from what the header's other items take.
          Item {
            width: Math.max(0, parent.width - cfgTitleText.implicitWidth
                                  - closeCross.width
                                  - parent.spacing * 2)
            height: 1
          }
          // Close affordance. Discard/Done sit at the foot of a column that is
          // taller than the panel, so the view needs an exit at the top too.
          // Discards, same as Escape / clicking the bar button away.
          Rectangle {
            id: closeCross
            width: Style.space(18)
            height: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            radius: Math.min(4, Style.cornerRadius)
            color: configCloseArea.containsMouse
                   ? Style.hoverFillFor(root.barForeground, Commons.Color.accent)
                   : "transparent"

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "✕"
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar && root.bar.fontFamily ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: configCloseArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeConfig()
            }
          }
        }

        // ---- idle timer ---------------------------------------------------
        NumberField {
          width: parent.width
          label: "Idle timer (min, gen -> llm)"
          from: 1
          to: 1440
          stepSize: 5
          value: root.cIdle
          onModified: root.cIdle = value
        }

        // ---- per-mode model pickers ---------------------------------------
        SearchableDropdown {
          id: configPresetLlm
          width: parent.width
          label: "LLM mode model"
          value: root.cLlmPreset
          options: s.modelOptions || []
          triggerLabel: root.cLlmPreset ? "" : "Select LLM model"
          onChanged: root.cLlmPreset = value
        }
        SearchableDropdown {
          id: configPresetGen
          width: parent.width
          label: "Gen mode model"
          value: root.cGenPreset
          options: s.modelOptions || []
          triggerLabel: root.cGenPreset ? "" : "Select gen model"
          onChanged: root.cGenPreset = value
        }

        // ---- save feedback ------------------------------------------------
        Text {
          width: parent.width
          visible: root.configBusy || !!root.configNote
          wrapMode: Text.WordWrap
          color: root.configNote && root.configNote.indexOf("saved") === 0
                 ? (s.statusColor || root.barForeground)
                 : (s.urgentColor || root.barForeground)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          text: root.configBusy ? "Saving…" : root.configNote
        }

        // ---- footer -------------------------------------------------------
        // Save stays open so the "saved" / error note beneath is actually
        // seen; Close (or ✕ / Escape) leaves the view.
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap
          Button {
            text: "Close"
            leftAlign: true
            width: (parent.width - parent.spacing) / 2
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            onClicked: root.closeConfig()
          }
          Button {
            text: "Save"
            leftAlign: true
            width: (parent.width - parent.spacing) / 2
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            onClicked: root.saveConfig()
          }
        }
      }
    }
  }

  // ---- config processes -----------------------------------------------------
  Process {
    id: configShowProc
    command: ["bash", s.pluginDir + "/modesctl.sh", "show"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var o = JSON.parse(String(text || "{}"))
          root.cfg = o
          // Only the surviving knobs; assigning the removed ones would throw
          // here and land in the catch as a bogus read failure.
          root.cIdle = root.intOf(o.gen_idle_minutes, 30)
          root.cLlmPreset = root.presetOf("llm", "")
          root.cGenPreset = root.presetOf("gen", "")
        } catch (e) {
          root.configNote = "could not read cardmode config"
        }
      }
    }
  }

  Process {
    id: configSaveProc
    stderr: StdioCollector { id: configSaveErr; waitForEnd: true }
    stdout: StdioCollector { id: configSaveOut; waitForEnd: true }
    onExited: function(code) {
      root.configBusy = false
      var out = String((configSaveOut.text || "")).trim()
      if (code === 0) {
        root.configNote = "saved"
        // reload so the fields reflect the file (and drop any rejected input)
        root.loadConfig()
      } else {
        var err = String((configSaveErr.text || "")).trim()
        root.configNote = err !== "" ? err : (out !== "" ? out : "save failed (exit " + code + ")")
      }
    }
  }
}
