import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Luma popup: every future event in one list, in date order. The feed
// is the standard Omarchy community calendar until the user connects a
// personal iCal subscription (see ./setup).
//
// This panel owns all data and polling. BarWidget.qml owns the bar slot
// and hands this panel the button to anchor against. lib/luma-fetch reads
// the secrets file itself, so the feed URL never enters this process or
// its arguments.
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
  readonly property int maxEvents: Model.clampMaxEvents(setting("maxEvents", 30))

  // ---- Data state.
  // feedState: loading | ok | default | insecure | network | error
  //            ("default" is the standard Omarchy community calendar,
  //            served until a personal feed URL is configured)
  property string feedState: "loading"
  property var feedEvents: []
  // slug → thumb URL; "" is a resolved page without a cover (negative
  // cache), absence means not fetched yet. In-memory only, like all data.
  property var coverUrlsBySlug: ({})
  property real lastGoodPollMs: 0
  property int selectedIndex: 0

  property date now: new Date()

  readonly property var events: Model.futureEvents(feedEvents, now.getTime(), maxEvents)
  readonly property string barLabel: Model.barLabel(events.length > 0 ? events[0] : null, now.getTime())

  readonly property string nextEventLabel: {
    if (events.length === 0) return ""
    var days = Model.daysUntil(events[0].startMs, now.getTime())
    return days <= 0 ? "next event today" : "next event in " + days + (days === 1 ? " day" : " days")
  }

  readonly property bool needsSetup: feedState === "insecure"
  readonly property string setupHint: "Secrets file must be private: chmod 600 " + secretsPath

  readonly property string footerText: {
    if (feedState === "network")
      return "offline · " + Model.lastPollLabel(lastGoodPollMs, now.getTime())
    var label = Model.lastPollLabel(lastGoodPollMs, now.getTime())
    if (feedState === "default")
      return label === "" ? "Omarchy calendar" : "Omarchy calendar · " + label
    return label
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
    if (typeof listFlick !== "undefined" && listFlick) listFlick.contentY = 0
    // Covers that failed (network) or never queued (a poll the panel
    // missed) get another chance every time the panel opens.
    root.queueCoverFetches()
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
    if (!feedProc.running) feedProc.running = true
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
    ensureSelectedVisible()
  }

  // Keyboard navigation scrolls the list so the selection stays on screen,
  // clear of the scroll-hint gradient at the bottom edge.
  function ensureSelectedVisible() {
    var maxY = Math.max(0, listFlick.contentHeight - listFlick.height)
    // The last row scrolls clear to the end, so the footer comes into view
    // and the scroll-hint gradient stands down.
    if (root.selectedIndex >= root.events.length - 1) {
      listFlick.contentY = maxY
      return
    }
    var rowTop = rowsColumn.y + root.selectedIndex * (root.rowHeight + Style.space(2))
    var rowBottom = rowTop + root.rowHeight
    var slack = Style.space(22)
    if (rowTop < listFlick.contentY)
      listFlick.contentY = Math.max(0, rowTop)
    else if (rowBottom > listFlick.contentY + listFlick.height - slack)
      listFlick.contentY = Math.min(rowBottom - listFlick.height + slack, maxY)
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
        if (result.status === "ok" || result.status === "default") {
          root.feedEvents = Model.parseIcs(result.payload)
          root.feedState = result.status
          root.lastGoodPollMs = Date.now()
          root.queueCoverFetches()
        } else if (result.status === "network") {
          // Keep the last data; the footer shows the last good poll.
          root.feedState = "network"
        } else {
          root.feedState = result.status
        }
      }
    }
  }

  // ---- Cover art: one event-page fetch per unknown slug, serialized so
  //      only one curl runs at a time and paced so luma.com never sees a
  //      burst. The page HTML yields the cover URL through
  //      Model.coverUrlFromHtml; a network failure stays uncached so the
  //      next refresh retries it, and a 429 pauses the whole queue with a
  //      doubling backoff (Cloudflare rate-limits the event pages).
  property var coverQueue: []
  property var pendingCover: null
  property int coverBackoffMs: 0

  function queueCoverFetches() {
    var queue = root.coverQueue.slice()
    var queued = {}
    for (var i = 0; i < queue.length; i++) queued[queue[i].slug] = true
    if (coverProc.running && root.pendingCover) queued[root.pendingCover.slug] = true
    var list = root.events
    for (var j = 0; j < list.length; j++) {
      var event = list[j]
      if (!event.slug || !event.url) continue
      if (root.coverUrlsBySlug[event.slug] !== undefined || queued[event.slug]) continue
      queue.push({ slug: event.slug, url: event.url })
      queued[event.slug] = true
    }
    root.coverQueue = queue
    root.runNextCover()
  }

  function runNextCover() {
    if (root.coverQueue.length === 0) return
    if (coverBackoffTimer.running || coverPaceTimer.running) return
    if (coverProc.running) {
      Qt.callLater(root.runNextCover)
      return
    }
    var queue = root.coverQueue.slice()
    root.pendingCover = queue.shift()
    root.coverQueue = queue
    coverProc.command = ["bash", root.scriptPath("luma-cover"), root.pendingCover.url, root.pendingCover.slug]
    coverProc.running = true
  }

  // ~40 requests/minute at most, far under a browsing session's page rate.
  Timer {
    id: coverPaceTimer
    interval: 1500
    onTriggered: root.runNextCover()
  }

  Timer {
    id: coverBackoffTimer
    interval: root.coverBackoffMs
    onTriggered: root.runNextCover()
  }

  Process {
    id: coverProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = Model.splitScriptOutput(text)
        if (result.status === "ok" || result.status === "none" || result.status === "cached") {
          var url = ""
          if (result.status === "ok") url = Model.coverUrlFromHtml(result.payload)
          else if (result.status === "cached") url = result.payload.replace(/\s+$/, "")
          var covers = {}
          for (var slug in root.coverUrlsBySlug) covers[slug] = root.coverUrlsBySlug[slug]
          covers[root.pendingCover.slug] = url
          root.coverUrlsBySlug = covers
          root.coverBackoffMs = 0
          // Persist live resolutions so the page is never fetched again on
          // this machine; the store script ignores demo file:// covers.
          if (result.status !== "cached")
            Quickshell.execDetached(["bash", root.scriptPath("luma-cover-store"), root.pendingCover.slug, url])
          // A cache hit costs no request, so it needs no pacing gap.
          if (result.status === "cached") root.runNextCover()
          else coverPaceTimer.restart()
        } else if (result.status === "ratelimited") {
          // Put the event back and hold the queue: 2 minutes, doubling to
          // a 20-minute cap while the rate limit persists.
          var queue = root.coverQueue.slice()
          queue.unshift(root.pendingCover)
          root.coverQueue = queue
          root.coverBackoffMs = root.coverBackoffMs > 0 ? Math.min(root.coverBackoffMs * 2, 1200000) : 120000
          coverBackoffTimer.restart()
        } else {
          // "network" and script errors stay uncached; the next refresh or
          // panel open queues them again.
          coverPaceTimer.restart()
        }
      }
    }
  }

  SystemClock {
    precision: SystemClock.Minutes
    onDateChanged: root.now = date
  }

  // ---- Layout.
  readonly property int rowHeight: Style.space(56)
  readonly property int panelWidth: Style.space(480)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    // Capped like the agents dashboard; a longer event list scrolls inside,
    // under the fixed hero header.
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight + Style.space(12) + contentColumn.implicitHeight,
      Style.space(640))

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

      // ---- Fixed header: the hero and its divider stay put while the
      //      list scrolls underneath.
      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        // Exposed for the hero's trailingControl, whose `root` resolves to
        // PanelHero (not this Panel) — reach panel state via `headerColumn`.
        readonly property bool refreshBusy: feedProc.running
        function doRefresh() { root.refresh() }

        // ---- Hero: the Luma mark, the name, and the next-event
        //      countdown — the same header shape the agents panel uses
        //      for its provider mark.
        PanelHero {
          id: hero
          width: parent.width
          title: "Luma"
          meta: root.nextEventLabel
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily

          iconComponent: Component {
            LumaMark {
              width: Style.font.display
              height: Style.font.display
              tint: root.contentForeground
            }
          }

          // Refresh on demand: re-poll the feed and any covers that are
          // still missing. The R key does the same.
          trailingControl: Component {
            PanelActionButton {
              iconText: "󰑐"
              tooltipText: "Refresh (R)"
              foreground: hero.foreground
              fontFamily: hero.fontFamily
              enabled: !headerColumn.refreshBusy
              onClicked: headerColumn.doRefresh()
            }
          }
        }

        PanelSeparator {
          foreground: root.contentForeground
        }
      }

      // No extra margins: KeyboardPanel already pads its content area with
      // Style.spacing.popupPadding, which is all the agents panel uses too.
      Flickable {
        id: listFlick
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          // The agents panel's section rhythm: sections sit Style.space(12)
          // apart with a PanelSeparator between them; the event rows keep
          // their own tighter spacing in a nested column.
          spacing: Style.space(12)

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
          Column {
            id: rowsColumn
            width: parent.width
            spacing: Style.space(2)

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

                // Cover art from the event page, the Luma mark until it
                // arrives (or when the page has none). Same idiom as the
                // media widget's album art.
                BorderSurface {
                  id: coverThumb
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(46)
                  height: Style.space(46)
                  radius: Style.spacing.labelGap
                  color: Style.normalFillFor(root.contentForeground, Color.accent)
                  borderSpec: Border.controlSpec("normal", root.contentForeground, Color.accent)

                  Image {
                    id: coverImage
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    source: root.coverUrlsBySlug[row.modelData.slug] || ""
                    visible: status === Image.Ready
                  }

                  LumaMark {
                    anchors.centerIn: parent
                    visible: !coverImage.visible
                    width: Style.space(18)
                    height: Style.space(18)
                    tint: Qt.darker(root.contentForeground, 1.4)
                  }
                }

                // Date and start time in a fixed gutter, so names align.
                Column {
                  id: whenColumn
                  anchors.left: coverThumb.right
                  anchors.leftMargin: Style.space(10)
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
                  anchors.right: parent.right
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
              }
            }
          }

          // ---- Footer: freshness and error states.
          PanelSeparator {
            visible: root.footerText !== "" && !root.needsSetup
            foreground: root.contentForeground
          }

          Text {
            visible: root.footerText !== "" && !root.needsSetup
            width: parent.width
            horizontalAlignment: Text.AlignRight
            text: root.footerText
            color: Qt.darker(root.contentForeground, 1.8)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---- Scroll affordance: a fade-out gradient over the list's bottom
      //      edge while there is more below, with a "scroll down" hint that
      //      disappears once the user starts scrolling. No mouse handlers,
      //      so clicks pass through to the rows underneath.
      Item {
        id: scrollHint
        anchors.left: listFlick.left
        anchors.right: listFlick.right
        anchors.bottom: listFlick.bottom
        height: Style.space(44)
        visible: opacity > 0
        opacity: listFlick.interactive && !listFlick.atYEnd ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }

        Rectangle {
          anchors.fill: parent
          gradient: Gradient {
            GradientStop {
              position: 0
              color: Qt.rgba(Color.popups.background.r, Color.popups.background.g,
                             Color.popups.background.b, 0)
            }
            GradientStop { position: 1; color: Color.popups.background }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          text: "scroll down 󰅀"
          opacity: listFlick.atYBeginning ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 160 } }
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
