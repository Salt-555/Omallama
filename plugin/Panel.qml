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

  function open() { root.controller.show(); root.loadHistory() }
  onVisibleChanged: if (visible) root.loadHistory()
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // ---- tok/s history (panel graph) ----------------------------------------
  // monitor.sh appends one line per completed run; this is a sparkline source.
  property var tpsHistory: []
  function loadHistory() {
    // Never stack a second tail on top of one still running: a slow disk or a
    // paused compositor would otherwise queue processes behind the 5 s timer.
    if (!historyProc.running) historyProc.running = true
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
  // Per-client lane limits for the LLM proxy door (:8191, fronting :6969).
  // Rows come from llmlimits.sh list: configured clients plus every IP seen
  // on the door, with hit counts. Save applies them through llmlimits.sh,
  // which regenerates the nginx limit map and gracefully reloads the proxy
  // (in-flight requests finish; no model touched). 0 = unlimited.
  property var limitRows: []
  property int cDefaultLimit: 0
  // State of the :6969 door (llm-door.sh): on = external :6969 passes the
  // limits, off = external clients bypass them until it is enabled.
  property string doorState: "off"

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
    root.loadLimits()
    root.configOpen = true
  }
  function loadLimits() {
    if (!limitsListProc.running) limitsListProc.running = true
  }
  function toggleDoor() {
    if (doorProc.running) return
    configNote = ""
    doorProc.command = ["bash", s.pluginDir + "/llm-door.sh", doorState === "on" ? "disable" : "enable"]
    doorProc.running = true
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
    // Limits ride the same Save button: only nonzero rows are written, so an
    // untouched list never changes a limit.
    var limitPatch = {
      default: cDefaultLimit,
      clients: limitRows.reduce(function(acc, r) {
        if (r.limit > 0) acc[r.ip] = r.limit
        return acc
      }, {}),
      names: limitRows.reduce(function(acc, r) {
        var n = String(r.name || "").trim()
        if (n !== "") acc[r.ip] = n
        return acc
      }, {})
    }
    limitsSaveProc.command = ["bash", s.pluginDir + "/llmlimits.sh", "apply", JSON.stringify(limitPatch)]
    limitsSaveProc.running = true
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
            // The card's job is the headline (Chat / Images / Manual); the
            // RUNTIME it happens to run on is a detail, and it lives on the
            // status line. This used to print the backend name, which is how a
            // backend the local map had never heard of read as "llama.cpp".
            text: s.modeLabel || "—"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            id: actText
            // activityLabel first: phaseWord is always defined on the host
            // ("idle"), so reading it first pinned this to "idle" even when the
            // dot went urgent for loading/offline/draining.
            text: (s.activityLabel || s.phaseWord || "…")
                  + (s.slotsTotal !== ""
                     ? " · " + (s.slotsUsed !== "" ? s.slotsUsed : "0") + "/" + s.slotsTotal
                     : "")
            anchors.verticalCenter: parent.verticalCenter
            color: s.statusColor || root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
          // Config gear, parked right. Row has no fillWidth, so the spacer is
          // computed from the other items' widths (four items, four gaps).
          Item {
            width: Math.max(0, parent.width - statusDot.width
                                  - titleText.implicitWidth
                                  - actText.implicitWidth
                                  - gearBox.width
                                  - parent.spacing * 4)
            height: 1
          }
          Rectangle {
            id: gearBox
            width: Style.space(18)
            height: Style.space(18)
            anchors.verticalCenter: parent.verticalCenter
            radius: Math.min(4, Style.cornerRadius)
            color: gearArea.containsMouse
                   ? Style.hoverFillFor(root.barForeground, Color.accent)
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
          // Rates take the width they can; the runtime tag is pinned right so
          // it never gets elided. As the tail of the elided line it read
          // "· Bas…" on any panel narrower than the text.
          Row {
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: Math.max(0, parent.width - backendTag.implicitWidth - parent.spacing)
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
              id: backendTag
              // The runtime, named by monitor.sh from probe.sh's label table.
              text: s.backendLabel || ""
              color: root.barForeground
              opacity: 0.45
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
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

        // ---- tok/s per completed run ---------------------------------------
        // One bar per run, written by monitor.sh at every run boundary. These
        // are the AGGREGATE numbers (all lanes), same as the line above, so the
        // shape answers "what did the card actually do", request by request.
        Item {
          id: histChart
          width: parent.width
          height: histCaption.height + Style.space(5) + histRow.height
          visible: root.tpsHistory.length > 0

          readonly property int capacity: 40
          readonly property real peak: {
            var m = 0
            for (var i = 0; i < root.tpsHistory.length; i++)
              m = Math.max(m, root.tpsHistory[i])
            return Math.max(m, 1)
          }
          // Bar width depends on CAPACITY, never on how many points exist yet.
          // Sizing it off the point count made every bar shrink each time a run
          // finished, so the whole row twitched under the cursor.
          readonly property real barW: Math.max(1, (width - (capacity - 1) * histRow.spacing) / capacity)

          Text {
            id: histCaption
            width: parent.width
            elide: Text.ElideRight
            text: "tok/s per run · peak " + Math.round(histChart.peak)
                  + (root.tpsHistory.length
                     ? " · last " + Math.round(root.tpsHistory[root.tpsHistory.length - 1]) : "")
            color: root.barForeground
            opacity: 0.55
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            id: histRow
            anchors.top: histCaption.bottom
            anchors.topMargin: Style.space(5)
            // Right-anchored: new runs enter at the right edge and old ones
            // slide left, the way a scrolling sparkline reads. Width follows
            // the point count but the bars themselves never change size.
            anchors.right: parent.right
            width: Math.min(parent.width,
                            root.tpsHistory.length * histChart.barW
                            + Math.max(root.tpsHistory.length - 1, 0) * spacing)
            height: 24
            spacing: 1

            Repeater {
              model: root.tpsHistory
              Item {
                width: histChart.barW
                height: histRow.height
                Rectangle {
                  width: parent.width
                  height: Math.max(1, Math.round(parent.height * (modelData / histChart.peak)))
                  anchors.bottom: parent.bottom
                  radius: Math.min(1, width / 3)
                  color: root.barForeground
                  // The newest run is the one the numbers above describe.
                  opacity: index === root.tpsHistory.length - 1 ? 0.9 : 0.4
                }
              }
            }
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
                   || String(s.cardmodePhase || "") !== ""
                   || /blocked|aborted|failed|unloaded|timed out/.test(String(s.cardmodeNote || ""))
          readonly property string note: s.serviceFailed === true
              ? "llama-server died (" + (s.serviceExit || "?") + ") — nothing restarts it, press Start"
              : !!s.statusNote ? s.statusNote
              : s.modelSwitching
              ? "Reloading " + (s.currentModel ? String(s.currentModel).split("/").pop() : "…")
              : s.controlRunning ? "Working…"
              // cardmode's live WAIT wins over its last note: "waiting: drain 2
              // in flight" is what is true right now, the note is history.
              : String(s.cardmodePhase || "") !== "" ? s.cardmodePhase
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

        // tiny-voca TTS on the CPU (:8880) — its own row because it's
        // a separate service with its own lifecycle, not a llama-server
        // control. 18 MB CPU model: starts instantly, always resident.
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
            // Same third-of-row width as its siblings: half-the-row made this
            // row wider than the panel and painted this button past the card
            // edge (the same pitfall the Comfy comment above records).
            width: (parent.width - parent.spacing * 2) / 3
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
                   ? Style.hoverFillFor(root.barForeground, Color.accent)
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

        // ---- per-client lane limits (LLM door) ------------------------------
        // One row per client seen on the doors (or pinned by hand), each with
        // a lane cap. 0 = unlimited. Applied on Save: llmlimits.sh
        // regenerates the nginx limit map and gracefully reloads the proxy.
        Row {
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: parent.width - doorBtn.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: "Client lane limits · LLM"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Button {
            id: doorBtn
            text: root.doorState === "on" ? "Door: on" : "Door: off"
            leftAlign: true
            selected: root.doorState === "on"
            foreground: root.barForeground
            opacity: enabled ? 1.0 : 0.35
            onClicked: root.toggleDoor()
          }
        }
        Text {
          width: parent.width
          visible: root.doorState !== "on"
          wrapMode: Text.WordWrap
          text: "Door off — external clients reach the server past the limits. Enable flips the :6969 door on (refuses while a backend is still published wide; restart it first)."
          color: root.barForeground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        NumberField {
          width: parent.width
          label: "Default lanes for new clients (0 = unlimited)"
          from: 0
          to: 8
          value: root.cDefaultLimit
          onModified: root.cDefaultLimit = value
        }
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.limitRows.length > 0
          Repeater {
            model: root.limitRows
            Row {
              width: parent.width
              spacing: Style.space(6)
              TextField {
                id: nameField
                // Device name, optional. Focus-loss or Enter commits it to the
                // row; Save writes it (backend validates 1-24 safe chars).
                width: Style.space(108)
                verticalPadding: Style.space(2)
                font.pixelSize: Style.font.bodySmall
                text: modelData.name || ""
                placeholderText: "name"
                maximumLength: 24
                validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9 _-]{0,24}/ }
                onEditingFinished: root.limitRows[index].name = text
              }
              Text {
                width: parent.width - nameField.width - limitField.width - parent.spacing * 2
                elide: Text.ElideMiddle
                anchors.verticalCenter: parent.verticalCenter
                // "direct" = connected past the door (limit applies only once
                // the door is on); "live" = a request in flight right now.
                text: (modelData.name ? modelData.name + " · " : "")
                      + modelData.ip
                      + (modelData.hits > 0 ? "  ·  " + modelData.hits + " req" : "")
                      + (modelData.direct > 0 ? "  ·  direct" + (modelData.direct > 1 ? " ×" + modelData.direct : "") : "")
                      + (modelData.live > 0 ? "  ·  live" + (modelData.live > 1 ? " ×" + modelData.live : "") : "")
                color: root.barForeground
                opacity: 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              NumberField {
                id: limitField
                from: 0
                to: 8
                stepSize: 1
                value: modelData.limit
                // Edits land on the row object; Save reads them. No binding
                // notification needed — the list reloads after save anyway.
                onModified: root.limitRows[index].limit = value
              }
            }
          }
        }
        Text {
          width: parent.width
          visible: root.limitRows.some
                   && root.limitRows.some(function(r) { return (r.direct || 0) > 0 })
          wrapMode: Text.WordWrap
          text: "direct = connected past the door — limits apply once the :6969 door is on."
          color: root.barForeground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          width: parent.width
          visible: root.limitRows.length === 0
          wrapMode: Text.WordWrap
          text: "No clients yet — IPs appear here once a client connects to the LLM."
          color: root.barForeground
          opacity: 0.45
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
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
  // Sparkline source: monitor.sh appends "epoch tps tokens" per completed run.
  // Tail is capped at 40 points, matching the chart's fixed capacity.
  Process {
    id: historyProc
    command: ["sh", "-c", "tail -n 40 \"$HOME/.config/llama-server/.tps_history\" 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].trim().split(/\s+/)
          if (f.length >= 2) {
            var v = parseFloat(f[1])
            if (isFinite(v) && v > 0) out.push(v)
          }
        }
        root.tpsHistory = out.slice(-40)
      }
    }
  }

  // Refresh while the panel is open, so a run finishing behind it appears
  // without closing and reopening.
  Timer {
    interval: 5000
    repeat: true
    running: root.visible
    onTriggered: root.loadHistory()
  }

  Process {
    id: doorProc
    stderr: StdioCollector { id: doorErr; waitForEnd: true }
    stdout: StdioCollector { id: doorOut; waitForEnd: true }
    onExited: function(code) {
      var err = String((doorErr.text || "")).trim()
      var out = String((doorOut.text || "")).trim()
      // enable can legitimately refuse (port still held by a wide-published
      // backend) — its stderr is the instruction, so it wins the note.
      root.configNote = code !== 0 ? (err !== "" ? err : "door toggle failed (exit " + code + ")")
                                   : (out !== "" ? out : "door updated")
      root.loadLimits()
    }
  }

  Process {
    id: limitsListProc
    command: ["bash", s.pluginDir + "/llmlimits.sh", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var o = JSON.parse(String(text || "{}"))
          root.limitRows = o.rows || []
          root.cDefaultLimit = root.intOf(o.default, 0)
          root.doorState = o.door === "on" ? "on" : "off"
        } catch (e) {
          root.configNote = "could not read client limits"
        }
      }
    }
  }

  Process {
    id: limitsSaveProc
    stderr: StdioCollector { id: limitsSaveErr; waitForEnd: true }
    stdout: StdioCollector { id: limitsSaveOut; waitForEnd: true }
    onExited: function(code) {
      var err = String((limitsSaveErr.text || "")).trim()
      // A real failure must win the note over the plain "saved" the cardmode
      // save may have written; stderr on success (e.g. "proxy down, limits
      // take effect on start") is still worth showing.
      if (code !== 0 || err !== "") {
        root.configNote = code !== 0 ? (err !== "" ? err : "limits save failed (exit " + code + ")") : err
      }
      root.loadLimits()
    }
  }

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
