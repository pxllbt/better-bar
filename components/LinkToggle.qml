import QtQuick
import "../Singletons"

/**
 * Toggle switch: tile bg off, terracotta fill on, cream knob slides on the
 * fast motion token. Shared by the wifi, bluetooth and hotspot controls.
 *
 * `pal` is the host's SettingsPalette; null means the pill's own tokens, which
 * is every pill surface. The dock's settings panel passes the dock's palette, so
 * its switches are the dock's accent and the dock's knob colour.
 */
Rectangle {
    id: toggle

    property real s: 1
    property bool on: false
    property var pal: null
    signal toggled()

    readonly property color accent: toggle.pal ? toggle.pal.accent : Theme.verm
    readonly property color offTile: toggle.pal ? toggle.pal.edge : Theme.tileBg
    readonly property color knob: toggle.pal ? toggle.pal.accentInk : Theme.cream

    width: 28 * s
    height: 16 * s
    radius: 999
    color: on ? accent : offTile
    border.width: on ? 0 : 1
    border.color: toggle.pal ? toggle.pal.edge : Theme.border

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 10 * toggle.s
        height: 10 * toggle.s
        radius: width / 2
        color: toggle.knob
        x: toggle.on ? toggle.width - width - 3 * toggle.s : 3 * toggle.s
        Behavior on x { NumberAnimation { duration: Motion.fast } }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: toggle.toggled()
    }
}
