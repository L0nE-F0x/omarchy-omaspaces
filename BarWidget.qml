import QtQuick
import qs.Commons
import qs.Ui

// apex-forge-keep: OmaSpaces chip.
//
// A bare glyph on the bar: the panel it opens is the whole interface, so the
// chip stays out of the way. It picks up a dot while a space is being applied
// so a long Chrome cold start still reads as "working" from the bar alone.
BarWidget {
  id: root
  moduleName: "lonefox.omaspaces"

  readonly property bool busy: panelLoader.item ? panelLoader.item.busyId !== "" : false
  readonly property string lastApplied: panelLoader.item ? panelLoader.item.lastApplied : ""

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = iconButton
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Right click is the shortcut for "put me back where I was": re-apply the
  // last space without opening the panel at all.
  function reapplyLast() {
    if (panelLoader.item && panelLoader.item.reapplyLast) panelLoader.item.reapplyLast()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: iconButton
    anchors.centerIn: parent
    bar: root.bar
    text: "\uf009"
    active: root.busy
    tooltipText: {
      if (root.busy) return "OmaSpaces — opening…"
      if (root.lastApplied !== "") return "OmaSpaces — " + root.lastApplied + "\nRight click to re-apply"
      return "OmaSpaces — workspace profiles"
    }
    onPressed: function(button) {
      if (button === Qt.RightButton) root.reapplyLast()
      else root.togglePanel()
    }
  }
}
