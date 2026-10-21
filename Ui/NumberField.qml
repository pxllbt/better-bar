import QtQuick
import QtQuick.Controls as QQC
import qs.Commons

/**
 * A numeric field.
 *
 * WHY THE FIELD IS `readOnly` AND NOT EDITABLE, which looks like a bug and is
 * not:
 *
 * Every `QQuickTextInput` connects to the clipboard in its constructor, and
 * `q_canPasteChanged()` then calls `mimeData()->hasText()` -- on Wayland an
 * unbounded, deadline-free transfer of whatever another client offered. The
 * read is gated on `!m_readOnly`, so an editable native field reopens that
 * path for exactly as long as it is editable, and a foreign clipboard producer
 * can stall or exhaust the process every surface of the bar shares.
 *
 * `maximumLength` does not close it: that bounds what is STORED, not the
 * transfer.
 *
 * The bar's rule, everywhere else, is `readOnly: true` plus editing driven
 * from `Singletons/TextEntry.qml`. This component was the one place that rule
 * was broken -- its field was editable whenever the spinbox was editable.
 *
 * It is currently unused, so this change breaks nothing. Anyone reviving it
 * must drive the editing through `TextEntry` rather than by making the field
 * editable again.
 */
Column {
  id: root

  property string label: ""
  property int value: 0
  property int from: 0
  property int to: 100
  property int stepSize: 1
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property real fieldWidth: Style.spacing.numberFieldWidth
  property bool hasCursor: false
  property bool _hovered: false
  property alias field: spin

  signal modified(int value)
  signal hovered(bool on)

  spacing: Style.spacing.md

  Text {
    textFormat: Text.PlainText
    visible: root.label !== ""
    text: root.label
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  QQC.SpinBox {
    id: spin
    width: root.fieldWidth
    implicitHeight: Math.max(Style.spacing.controlHeight, root.fontSize + Style.spacing.controlPaddingY * 2)
    from: root.from
    to: root.to
    stepSize: root.stepSize
    value: root.value
    editable: true
    font.family: root.fontFamily
    font.pixelSize: root.fontSize

    readonly property bool _focused: spin.activeFocus
    readonly property bool _hot: root._hovered || root.hasCursor
    readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

    leftPadding: Border.left(_borderSpec) + Style.spacing.controlPaddingX
    rightPadding: Border.right(_borderSpec) + Style.spacing.controlPaddingX
    topPadding: Border.top(_borderSpec)
    bottomPadding: Border.bottom(_borderSpec)

    onValueModified: root.modified(value)

    background: BorderSurface {
      color: Style.controlFill(spin._focused, spin._hot, root.foreground, root.accent)
      borderSpec: spin._borderSpec
      radius: Style.cornerRadius

      HoverHandler {
        onHoveredChanged: {
          root._hovered = hovered
          root.hovered(hovered)
        }
      }
    }

    contentItem: TextInput {
      text: spin.displayText
      font: spin.font
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      horizontalAlignment: Qt.AlignHCenter
      verticalAlignment: Qt.AlignVCenter
      readOnly: true
      validator: spin.validator
      inputMethodHints: Qt.ImhFormattedNumbersOnly
    }
  }
}
