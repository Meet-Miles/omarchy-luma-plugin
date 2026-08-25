import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Luma events in the bar: a calendar glyph with the days until the next
// event ("12d", or the start time when it is today), plus the guest count
// when that event is one you host ("12d · 23/35").
//
// Left click reveals the event list, right or middle click starts a
// refresh. Panel.qml owns all data; this file owns the bar slot.
BarWidget {
  id: root
  moduleName: "studiotwin.luma"

  readonly property string glyph: "󰃭"
  readonly property string barText: panelLoader.item ? panelLoader.item.barLabel : ""
  readonly property bool hasNewRegistrations: panelLoader.item ? panelLoader.item.hasNewRegistrations === true : false

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical
      ? ""
      : (root.barText === "" ? root.glyph : root.glyph + "  " + root.barText)
    labelVisible: !root.vertical
    hasVisualContent: true
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.barText === "" ? "Luma" : ""

    onPressed: function(b) {
      if (b === Qt.RightButton || b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    // In a vertical bar the slot is icon-sized, so the glyph stands alone
    // and the countdown lives in the panel.
    OpticalGlyph {
      visible: root.vertical
      width: button.width
      height: Style.bar.iconSlot
      text: root.glyph
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.foreground
    }

    // New-registration badge: an accent dot in the slot corner, cleared
    // the next time the panel opens.
    Rectangle {
      visible: root.hasNewRegistrations
      width: Style.space(8)
      height: Style.space(8)
      radius: width / 2
      color: Color.accent
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(4)
      anchors.rightMargin: Style.space(2)
    }
  }
}
