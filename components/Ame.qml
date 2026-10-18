pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * 飴 Ame: GPU-accelerated soul bead & glowing accent indicator.
 *
 * Replaced the legacy CPU-bound 2D software Canvas with pure hardware-accelerated
 * declarative Scene Graph primitives (layered rounded rectangles).
 *
 * Characteristics:
 *   - 0.0% idle CPU: No software rasterization, no Canvas.requestPaint(), no continuous timers.
 *   - 144Hz/165Hz butter-smooth GPU transitions using Motion.glide and Motion.fast easing.
 *   - Reactive to the active theme accent (Theme.accent / Theme.onGlow).
 *   - Completely dormant when hidden (form === "off").
 */
Item {
    id: root

    property real s: 1
    property point point: Qt.point(0, 0)
    property string form: "off"
    property real heat: 0
    property point wake: Qt.point(0, 0)
    property real wickDir: -1

    readonly property bool isOff: form === "off" || form === "" || form === "rest"
    opacity: isOff ? 0 : 1
    visible: opacity > 0.001

    Behavior on opacity {
        NumberAnimation {
            duration: Motion.fast
            easing.type: Easing.OutCubic
        }
    }

    // Target tracking coordinates
    readonly property real targetX: root.point.x
    readonly property real targetY: root.point.y

    // Smooth GPU-accelerated follower bead
    Item {
        id: bead
        x: root.targetX - width / 2
        y: root.targetY - height / 2
        width: 22 * root.s
        height: 22 * root.s
        scale: root.isOff ? 0.3 : (1.0 + root.heat * 0.35)

        Behavior on x {
            enabled: !root.isOff
            NumberAnimation {
                duration: Motion.glide
                easing.type: Easing.OutCubic
            }
        }

        Behavior on y {
            enabled: !root.isOff
            NumberAnimation {
                duration: Motion.glide
                easing.type: Easing.OutCubic
            }
        }

        Behavior on scale {
            NumberAnimation {
                duration: Motion.fast
                easing.type: Easing.OutCubic
            }
        }

        // Layer 1: Soft ambient glow halo
        Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: parent.height
            radius: width / 2
            antialiasing: true
            color: Qt.alpha(Theme.accent, 0.22)
            opacity: root.heat > 0 ? 0.8 : 0.55
        }

        // Layer 2: Mid glow ring
        Rectangle {
            anchors.centerIn: parent
            width: 13 * root.s
            height: 13 * root.s
            radius: width / 2
            antialiasing: true
            color: Qt.alpha(Theme.accent, 0.45)
        }

        // Layer 3: Vibrant core bead
        Rectangle {
            anchors.centerIn: parent
            width: 7 * root.s
            height: 7 * root.s
            radius: width / 2
            antialiasing: true
            color: Theme.accent

            // Specular micro glint
            Rectangle {
                x: 1 * root.s
                y: 1 * root.s
                width: 2.2 * root.s
                height: 2.2 * root.s
                radius: width / 2
                antialiasing: true
                color: "#ffffff"
                opacity: 0.8
            }
        }
    }
}
