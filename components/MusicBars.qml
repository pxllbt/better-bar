pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * Centered liquid soundwave capsule. Floating rounded bars expand symmetrically
 * from the vertical center line with zero animation engine overhead (Cava's internal
 * smoothing handles liquid motion directly, bypassing CPU-heavy NumberAnimation loops).
 */
Item {
    id: root

    property real s: 1
    property real span: 14

    implicitWidth: waveRow.implicitWidth
    implicitHeight: span * s
    width: implicitWidth
    height: implicitHeight

    Row {
        id: waveRow
        anchors.centerIn: parent
        spacing: 1.5 * root.s
        height: root.height

        Repeater {
            model: Cava.bars

            Rectangle {
                id: bar
                required property int index

                anchors.verticalCenter: parent.verticalCenter
                width: (index === 2 ? 2.2 : 1.8) * root.s
                radius: width / 2

                readonly property real weight: index === 2 ? 1.05 : (index === 1 || index === 3 ? 0.95 : 0.85)
                readonly property real level: (Cava.levels[index] || 0) * weight

                height: Math.max(2.5 * root.s, Math.min(root.span * root.s, level * root.span * root.s))

                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.vermLit }
                    GradientStop { position: 0.5; color: Theme.accent }
                    GradientStop { position: 1.0; color: Theme.vermLit }
                }

                opacity: Cava.active ? Math.max(0.45, Math.min(1.0, 0.4 + level * 0.8)) : 0.3
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
