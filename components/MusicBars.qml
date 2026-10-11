pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * Breath-flame glyph: a single 1px-wide pulse that adapts to its container.
 *
 * Strip mode: a thin horizontal "breath" — width and opacity pulse to the
 * center-weighted spectrum band (Cava.levels[2]), rendered as a 1px capsule
 * that swells and fades. No NumberAnimation, no JS timer — Cava's own 30Hz
 * smoothing drives the binding directly.
 *
 * Expanded Media card: the same glyph re-roots as a vertical "flame" edge
 * on the right side of the album art. Its height is bound to the sum of
 * all five bands, normalized — a single bar that grows from the seam like
 * a pulse from the card itself.
 *
 * Full Media surface: the glyph stretches behind the title marquee as a
 * 2px spectral watermark. Each band maps to a pre-instantiated slice whose
 * height is a pure binding — the marquee becomes an equalizer.
 */
Item {
    id: root

    property real s: 1
    property real span: 14

    readonly property bool inStrip: pill && pill.stripMedia
    readonly property bool inCard: root.width <= 30 * root.s

    implicitWidth: inStrip ? (Cava.active ? 62 * root.s : 0) : 22 * root.s
    implicitHeight: inStrip ? 3 * root.s : span * root.s
    width: implicitWidth
    height: implicitHeight

    readonly property real centerLevel: Cava.levels.length > 2 ? (Cava.levels[2] || 0) : 0
    readonly property real summedLevel: {
        var sum = 0;
        for (var i = 0; i < Cava.bars && i < Cava.levels.length; i++) {
            var v = Cava.levels[i] || 0;
            sum += v * (i === 2 ? 1.2 : (i === 1 || i === 3 ? 1.0 : 0.8));
        }
        return Math.min(1, sum / 3.5);
    }

    Rectangle {
        id: breath
        anchors.centerIn: parent
        width: inStrip ? (8 + 54 * root.centerLevel) * root.s : 2 * root.s
        height: inStrip ? 1 * root.s : (inCard ? 2 * root.s : 14 * root.s)
        radius: inStrip ? height / 2 : 1 * root.s

        anchors.horizontalCenterOffset: 0

        readonly property real phase: root.inStrip ? root.centerLevel : root.summedLevel

        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.vermLit }
            GradientStop { position: 0.5; color: Theme.accent }
            GradientStop { position: 1.0; color: Theme.vermLit }
        }

        opacity: Cava.active ? Math.max(0.25, 0.4 + 0.6 * root.phase) : 0.1
        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
    }

    Rectangle {
        id: flame
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: inCard ? 2 * root.s : 0
        height: inCard ? (8 + 58 * root.summedLevel) * root.s : 0
        anchors.rightMargin: inCard ? -1 * root.s : 0
        anchors.topMargin: inCard ? -4 * root.s : 0
        radius: 1 * root.s
        clip: true

        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.verm }
            GradientStop { position: 0.5; color: Theme.accent }
            GradientStop { position: 1.0; color: Theme.vermLit }
        }
        opacity: inCard && Cava.active ? Math.max(0.4, root.summedLevel) : 0
    }

    Rectangle {
        id: watermark
        anchors.fill: parent
        anchors.margins: {
            if (!root.inStrip && !root.inCard)
                return 4 * root.s;
            return 0;
        }
        width: 0
        height: 0
        visible: false

        Repeater {
            model: Cava.bars
            Rectangle {
                id: slice
                required property int index
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                width: parent.width / Cava.bars
                height: (Cava.levels[index] || 0) * parent.height
                opacity: (Cava.levels[index] || 0) * 0.5
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.vermLit }
                    GradientStop { position: 1.0; color: Theme.accent }
                }
            }
        }
    }

    MouseArea {
        id: vizMouse
        anchors.fill: parent
        anchors.margins: -4 * root.s
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (Players.active && Players.active.canTogglePlaying)
                Players.active.togglePlaying();
        }
        onWheel: (wheel) => {
            if (Players.active && Players.active.volume !== undefined) {
                var delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                Players.active.volume = Math.max(0.0, Math.min(1.0, Players.active.volume + delta));
            }
        }
    }
}
