import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Luma events in the bar: the Luma star mark alone. The next-event
// countdown ("12d", or the start time when it is today) lives in the
// tooltip and the panel header.
//
// Left click reveals the event list, right or middle click starts a
// refresh. Panel.qml owns all data; this file owns the bar slot.
BarWidget {
  id: root
  moduleName: "studiotwin.luma"

  readonly property string barText: panelLoader.item ? panelLoader.item.barLabel : ""

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // ---- Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget
  //      root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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

  IpcHandler {
    target: "studiotwin.luma"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  // BarIconButton is the slot the built-in icon widgets use (the agents
  // plugin among them), so size and padding match them exactly. The icon
  // canvas renders the Luma mark instead of a font glyph.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.barText === "" ? "Luma" : "Luma · " + root.barText

    iconComponent: Component {
      LumaMark {
        tint: button.foreground
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton || b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
