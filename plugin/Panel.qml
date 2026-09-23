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
            color: s.statusColor || "#888888"
          }
          Text {
            text: "llama.cpp · 6969"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Item { width: 1; height: 1 }
          Text {
            text: s.activityLabel || "…"
            anchors.verticalCenter: parent.verticalCenter
            color: s.statusColor || "#888888"
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- status rows ---------------------------------------------------
        Column {
          id: statusColumn
          width: parent.width
          spacing: Style.space(6)
          property var rows: [
            { label: "Status", value: s.status === "down" ? "server offline" : "online" },
            { label: "Activity", value: s.activityLabel || "—" },
            { label: "Model", value: s.modelName || (s.shortModel ? s.shortModel(s.model) : s.model) || "none loaded" },
            { label: "Endpoint", value: "127.0.0.1:6969" },
            { label: "VRAM", value: s.vramText || "—" }
          ]
          Repeater {
            model: statusColumn.rows
            // Label 40% + symmetric 2% gutters + value 56% = exact fit, so the
            // value's elipsis lands at the panel edge, not one gutter past it.
            Row {
              width: parent.width
              Text { width: parent.width * 0.4; text: modelData.label; color: root.barForeground; opacity: 0.6; font.family: Style.font.family; font.pixelSize: Style.font.body }
              Item { width: parent.width * 0.02 }
              Text { width: parent.width * 0.56; elide: Text.ElideRight; text: modelData.value; color: root.barForeground; font.family: Style.font.family; font.pixelSize: Style.font.body }
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
          color: s.statusColor || "#ffb300"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          visible: s.controlRunning && !s.modelSwitching
          text: "Working…"
          color: s.statusColor || "#ffb300"
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
          color: "#ef5350"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // ---- controls --------------------------------------------------------
        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Button {
            text: "Start"
            leftAlign: true
            width: (parent.width - parent.spacing * 2) / 3
            foreground: root.barForeground
            accent: "#4caf50"
            enabled: s.status === "down"
            onClicked: s.serverControl("start")
          }
          Button {
            text: "Restart"
            leftAlign: true
            width: (parent.width - parent.spacing * 2) / 3
            foreground: root.barForeground
            accent: "#ffb300"
            enabled: s.status === "ok"
            onClicked: s.serverControl("restart")
          }
          Button {
            text: "Stop"
            leftAlign: true
            width: (parent.width - parent.spacing * 2) / 3
            foreground: root.barForeground
            accent: "#ef5350"
            enabled: s.status !== "down"
            onClicked: s.serverControl("stop")
          }
        }
      }
    }
  }
}
