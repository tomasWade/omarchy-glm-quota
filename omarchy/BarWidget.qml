pragma ComponentBehavior: Bound
import QtQuick
import qs.Ui
import qs.Commons

// Bar entry point: the thermometer gauge for the WEEKLY window only (the
// 5-hour breakdown lives in the panel). All state and fetching live in
// Panel.qml, loaded once here; the gauge just mirrors its properties.
BarWidget {
  id: root
  moduleName: "tomasWade.glm-quota"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = gaugeHost
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh(force) {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(force)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (Bar.requestPopout prefers closeForPopoutSwitch over close).
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  // How wide the bar's open-panel underline should be — the honest painted
  // extent of the gauge, not a fraction of its slot.
  readonly property real openPanelIndicatorWidth: gauge.width

  onBarChanged: {
    injectPanel()
    syncClickRegistration()
  }
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

  // Click-target registration, mirroring WidgetButton: while this widget's
  // panel is open, its dismissal overlay forwards clicks that land on the
  // bar strip back to registered targets via triggerPress.
  property var registeredBar: null

  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)

  function triggerPress(button) {
    if (root.bar) root.bar.hideTooltip(root)
    if (button === Qt.MiddleButton) root.refresh(true)
    else if (button !== Qt.RightButton) root.togglePanel()
  }

  readonly property bool hasData: panelLoader.item ? panelLoader.item.hasData === true : false

  implicitWidth: gauge.width + Style.space(16)
  implicitHeight: barSize

  Item {
    id: gaugeHost
    anchors.centerIn: parent
    width: gauge.width
    height: gauge.height

    QuotaBar {
      id: gauge
      anchors.centerIn: parent
      width: Style.space(96)
      ratio: panelLoader.item ? panelLoader.item.weeklyRatio : 0
      pointer: panelLoader.item ? panelLoader.item.weeklyPointer : -1
      fg: root.bar ? root.bar.barForeground : Color.foreground
      trackHeight: 5
      tickHeight: 3
      caretHeight: 4
      caretWidth: 7
      gap: 2
      opacity: root.hasData ? 1 : 0.45

      Behavior on opacity {
        NumberAnimation { duration: 140 }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: {
      if (root.bar && panelLoader.item) root.bar.showTooltip(root, panelLoader.item.barTooltip)
    }
    onExited: {
      if (root.bar) root.bar.hideTooltip(root)
    }
    onClicked: function(mouse) { root.triggerPress(mouse.button) }
  }
}
