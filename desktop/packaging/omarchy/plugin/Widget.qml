// Monet Shot in the Omarchy bar (omarchy-shell, Omarchy 4). Follows
// `monet-shot status --waybar --follow` (one JSON line per change: text,
// tooltip, class) and drives the app: click records or stops, right-click
// pauses. Shaped like Omarchy's own ScreenRecording indicator.
import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "monet-shot"

  // idle | picking | countdown | recording | paused | saving | problem | off
  property string phase: "off"
  property string label: ""
  property string tip: "Monet Shot"

  // The icon alone sits in the bar's icon slot (BarIconButton is fixed to
  // it); with the 3-2-1 digit or the time beside it, a text button sized to
  // its label, as Omarchy's keyboard-layout widget does.
  readonly property bool withLabel: root.label !== ""
  readonly property string glyph: root.phase === "paused" ? "󰏤" : "󰑊"
  readonly property bool lit: root.phase === "recording" || root.phase === "countdown" || root.phase === "paused"
  implicitWidth: withLabel ? labelButton.implicitWidth : button.implicitWidth
  implicitHeight: withLabel ? labelButton.implicitHeight : button.implicitHeight

  function press(b) {
    if (!root.bar) return
    root.bar.run(b === Qt.RightButton ? "monet-shot pause" : "monet-shot toggle")
  }

  Process {
    id: follow
    command: ["monet-shot", "status", "--waybar", "--follow"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var s = JSON.parse(line)
          root.phase = s["class"] || "off"
          root.label = s.text || ""
          root.tip = s.tooltip || "Monet Shot"
        } catch (e) {}
      }
    }
    // Monet Shot updated or not installed for a moment: try again shortly.
    onExited: retry.start()
  }

  Timer { id: retry; interval: 5000; onTriggered: follow.running = true }

  BarIconButton {
    id: button
    visible: !root.withLabel
    anchors.fill: parent
    bar: root.bar
    // nf-md-record_rec, nf-md-pause
    text: root.glyph
    active: root.lit
    tooltipText: root.tip
    onPressed: function(b) { root.press(b) }
  }

  WidgetButton {
    id: labelButton
    visible: root.withLabel
    anchors.fill: parent
    bar: root.bar
    text: root.glyph + " " + root.label
    active: root.lit
    tooltipText: root.tip
    onPressed: function(b) { root.press(b) }
  }
}
