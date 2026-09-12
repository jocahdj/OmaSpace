import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget + popup panel for saving/restoring which apps live on which
// Hyprland workspace. All the actual hyprctl/JSON work happens in the
// bundled window-layouts.sh; this file is just the UI and fires it off with
// Quickshell.execDetached, then re-reads its JSON state file (which the
// script writes atomically) to refresh the list.
Panel {
  id: root
  moduleName: "jocahdj.omaspace"
  ipcTarget: "jocahdj.omaspace"

  function localPath(rel) {
    return String(Qt.resolvedUrl(rel)).replace(/^file:\/\//, "")
  }

  readonly property string scriptPath: localPath("window-layouts.sh")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")
  readonly property string statePath: root.stateHome + "/omarchy/window-layouts.json"

  property var stateData: ({ layouts: {}, bootLayout: "" })
  property var layoutNames: []
  property string newLayoutName: "default"
  property string confirmDeleteName: ""

  function loadState(raw) {
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    if (!parsed || typeof parsed !== "object") parsed = {}
    if (!parsed.layouts || typeof parsed.layouts !== "object") parsed.layouts = {}
    if (typeof parsed.bootLayout !== "string") parsed.bootLayout = ""
    root.stateData = parsed
    var names = Object.keys(parsed.layouts)
    names.sort()
    root.layoutNames = names
  }

  function workspaceSummary(name) {
    var ws = (root.stateData.layouts && root.stateData.layouts[name]) || {}
    var keys = Object.keys(ws)
    keys.sort(function(a, b) { return Number(a) - Number(b) })
    if (keys.length === 0) return "No windows recorded"
    var parts = []
    for (var i = 0; i < keys.length; i++) {
      var apps = ws[keys[i]] || []
      var labels = []
      for (var j = 0; j < apps.length; j++) labels.push(apps[j].class || apps[j].title || "?")
      parts.push("WS " + keys[i] + ": " + labels.join(", "))
    }
    return parts.join("   ·   ")
  }

  function runScript(args) {
    Quickshell.execDetached([root.scriptPath].concat(args))
  }

  function saveCurrentLayout() {
    var name = (root.newLayoutName || "").trim()
    if (!name) return
    runScript(["save", name])
  }

  function restoreLayout(name) { runScript(["restore", name]) }
  function deleteLayout(name) { runScript(["delete", name]) }
  function setBootLayout(name) { runScript(["set-boot", name]) }
  function clearBootLayout() { runScript(["set-boot", "none"]) }

  function requestDelete(name) { root.confirmDeleteName = name }
  function confirmDelete() {
    if (root.confirmDeleteName) deleteLayout(root.confirmDeleteName)
    root.confirmDeleteName = ""
  }
  function cancelDelete() { root.confirmDeleteName = "" }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("{}")
    onFileChanged: reload()
  }

  // A small fan of three slanted, solid rounded rectangles — like pages of
  // an open book — standing in for the app's "OmaSpace" bar icon instead of
  // a plain Unicode glyph. Each of the back two pages carries a thin border
  // in the bar's own background color, which is what makes it read as a
  // separate page peeking out from behind the one on top rather than a
  // single blurred blob — a plain foreground-colored outline is too subtle
  // at 18px. Colors track the bar's live theme.
  Component {
    id: layersIcon

    Item {
      id: iconRoot
      anchors.fill: parent
      readonly property color inkColor: root.bar ? root.bar.foreground : "white"
      readonly property color gapColor: root.bar ? root.bar.background : "black"

      Repeater {
        model: [
          { angle: -22, dx: -0.16, dy: -0.12, fade: 0.5 },
          { angle: -3, dx: 0.02, dy: 0.02, fade: 0.75 },
          { angle: 20, dx: 0.17, dy: 0.13, fade: 1.0 }
        ]

        Rectangle {
          required property var modelData
          required property int index
          width: iconRoot.width * 0.54
          height: iconRoot.height * 0.72
          radius: Math.min(width, height) * 0.22
          color: Qt.rgba(iconRoot.inkColor.r, iconRoot.inkColor.g, iconRoot.inkColor.b, modelData.fade)
          border.width: index < 2 ? Math.max(1, iconRoot.width * 0.09) : 0
          border.color: iconRoot.gapColor
          x: (iconRoot.width - width) / 2 + modelData.dx * iconRoot.width
          y: (iconRoot.height - height) / 2 + modelData.dy * iconRoot.height
          rotation: modelData.angle
          z: index
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: layersIcon
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.spacing.md

          Text {
            textFormat: Text.PlainText
            text: "OmaSpace"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.stateData.bootLayout
              ? "Restores '" + root.stateData.bootLayout + "' on login"
              : "Nothing restores automatically on login"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          PanelSeparator { foreground: root.bar.foreground }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            TextField {
              id: nameField
              width: parent.width - saveButton.width - parent.spacing
              text: root.newLayoutName
              placeholderText: "Layout name"
              onTextChanged: root.newLayoutName = text
              onAccepted: root.saveCurrentLayout()
            }

            Button {
              id: saveButton
              text: "Save current layout"
              enabled: nameField.text.trim().length > 0
              onClicked: root.saveCurrentLayout()
            }
          }

          Text {
            textFormat: Text.PlainText
            text: "Captures every window on every workspace right now, under this name."
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "SAVED LAYOUTS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: root.layoutNames.length === 0
            textFormat: Text.PlainText
            text: "No layouts saved yet."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: root.layoutNames

            Column {
              id: layoutRow
              required property string modelData
              readonly property string layoutName: modelData
              readonly property bool isBoot: root.stateData.bootLayout === layoutName

              width: contentColumn.width
              spacing: Style.spacing.xs

              Row {
                width: parent.width
                spacing: Style.spacing.sm

                ToggleSwitch {
                  id: bootSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: layoutRow.isBoot
                  foreground: root.bar.foreground
                  onToggled: layoutRow.isBoot ? root.clearBootLayout() : root.setBootLayout(layoutRow.layoutName)

                  PanelToolTip {
                    visible: bootSwitch.containsMouse
                    text: layoutRow.isBoot ? "Runs on boot — click to turn off" : "Run on boot"
                    fontFamily: root.bar.fontFamily
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: layoutRow.layoutName
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: layoutRow.isBoot
                  width: parent.width - bootSwitch.width - restoreBtn.width - deleteBtn.width - Style.space(3) * 4
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }

                Button {
                  id: restoreBtn
                  text: "Restore"
                  background: "#2e7d32"
                  foreground: "#ffffff"
                  accent: "#2e7d32"
                  onClicked: root.restoreLayout(layoutRow.layoutName)
                }

                PanelActionButton {
                  id: deleteBtn
                  iconText: "✕"
                  tooltipText: "Delete layout"
                  foreground: root.bar.foreground
                  hoverColor: root.bar.urgent
                  onClicked: root.requestDelete(layoutRow.layoutName)
                }
              }

              Text {
                textFormat: Text.PlainText
                text: root.workspaceSummary(layoutRow.layoutName)
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }
            }
          }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.confirmDeleteName !== ""
        message: "Delete layout '" + root.confirmDeleteName + "'?"
        confirmText: "Delete"
        background: Color.background
        foreground: root.bar.foreground
        onCanceled: root.cancelDelete()
        onConfirmed: root.confirmDelete()
      }
    }
  }
}
