import QtQuick
import "../Singletons"

/**
 * The theme's active-window border, drawn as a gradient edge.
 *
 * Omarchy themes name their active-window border as a stop list plus an angle
 * (`hyprland_active_border = "rgba(ff8800ff) ... 90deg"`), which the compositor
 * renders as a gradient rim. A QML Rectangle border is a flat colour, so the
 * edge is built from four strips — solid across the top and bottom, gradient
 * down the two sides.
 *
 * Renders nothing when the theme names fewer than two stops, and the host should
 * then fall back to its own flat border.
 */
Item {
    id: ring

    /** Rim thickness in px; 0 hides the rim entirely. */
    readonly property int ringWidth: ThemeColors.activeBorder.length > 1 ? 2 : 0
    readonly property var stops: ThemeColors.activeBorder
    readonly property color topColor: stops.length > 0 ? stops[0] : "transparent"
    readonly property color bottomColor: stops.length > 1 ? stops[stops.length - 1] : topColor

    /**
     * Corner radius of the shape being outlined. Bound by the host to the same
     * value it gives its own Rectangle, so the rim follows it exactly.
     */
    property real radius: 0

    /** Cap the radius at half the shortest side, as a rounded rect does. */
    readonly property real effRadius: Math.max(0, Math.min(radius, Math.min(width, height) / 2))

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: ring.ringWidth
        visible: ring.ringWidth > 0
        color: ring.topColor
        topLeftRadius: ring.effRadius
        topRightRadius: ring.effRadius
        bottomLeftRadius: 0
        bottomRightRadius: 0
        antialiasing: true
    }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: ring.ringWidth
        visible: ring.ringWidth > 0
        color: ring.bottomColor
        bottomLeftRadius: ring.effRadius
        bottomRightRadius: ring.effRadius
        topLeftRadius: 0
        topRightRadius: 0
        antialiasing: true
    }

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: ring.ringWidth
        visible: ring.ringWidth > 0
        gradient: Gradient {
            GradientStop { position: 0.0; color: ring.topColor }
            GradientStop { position: 1.0; color: ring.bottomColor }
        }
        topLeftRadius: ring.effRadius
        bottomLeftRadius: ring.effRadius
        topRightRadius: 0
        bottomRightRadius: 0
        antialiasing: true
    }

    Rectangle {
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: ring.ringWidth
        visible: ring.ringWidth > 0
        gradient: Gradient {
            GradientStop { position: 0.0; color: ring.topColor }
            GradientStop { position: 1.0; color: ring.bottomColor }
        }
        topRightRadius: ring.effRadius
        bottomRightRadius: ring.effRadius
        topLeftRadius: 0
        bottomLeftRadius: 0
        antialiasing: true
    }
}
