import QtQuick
import "../Singletons"

/**
 * 飭 MediaDisc: the pill-sized media metaphor — a compact CD that rotates.
 *
 * The media surface already has the full-sized record; this is the same visual
 * contract scaled down into the pill so the two never drift apart. It is a few
 * rectangles and one rotation, not another canvas: the disc reads as media
 * without a second 60fps painting path inside the bar.
 *
 * Rotation is always tied to a live reason — the pointer hovering the bud, or an
 * actual playing player — so an idle pill does not spin a CD forever.
 */
Item {
    id: root

    property real s: 1
    property bool spinning: false

    readonly property real spinSeconds: 6.0

    Item {
        id: disc
        anchors.centerIn: parent
        width: root.width
        height: root.height

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            // The theme's own surface, not a fixed near-black: the disc has to
            // read as an object sitting *on* the bar, so on a light theme it is
            // a light disc and on Tokyo Night it is a dark one. A hardcoded grey
            // made the bud the one element in the pill that ignored the palette.
            color: Theme.tileBg
        }

        // Outer rim: enough contrast for the disc to survive over a busy pill.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1, 1 * root.s)
            border.color: Qt.alpha(Theme.cream, 0.28)
        }

        // Grooves. Two declarative rings, not a canvas of concentric strokes:
        // the visual is the same at 18px and the cost is two rounded rectangles.
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.78
            height: parent.width * 0.78
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1, 1 * root.s)
            border.color: Qt.alpha(Theme.cream, 0.10)
        }

        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.56
            height: parent.width * 0.56
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1, 1 * root.s)
            border.color: Qt.alpha(Theme.cream, 0.07)
        }

        // Spindle hub, in the media surface's idiom: dark centre with a light
        // ring, so it reads as a hole rather than a flat dot. Derived from the
        // theme's own surface so it recedes on light themes and deepens on dark
        // ones, instead of a fixed black that goes flat on a light bar.
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.26
            height: parent.width * 0.26
            radius: width / 2
            color: Qt.darker(Theme.tileBg, 1.7)
            border.width: Math.max(1, 1 * root.s)
            border.color: Qt.alpha(Theme.cream, 0.25)
        }
    }

    RotationAnimation {
        target: disc
        property: "rotation"
        from: 0
        to: 360
        duration: Math.round(root.spinSeconds * 1000)
        loops: Animation.Infinite
        alwaysRunToEnd: false
        running: root.spinning
    }
}
