import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Luma popup: every future event in one list, in date order — the
// events you attend and the events you host. Hosted rows carry a Host
// marker and guests/capacity once an API key is present.
//
// This panel owns all data and polling. BarWidget.qml owns the bar label
// and hands this panel the button to anchor against. The lib/ scripts read
// the secrets file themselves, so no feed URL or API key ever enters this
// process or its arguments.
Panel {
  id: root
  moduleName: "studiotwin.luma"
  ipcTarget: "studiotwin.luma"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not
  // this nested panel, so everything the bar identifies a panel by has to
  // be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings (manifest defaults, spec section 9).
  readonly property string secretsPath: String(setting("secretsFilePath", "~/.config/omarchy/luma.env")).replace(/^~/, Quickshell.env("HOME"))
  readonly property int refreshMs: Model.clampRefreshInterval(setting("refreshIntervalSec", 1800)) * 1000
  readonly property int maxEvents: Model.clampMaxEvents(setting("maxEvents", 10))

  // ---- Data state.
  // feedState: loading | ok | missing | insecure | nourl | network | error
  // apiState:  off | ok | auth | ratelimited | network | error
  property string feedState: "loading"
  property string apiState: "off"
  property var feedEvents: []
  property var hostedEvents: []
  property var guestCountsById: ({})
  property var previousGuestCounts: null
  property bool hasNewRegistrations: false
  property real lastGoodPollMs: 0
  property int selectedIndex: 0

  property date now: new Date()

  readonly property var events: Model.futureEvents(
    Model.mergeHostData(feedEvents, hostedEvents, guestCountsById),
    now.getTime(), maxEvents)
  readonly property string barLabel: Model.barLabel(events.length > 0 ? events[0] : null, now.getTime())

  readonly property bool needsSetup: feedState === "missing" || feedState === "insecure" || feedState === "nourl"
  readonly property string setupHint: feedState === "insecure"
    ? "Secrets file must be private: chmod 600 " + secretsPath
    : feedState === "nourl"
      ? "Add LUMA_ICS_URL=… to " + secretsPath
      : "Create " + secretsPath + " (chmod 600) with\nLUMA_ICS_URL=<your Luma calendar subscription URL>"

  readonly property string footerText: {
    if (apiState === "auth") return "Invalid API key"
    if (feedState === "network" || apiState === "network")
      return "offline · " + Model.lastPollLabel(lastGoodPollMs, now.getTime())
    if (apiState === "ratelimited") return "Luma API rate limited, retrying"
    return Model.lastPollLabel(lastGoodPollMs, now.getTime())
  }

  // Guarded so the panel renders before the bar is injected (the
  // bar-widget contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function scriptPath(name) {
    return String(Qt.resolvedUrl("lib/" + name)).replace(/^file:\/\//, "")
  }

  function open() {
    root.selectedIndex = 0
    root.hasNewRegistrations = false
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    root.now = new Date()
    apiBackoffTimer.stop()
    root.apiBackoffMs = 0
    if (!feedProc.running) feedProc.running = true
    refreshHostData()
  }

  function refreshHostData() {
    if (apiListProc.running) return
    apiListProc.command = ["bash", root.scriptPath("luma-api"), root.secretsPath, "list", new Date().toISOString()]
    apiListProc.running = true
  }

  function openEvent(event) {
    if (event && event.url) Qt.openUrlExternally(event.url)
  }

  function openSelected() {
    if (root.events.length === 0) return
    var index = Math.min(root.selectedIndex, root.events.length - 1)
    openEvent(root.events[index])
  }

  function moveSelection(delta) {
    if (root.events.length === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.events.length - 1, root.selectedIndex + delta))
  }

  // ---- Feed poll: the personal iCal feed, every refreshIntervalSec.
  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.now = new Date()
      if (!feedProc.running) feedProc.running = true
    }
  }

  Process {
    id: feedProc
    command: ["bash", root.scriptPath("luma-fetch"), root.secretsPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.splitScriptOutput(text)
        if (result.status === "ok") {
          root.feedEvents = Model.parseIcs(result.payload)
          root.feedState = "ok"
          root.lastGoodPollMs = Date.now()
        } else if (result.status === "network") {
          // Keep the last data; the footer shows the last good poll.
          root.feedState = "network"
        } else {
          root.feedState = result.status
        }
      }
    }
  }

  // ---- Host poll: the calendar API, every 10 minutes (spec section 8).
  //      The script answers "nokey" without any network request when the
  //      secrets file has no LUMA_API_KEY, which keeps this timer cheap.
  property var detailQueue: []
  property int apiBackoffMs: 0

  Timer {
    interval: 600000
    running: true
    repeat: true
    onTriggered: {
      root.now = new Date()
      if (!apiBackoffTimer.running) root.refreshHostData()
    }
  }

  Timer {
    id: apiBackoffTimer
    interval: root.apiBackoffMs
    onTriggered: root.refreshHostData()
  }

  // A 429 waits, doubles the wait, and tries again (spec section 11).
  function scheduleApiBackoff() {
    root.apiState = "ratelimited"
    root.apiBackoffMs = root.apiBackoffMs > 0 ? Math.min(root.apiBackoffMs * 2, 1200000) : 60000
    apiBackoffTimer.restart()
  }

  Process {
    id: apiListProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.splitScriptOutput(text)
        if (result.status === "ok") {
          var entries = Model.parseApiEntries(result.payload)
          if (entries === null) {
            root.apiState = "error"
            return
          }
          root.apiState = "ok"
          root.apiBackoffMs = 0
          root.hostedEvents = entries
          // Guest counts come from one small detail call per hosted event;
          // with maxEvents of them each poll this stays far below the
          // API's ~200 requests/minute.
          root.detailQueue = entries.slice(0, root.maxEvents).map(function(e) { return e.id })
          root.runNextDetail()
        } else if (result.status === "nokey" || result.status === "missing" || result.status === "insecure") {
          // No key (or no usable secrets file at all) is the documented
          // version-0.1 mode, not an error: all events, no host data.
          root.apiState = "off"
          root.hostedEvents = []
          root.guestCountsById = {}
        } else if (result.status === "auth") {
          root.apiState = "auth"
        } else if (result.status === "ratelimited") {
          root.scheduleApiBackoff()
        } else if (result.status === "network") {
          root.apiState = "network"
        } else {
          root.apiState = "error"
        }
      }
    }
  }

  function runNextDetail() {
    if (root.detailQueue.length === 0) {
      root.finishHostPoll()
      return
    }
    // The stream can finish a tick before the process flips to not-running;
    // retry on the next event-loop pass rather than dropping the queue.
    if (apiDetailProc.running) {
      Qt.callLater(root.runNextDetail)
      return
    }
    var queue = root.detailQueue.slice()
    root.pendingDetailId = queue.shift()
    root.detailQueue = queue
    apiDetailProc.command = ["bash", root.scriptPath("luma-api"), root.secretsPath, "detail", root.pendingDetailId]
    apiDetailProc.running = true
  }

  property string pendingDetailId: ""

  Process {
    id: apiDetailProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.splitScriptOutput(text)
        if (result.status === "ok") {
          var count = Model.guestCountFromDetail(result.payload)
          if (count !== null) {
            var counts = {}
            for (var id in root.guestCountsById) counts[id] = root.guestCountsById[id]
            counts[root.pendingDetailId] = count
            root.guestCountsById = counts
          }
        } else if (result.status === "ratelimited") {
          root.detailQueue = []
          root.scheduleApiBackoff()
          return
        }
        // Other failures fall back to capacity minus spots remaining from
        // the list response; nothing to do here.
        root.runNextDetail()
      }
    }
  }

  // The registration badge: any hosted count above the previous poll's.
  // The first completed poll seeds the baseline and never badges.
  function finishHostPoll() {
    var check = Model.newRegistrationCheck(root.previousGuestCounts, root.hostedEvents, root.guestCountsById)
    if (check.grew && !root.opened) root.hasNewRegistrations = true
    root.previousGuestCounts = check.counts
  }

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.now = date
  }

  // ---- Layout.
  readonly property int rowHeight: Style.space(46)
  readonly property int panelWidth: Style.space(430)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(16))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: root.openSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(8)
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(6)

          // ---- Header: wordmark left, next-event countdown right.
          Item {
            width: parent.width
            height: Style.space(26)

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "LUMA"
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.letterSpacing: 2
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.events.length > 0
              text: {
                var days = root.events.length > 0 ? Model.daysUntil(root.events[0].startMs, root.now.getTime()) : 0
                return days <= 0 ? "next event today" : "next event in " + days + (days === 1 ? " day" : " days")
              }
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---- Setup hint: no secrets, no network requests, just the way
          //      forward (spec section 11).
          Text {
            visible: root.needsSetup
            width: parent.width
            text: root.setupHint
            wrapMode: Text.Wrap
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            visible: !root.needsSetup && root.feedState !== "loading" && root.events.length === 0
            width: parent.width
            text: "No events"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          // ---- The event list.
          Repeater {
            model: root.events

            Rectangle {
              id: row
              required property var modelData
              required property int index

              width: contentColumn.width
              height: root.rowHeight
              radius: Style.cornerRadius
              color: index === root.selectedIndex || rowMouse.containsMouse
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : "transparent"

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.selectedIndex = row.index
                  root.openEvent(row.modelData)
                }
              }

              // Date and start time in a fixed gutter, so names align.
              Column {
                id: whenColumn
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(88)

                Text {
                  text: Model.dateLabel(row.modelData.startMs, root.now.getTime())
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  text: Model.timeLabel(row.modelData.startMs)
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Column {
                anchors.left: whenColumn.right
                anchors.leftMargin: Style.space(10)
                anchors.right: hostColumn.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  text: row.modelData.name
                  elide: Text.ElideRight
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  visible: row.modelData.city !== ""
                  text: row.modelData.city
                  elide: Text.ElideRight
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              // Hosted events carry the Host marker and guests/capacity.
              Column {
                id: hostColumn
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                width: row.modelData.hosted ? Style.space(52) : 0

                Text {
                  visible: row.modelData.hosted
                  anchors.right: parent.right
                  text: "HOST"
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  font.bold: true
                }

                Text {
                  visible: row.modelData.hosted && row.modelData.guests !== null
                  anchors.right: parent.right
                  text: row.modelData.guests + " / " + (row.modelData.capacity !== null ? row.modelData.capacity : "∞")
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          // ---- Footer: freshness and error states.
          Text {
            visible: root.footerText !== "" && !root.needsSetup
            width: parent.width
            horizontalAlignment: Text.AlignRight
            text: root.footerText
            color: root.apiState === "auth"
              ? Color.accent
              : Qt.darker(root.contentForeground, 1.8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
