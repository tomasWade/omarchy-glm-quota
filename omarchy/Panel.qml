pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail panel and data owner. The bar gauge and this panel read the same
// state: a `report` with two windows (fiveHour, weekly), each carrying used /
// quota / nextResetMs / windowMs. The floating caret positions are derived
// here from the wall clock, so they advance between polls without any
// network traffic.
//
// demo: true renders a canned report (no process, no key) — the numbers are
// fixed but the carets still move with real time, which is what the visual
// preview needs to show.
Panel {
  id: root
  moduleName: "tomaswade.glm-quota"
  ipcTarget: "tomaswade.glm-quota"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so popout coordination identifies as that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The panel draws on the popup card, so it takes the popup text token.
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.darker(Color.popups.text, 1.55)
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string fontFam: bar ? bar.fontFamily : Style.font.family

  // ---- settings --------------------------------------------------------------
  readonly property int refreshMinutes: Math.max(2, parseInt(setting("refreshMinutes", 10), 10) || 10)
  readonly property string keyFileSetting: String(setting("keyFile", "") || "")
  readonly property bool demo: setting("demo", false) === true

  // ---- i18n --------------------------------------------------------------------
  // "auto" follows the system locale (Chinese when it starts with "zh"),
  // "zh"/"en" force a language regardless of locale.
  readonly property string langSetting: String(setting("language", "auto") || "auto").toLowerCase()
  readonly property bool useZh: langSetting === "zh"
    || (langSetting !== "en" && Qt.locale().name.toLowerCase().indexOf("zh") === 0)
  function tr(zh, en) { return useZh ? zh : en }

  // ---- data --------------------------------------------------------------------
  property var report: null
  // Machine-readable failure code from the script (nokey/unauthorized/
  // network/badresp) or from the loader itself (nooutput/parsefail). Empty
  // when the last fetch succeeded.
  property string errorCode: ""
  property bool pluginStale: false
  // Wall clock, reticked below — every caret binding reads this, not
  // Date.now() directly, so one timer moves them all.
  property real nowMs: Date.now()

  // ---- fetch state machine ---------------------------------------------------
  // Mirrors meteobar: processDone/collectorDone pair + exit fallback timer.
  // Our script's contract is "always one JSON line, always exit 0", so the
  // error paths here only guard against the script itself going missing.
  property bool processDone: true
  property bool collectorDone: true
  property string capturedText: ""
  property bool pendingForce: false
  property real lastSuccessAt: 0
  readonly property bool fetchBusy: !(processDone && collectorDone)

  readonly property string scriptPath: {
    var u = Qt.resolvedUrl("../bin/glm-quota").toString()
    return u.startsWith("file://") ? u.substring(7) : u
  }

  readonly property var fiveHour: (report && report.fiveHour) ? report.fiveHour : null
  readonly property var weekly: (report && report.weekly) ? report.weekly : null
  readonly property bool hasData: !!(fiveHour && weekly)
  readonly property string level: (report && report.level) ? String(report.level) : ""

  function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v) }

  function windowRatio(w) {
    if (!w || !(w.quota > 0)) return 0
    return clamp01(Number(w.used) / Number(w.quota))
  }

  // Time through the window: the API only tells us when the window ENDS
  // (nextResetMs); its start is nextResetMs - windowMs, so the share of time
  // spent is 1 - remaining/total.
  function windowPointer(w) {
    if (!w || !(w.windowMs > 0) || !(w.nextResetMs > 0)) return -1
    return clamp01(1 - (Number(w.nextResetMs) - nowMs) / Number(w.windowMs))
  }

  readonly property real fiveHourRatio: windowRatio(fiveHour)
  readonly property real fiveHourPointer: windowPointer(fiveHour)
  readonly property real weeklyRatio: windowRatio(weekly)
  readonly property real weeklyPointer: windowPointer(weekly)

  // Bar gauge + tooltip read these off the loaded panel item.
  readonly property string barTooltip: {
    if (!hasData) return demo ? tr("GLM 用量（演示数据）", "GLM usage (demo)") : tr("GLM 用量", "GLM usage")
    var pct = Math.round(weeklyRatio * 100)
    return demo
      ? tr("GLM 周用量 ", "GLM weekly ") + pct + tr("%（演示）", "% (demo)")
      : tr("GLM 周用量 ", "GLM weekly ") + pct + "% · " + fmtRemaining(weekly.nextResetMs - nowMs)
  }

  // ---- formatting ------------------------------------------------------------
  function fmtInt(n) {
    return String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }

  function fmtRemaining(untilMs) {
    var ms = Number(untilMs) - nowMs
    if (!(ms > 0)) return tr("即将刷新", "resets now")
    var m = Math.floor(ms / 60000)
    if (m < 1) return tr("1 分钟内刷新", "resets within a minute")
    if (m < 60) return tr(m + " 分钟后刷新", "resets in " + m + " min")
    var h = Math.floor(m / 60)
    var mm = m % 60
    if (h < 48) return tr(h + " 时 " + mm + " 分后刷新", "resets in " + h + "h " + mm + "m")
    var d = Math.floor(h / 24)
    return tr(d + " 天 " + (h % 24) + " 时后刷新", "resets in " + d + "d " + (h % 24) + "h")
  }

  function fmtClock(ms) {
    var d = new Date(Number(ms) || 0)
    return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
  }

  // ---- demo payload ------------------------------------------------------------
  // Canned usage numbers; window anchors derive from the epoch so the carets
  // advance with the real clock and survive hot reloads within a window.
  function makeDemoReport() {
    var wk = 7 * 24 * 3600 * 1000
    var fh = 5 * 3600 * 1000
    var now = Date.now()
    return {
      demo: true,
      level: "pro",
      fetchedAt: now,
      stale: false,
      fiveHour: {
        used: 7643, quota: 12000, remaining: 12000 - 7643,
        windowMs: fh, nextResetMs: (Math.floor(now / fh) + 1) * fh
      },
      weekly: {
        used: 27168, quota: 60000, remaining: 60000 - 27168,
        windowMs: wk, nextResetMs: (Math.floor(now / wk) + 1) * wk
      }
    }
  }

  // ---- lifecycle ----------------------------------------------------------------
  function open() {
    root.controller.show()
    // Popup-open auto-refresh: only when the data is stale by script-layer
    // standards (cache TTL 240s). Refetching sooner would just replay the
    // cached report — and clobber a key/network error state set by a forced
    // refresh moments earlier.
    if (!demo && Date.now() - lastSuccessAt > 240 * 1000) refresh(false)
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? close() : open() }

  function refresh(force) {
    if (demo) {
      report = makeDemoReport()
      errorCode = ""
      pluginStale = false
      return
    }
    if (glmProc.running) {
      pendingForce = pendingForce || force === true
      return
    }
    var cmd = [scriptPath]
    if (keyFileSetting !== "") cmd.push("--key-file", keyFileSetting)
    if (force === true) cmd.push("--force")
    processDone = false
    collectorDone = false
    capturedText = ""
    // Through sh, never direct (meteobar's lesson): a missing binary can
    // abort the whole Quickshell process before any QML signal fires.
    glmProc.command = ["/bin/sh", "-c", 'exec "$0" "$@"'].concat(cmd)
    glmProc.running = true
  }

  function maybeFinalize() {
    if (fetchBusy) return
    exitFallback.stop()
    finalizeRun()
  }

  function finalizeRun() {
    var text = capturedText.trim()
    if (text === "") {
      errorCode = "nooutput"
      if (!report) report = makeEmptyReport()
    } else {
      // The script prints exactly one JSON object; be lenient about a stray
      // trailing newline by taking the first non-empty line.
      var firstLine = text.split("\n")[0]
      try {
        var parsed = JSON.parse(firstLine)
        report = parsed
        errorCode = parsed.error || ""
        pluginStale = parsed.stale === true
        if (!pluginStale) lastSuccessAt = Date.now()
      } catch (e) {
        errorCode = "parsefail"
        if (!report) report = makeEmptyReport()
      }
    }
    // A refresh that arrived while this run was in flight was parked in
    // pendingForce — replay it now that the process is free.
    if (pendingForce) {
      pendingForce = false
      Qt.callLater(function() { refresh(true) })
    }
  }

  function makeEmptyReport() {
    return {
      level: "", fetchedAt: Date.now(), stale: true, error: errorCode,
      fiveHour: null, weekly: null
    }
  }

  // Localized label for the current error code (footer + guidance).
  function errorLabel() {
    switch (errorCode) {
      case "": return ""
      case "nokey": return tr("API key 未配置", "API key missing")
      case "unauthorized": return tr("API key 无效或已过期", "API key invalid or expired")
      case "network": return tr("网络错误", "network error")
      case "badresp": return tr("接口返回异常", "unexpected API response")
      case "nooutput": return tr("glm-quota 无输出", "glm-quota produced no output")
      case "parsefail": return tr("无法解析输出", "could not parse output")
      default: return errorCode
    }
  }

  // Actionable hint for the two key-related failures. The path shown is the
  // effective key file: the setting override, or api.key at the plugin root.
  readonly property bool keyTrouble: errorCode === "nokey" || errorCode === "unauthorized"
  readonly property string keyPathShown: {
    if (keyFileSetting !== "") return keyFileSetting
    var i = scriptPath.lastIndexOf("/bin/")
    return i > 0 ? scriptPath.substring(0, i) + "/api.key" : scriptPath + ".key"
  }
  readonly property string keyGuidance: useZh
    ? "⚠ 请到 open.bigmodel.cn 控制台创建 API Key，保存到 " + keyPathShown + "（单行纯 key，建议 chmod 600）"
    : "⚠ Create an API key in the open.bigmodel.cn console and save it to " + keyPathShown + " (single line, chmod 600 recommended)"

  Component.onCompleted: refresh(false)

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(true) }
    function state(): string {
      return JSON.stringify({
        langSetting: root.langSetting, useZh: root.useZh,
        settings: root.settings, errorCode: root.errorCode,
        refreshMinutes: root.refreshMinutes, demo: root.demo
      })
    }
  }

  Process {
    id: glmProc
    // A command that does not exist gives NEITHER started NOR exited —
    // Quickshell drops running back to false silently. This handler is what
    // un-sticks the panel in that case.
    onRunningChanged: {
      if (running) return
      processDone = true
      exitFallback.restart()
      maybeFinalize()
    }
    onExited: {
      processDone = true
      exitFallback.restart()
      maybeFinalize()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        capturedText = text
        collectorDone = true
        maybeFinalize()
      }
    }
  }

  Timer {
    id: exitFallback
    interval: 300
    repeat: false
    onTriggered: {
      collectorDone = true
      maybeFinalize()
    }
  }

  // Caret heartbeat: every 20s is plenty for a mark whose whole job is
  // "roughly where in the window are we".
  Timer {
    interval: 20 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // Data poll: the script layer caches (TTL 240s), so this fires the process
  // every refreshMinutes but only leaves the LAN as often as the TTL allows.
  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: !root.demo
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // ---- card ---------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r") root.refresh(true) }

      Flickable {
        id: contentScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: contentScroll.width
          spacing: Style.space(12)

          // ---- header: title, level, updated, refresh ----------------------
          Item {
            width: parent.width
            implicitHeight: headerRow.implicitHeight

            Row {
              id: headerRow
              spacing: Style.space(10)

              Text {
                text: root.tr("GLM 用量", "GLM Usage")
                color: root.fg
                font.family: root.fontFam
                font.pixelSize: Style.font.display * 0.75
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                visible: root.level !== ""
                width: levelLabel.implicitWidth + Style.space(10)
                height: levelLabel.implicitHeight + Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
                border.width: 1
                border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.30)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: levelLabel
                  anchors.centerIn: parent
                  text: root.level
                  color: root.dim
                  font.family: root.fontFam
                  font.pixelSize: Style.font.caption
                }
              }

              Item { width: 1; height: 1 }

              Text {
                visible: root.report !== null
                text: (root.pluginStale ? "⚠ " : "")
                  + (root.report ? root.tr("更新于 ", "updated ") + root.fmtClock(root.report.fetchedAt) : "")
                color: root.pluginStale ? root.urgentColor : root.dim
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelActionButton {
              anchors.right: parent.right
              iconText: root.fetchBusy ? "…" : "󰑓"
              foreground: root.fg
              fontFamily: root.fontFam
              tooltipText: root.tr("刷新 (r)", "Refresh (r)")
              enabled: !root.fetchBusy
              onClicked: root.refresh(true)
            }
          }

          QuotaSection {
            width: parent.width
            title: root.tr("5 小时窗口", "5-Hour Window")
            win: root.fiveHour
            ratio: root.fiveHourRatio
            pointer: root.fiveHourPointer
            nowMs: root.nowMs
            fg: root.fg
            dim: root.dim
            urgent: root.urgentColor
            fontFam: root.fontFam
            tr: function(zh, en) { return root.tr(zh, en) }
            fmtInt: function(n) { return root.fmtInt(n) }
            fmtRemaining: function(ms) { return root.fmtRemaining(ms) }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.dim
          }

          QuotaSection {
            width: parent.width
            title: root.tr("本周", "This Week")
            win: root.weekly
            ratio: root.weeklyRatio
            pointer: root.weeklyPointer
            nowMs: root.nowMs
            fg: root.fg
            dim: root.dim
            urgent: root.urgentColor
            fontFam: root.fontFam
            tr: function(zh, en) { return root.tr(zh, en) }
            fmtInt: function(n) { return root.fmtInt(n) }
            fmtRemaining: function(ms) { return root.fmtRemaining(ms) }
          }

          Text {
            visible: root.keyTrouble
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.keyGuidance
            color: root.urgentColor
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            text: (root.demo ? root.tr("演示数据", "demo data") + " · " : "")
              + (root.errorCode !== "" ? root.errorLabel() + " · " : "")
              + root.tr("数据 open.bigmodel.cn", "data: open.bigmodel.cn")
            color: root.dim
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // ---- one quota section -----------------------------------------------------
  component QuotaSection: Column {
    id: section

    property string title: ""
    property var win: null
    property real ratio: 0
    property real pointer: -1
    property real nowMs: 0
    property color fg: Color.foreground
    property color dim: Color.foreground
    property color urgent: Color.urgent
    property string fontFam: Style.font.family
    property var tr: function(zh, en) { return zh }
    property var fmtInt: function(n) { return String(n) }
    property var fmtRemaining: function(ms) { return "" }

    spacing: Style.space(6)

    function alphaOf(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    Row {
      width: parent.width
      spacing: Style.space(8)

      PanelSectionHeader {
        text: section.title
        foreground: section.fg
        fontFamily: section.fontFam
        anchors.verticalCenter: parent.verticalCenter
      }

      Item { width: 1; height: 1 }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: section.win
          ? section.fmtInt(section.win.used) + " / " + section.fmtInt(section.win.quota)
          : "— / —"
        color: section.fg
        font.family: section.fontFam
        font.pixelSize: Style.font.body
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: section.win ? Math.round(section.ratio * 100) + "%" : ""
        color: section.ratio >= 0.9 ? section.urgent : (section.ratio >= 0.75 ? section.fg : section.dim)
        font.family: section.fontFam
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: section.win ? section.tr("剩 ", "") + section.fmtInt(section.win.remaining) + section.tr("", " left") : ""
        color: section.dim
        font.family: section.fontFam
        font.pixelSize: Style.font.caption
      }
    }

    QuotaBar {
      width: parent.width
      ratio: section.ratio
      pointer: section.pointer
      fg: section.fg
      trackHeight: 9
      tickHeight: 5
      caretHeight: 6
      caretWidth: 9
      gap: 3
    }

    Text {
      text: section.win
        ? section.tr("时间进度 ", "time ") + Math.max(0, Math.round(section.pointer * 100)) + "% · " + section.fmtRemaining(section.win.nextResetMs)
        : ""
      color: section.dim
      font.family: section.fontFam
      font.pixelSize: Style.font.caption
    }
  }
}
