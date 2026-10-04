pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * Mini-segmented choice control. `options` is a list of `{ label, value }`; the
 * pill whose value equals `value` lights with a flame tint. Picking a pill emits
 * `picked(value)`; selection keys off the source value, never a child's effective
 * visibility. The host passes `s` for scale.
 *
 * `pal` is the host's SettingsPalette; a null one means the pill's own tokens,
 * which is every pill surface. The dock's settings panel passes the dock's
 * palette so its segments are the dock's colours and not the pill's.
 */
Rectangle {
    id: seg

    property real s: 1
    property var options: []
    property var value
    property var pal: null
    signal picked(var value)

    readonly property color glow: seg.pal ? seg.pal.accent : Theme.onGlow
    readonly property color tile: seg.pal ? seg.pal.tile : Theme.frameBg
    readonly property color ink: seg.pal ? seg.pal.ink : Theme.cream
    readonly property color subInk: seg.pal ? seg.pal.sub : Theme.subtle

    readonly property real pad: 1

    width: pills.implicitWidth + 2 * pad
    height: pills.implicitHeight + 2 * pad
    radius: 9 * seg.s
    color: "transparent"

    Row {
        id: pills
        anchors.centerIn: parent
        spacing: 2 * seg.s

        Repeater {
            model: seg.options

            Rectangle {
                id: opt
                required property var modelData
                readonly property bool current: seg.value === modelData.value
                property bool hovered: false

                width: optLabel.implicitWidth + 10 * seg.s
                height: optLabel.implicitHeight + 10 * seg.s
                radius: 8 * seg.s
                color: opt.current ? Qt.alpha(seg.glow, 0.16) : (opt.hovered ? seg.tile : "transparent")
                Behavior on color { ColorAnimation { duration: Motion.fast } }

                Text {
                    id: optLabel
                    anchors.centerIn: parent
                    text: opt.modelData.label
                    color: opt.current ? seg.ink : seg.subInk
                    font.family: Theme.font
                    font.pixelSize: 10 * seg.s
                    font.weight: Font.Bold
                    font.letterSpacing: 0.2 * seg.s
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: opt.hovered = true
                    onExited: opt.hovered = false
                    onClicked: seg.picked(opt.modelData.value)
                }
            }
        }
    }
}
