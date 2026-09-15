pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons

// Thermometer-style quota bar. One reusable visual, two scales:
//   - mercury fill  (ratio)  = share of the quota already spent
//   - floating caret (pointer) = share of the window's time already spent
// Fixed ruler ticks sit below the track (tall at 0/25/50/75/100%, short at
// the eighths between), so the two moving marks always read against a scale.
Item {
  id: root

  // 0..1 quota usage share. Clamped when painted.
  property real ratio: 0
  // 0..1 time-through-window share for the floating caret. Negative hides it.
  property real pointer: -1
  // Foreground for track, ticks and caret — the caller picks the contrast
  // reference (bar foreground on the bar, popup text inside the panel).
  property color fg: Color.foreground
  // Auto mercury ramp follows the theme (accent → warm → hot as usage
  // climbs); manualFill replaces it when autoColor is false.
  property bool autoColor: true
  property color manualFill: Color.accent
  property real trackHeight: 6
  property real tickHeight: 4
  property real caretHeight: 5
  property real caretWidth: 8
  // Gaps between caret / track / ruler. Kept proportional so the panel can
  // ask for a bigger bar by only raising the three heights.
  property real gap: 2

  function alphaOf(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function lerpColor(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }
  function clamp01(v) { return v < 0 ? 0 : (v > 1 ? 1 : v) }

  // Mercury color: theme accent up to 75% of the quota, easing to a warm
  // tone by 90% and to urgent red past that. Warmth hues are fixed; the
  // lightness tracks the foreground so it reads on light and dark themes.
  readonly property real warmLightness: Math.max(0.38, Math.min(0.68, fg.hslLightness))
  readonly property color mercury: {
    if (!autoColor) return manualFill
    var base = Color.accent
    var warm = Qt.hsla(0.10, 0.75, warmLightness, 1)
    var hot = Qt.hsla(0.02, 0.78, warmLightness, 1)
    var r = clamp01(ratio)
    if (r <= 0.75) return base
    if (r <= 0.90) return lerpColor(base, warm, (r - 0.75) / 0.15)
    return lerpColor(warm, hot, Math.min(1, (r - 0.90) / 0.08))
  }

  readonly property real caretRowHeight: caretHeight + gap
  readonly property real rulerTop: caretRowHeight + trackHeight + gap
  implicitHeight: rulerTop + tickHeight

  // ---- floating time caret -------------------------------------------------
  // Solid triangle over a hairline that reaches down to the ruler, marking
  // where "now" sits inside the window. Distinct from the mercury by shape:
  // it never fills, it points.
  Item {
    id: caret
    visible: root.pointer >= 0
    x: Math.round(Math.max(0, Math.min(1, root.pointer)) * root.width) - width / 2
    y: 0
    width: root.caretWidth
    height: root.rulerTop

    Canvas {
      id: caretTriangle
      anchors.top: parent.top
      width: root.caretWidth
      height: root.caretHeight
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.fillStyle = root.fg
        ctx.beginPath()
        ctx.moveTo(0, 0)
        ctx.lineTo(width, 0)
        ctx.lineTo(width / 2, height)
        ctx.closePath()
        ctx.fill()
      }
      Connections {
        target: root
        function onFgChanged() { caretTriangle.requestPaint() }
      }
    }

    Rectangle {
      anchors.top: parent.top
      anchors.topMargin: root.caretHeight
      anchors.horizontalCenter: parent.horizontalCenter
      width: 1
      height: root.rulerTop - root.caretHeight
      color: root.alphaOf(root.fg, 0.7)
    }
  }

  // ---- track + mercury ------------------------------------------------------
  Rectangle {
    id: track
    y: root.caretRowHeight
    width: parent.width
    height: root.trackHeight
    radius: root.trackHeight / 2
    color: root.alphaOf(root.fg, 0.14)
    border.width: 1
    border.color: root.alphaOf(root.fg, 0.28)

    Rectangle {
      id: mercury
      readonly property real fillWidth: root.clamp01(root.ratio) * (track.width - 2)
      x: 1
      y: 1
      width: fillWidth
      height: parent.height - 2
      radius: Math.min(height / 2, width / 2)
      color: root.mercury

      Behavior on width {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
      }
    }
  }

  // ---- ruler ticks ------------------------------------------------------------
  // Nine ticks at eighths; the even ones (quarters, including both ends) are
  // taller. End ticks are inset by half a line so they stay inside the track.
  Repeater {
    model: 9

    Rectangle {
      required property int index
      readonly property real frac: index / 8
      readonly property bool major: index % 2 === 0
      x: Math.round(frac * (root.width - 1))
      y: root.rulerTop + (major ? 0 : Math.max(1, root.tickHeight * 0.4))
      width: 1
      height: major ? root.tickHeight : Math.max(1, root.tickHeight * 0.6)
      color: root.alphaOf(root.fg, major ? 0.55 : 0.28)
    }
  }
}
