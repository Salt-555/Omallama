import QtQuick
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the dropdown popup owns the keys (search field + result list),
      // freeze the panel cursor: PanelKeyCatcher runs with Keys.BeforeItem and
      // accepts arrows/Escape/Return, so without this the filter would swallow
      // j/k/h/l/x and Escape would close the panel instead of the popup.
      blocked: modelDropdown.popupOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.spacing.controlGap

        // ---- header --------------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.space(8)
          Rectangle {
            width: 8; height: 8; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: s.statusColor || root.barForeground
          }
          Text {
            text: (s.backend === "gufo" ? "Gufo"
                   : s.backend === "sglang" ? "SGLang"
                   : "llama.cpp") + " · 6969"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Item { width: 1; height: 1 }
          Text {
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
            // activityLabel first: phaseWord is always defined on the host
            // ("idle"), so reading it first pinned this to "idle" even when the
            // dot went urgent for loading/offline/draining.
            text: s.activityLabel || s.phaseWord || "…"
            anchors.verticalCenter: parent.verticalCenter
            color: s.statusColor || root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
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

        // ---- status rows ---------------------------------------------------
        Column {
          id: statusColumn
          width: parent.width
          spacing: Style.space(6)
          // Every value reads host props through `s`; guard them all — the
          // host props don't exist on the Panel base until injectPanel wires
          // hostWidget, and undefined rows tripped
          // "Unable to assign [undefined] to QString" on every panel load.
          property var rows: [
            {
              label: "Tokens/s",
              value: ((s.tpsEnc || "") ? "enc " + s.tpsEnc : "enc —")
                     + " · " + ((s.tpsLast || "") ? "dec " + s.tpsLast : "dec —")
            },
            { label: "TTFT", value: (s.ttftMs || "") ? s.ttftMs + " ms" : "—" },
            { label: "Power", value: (s.avgW || "") !== "" ? Number(s.avgW).toFixed(0) + " W avg" : ((s.powerW || "") !== "" ? Number(s.powerW).toFixed(0) + " W" : "—") },
            { label: "Efficiency", value: (s.tokW || "") !== "" ? Number(s.tokW).toFixed(3) + " tok/W" : "—" },
            { label: "Req active", value: s.reqActive || "0" },
            { label: "Req deferred", value: s.reqDeferred || "0" },
            { label: "VRAM", value: s.vramText || "—" }
          ]
          Repeater {
            model: statusColumn.rows
            // Label 40% + 2% gutter + value 58% = full width, so the value's
            // ellipsis lands at the panel edge instead of one gutter short.
            Row {
              width: parent.width
              Text { width: parent.width * 0.4; text: modelData.label; color: root.barForeground; opacity: 0.6; font.family: Style.font.family; font.pixelSize: Style.font.body }
              Item { width: parent.width * 0.02 }
              Text { width: parent.width * 0.58; elide: Text.ElideRight; text: modelData.value; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.body }
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
        Text {
          visible: s.modelSwitching
          text: "Reloading " + (s.currentModel ? String(s.currentModel).split("/").pop() : "…")
          color: s.statusColor || root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          visible: s.controlRunning && !s.modelSwitching
          text: "Working…"
          color: s.statusColor || root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          // Failure feedback: a control op that exited nonzero, or a switch
          // that never came up. Otherwise the panel would silently sit on
          // "Switching model…" with no reason given.
          visible: !!s.statusNote
          width: parent.width
          wrapMode: Text.WordWrap
          text: s.statusNote || ""
          color: s.urgentColor || root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          // The reconciler's own voice: what cardmode is doing (a handoff in
          // flight, ours or a comfy prompt's) or last refused. "timed out" is
          // listed because a switch that never came up is a failure too -- it
          // used to be the one silent failure class.
          visible: (s.cardmodeSwitching === "true") || s.modeSwitchRunning
                   || /blocked|aborted|failed|unloaded|timed out/.test(String(s.cardmodeNote || ""))
          width: parent.width
          wrapMode: Text.WordWrap
          text: s.cardmodeNote || (s.modeSwitchRunning ? "asking cardmode to switch…" : "")
          color: s.statusColor || root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          // Only a dead server earns a sentence. `failed` is the state that
          // never self-heals (Restart=no by design, and cardmode's idle timer
          // only acts in gen mode), so the reason and the way out belong on
          // screen instead of a bare "offline".
          visible: s.serviceFailed === true
          width: parent.width
          wrapMode: Text.WordWrap
          text: "llama-server died (" + (s.serviceExit || "?") + ") — nothing restarts it, press Start"
          color: s.urgentColor || root.barForeground
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
      }
    }
  }
}
