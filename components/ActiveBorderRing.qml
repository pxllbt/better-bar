import QtQuick
import QtQuick.Shapes
import "../Singletons"
import "../Commons/BorderGeometry.js" as Geometry

/**
 * The theme's active-window border, drawn as a gradient edge.
 *
 * Omarchy themes name their active-window border as a stop list plus an angle
 * (`hyprland_active_border = "rgba(ff8800ff) ... 90deg"`), which the compositor
 * renders as a gradient rim. Rendered via Shape and a compound winding SVG
 * ring path so rounded corners trace the host's silhouette seamlessly instead
 * of leaving sharp corner spandrels.
 *
 * Renders nothing when the theme names fewer than two stops, and the host should
 * then fall back to its own flat border.
 */
Item {
    id: ring

    /** Rim thickness in px; 0 hides the rim entirely. */
    readonly property int ringWidth: ThemeColors.activeBorder.length > 1 ? 2 : 0
    readonly property var stops: ThemeColors.activeBorder
    readonly property real angle: ThemeColors.activeBorderAngle
    readonly property color topColor: stops.length > 0 ? stops[0] : "transparent"
    readonly property color bottomColor: stops.length > 1 ? stops[stops.length - 1] : topColor

    /**
     * Corner radius of the shape being outlined. Bound by the host to the same
     * value it gives its own Rectangle, so the rim follows it exactly.
     */
    property real radius: 0
    property real topLeftRadius: radius
    property real topRightRadius: radius
    property real bottomLeftRadius: radius
    property real bottomRightRadius: radius

    /** Cap the radius at half the shortest side, as a rounded rect does. */
    readonly property real effRadius: Math.max(0, Math.min(radius, Math.min(width, height) / 2))

    readonly property var _radii: ({
        topLeft: ring.topLeftRadius,
        topRight: ring.topRightRadius,
        bottomLeft: ring.bottomLeftRadius,
        bottomRight: ring.bottomRightRadius
    })
    readonly property var _widths: Geometry.parseWidthSpec(ring.ringWidth, 0)
    readonly property var _endpoints: Geometry.gradientEndpoints(width, height, ring.angle || 0)
    readonly property string _path: ring.ringWidth > 0 && width > 0 && height > 0
        ? Geometry.ringPath(width, height, ring._radii, ring._widths)
        : ""

    visible: ring.ringWidth > 0 && width > 0 && height > 0

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: ring.visible

        ShapePath {
            fillRule: ShapePath.WindingFill
            strokeWidth: 0
            fillGradient: LinearGradient {
                x1: ring._endpoints.x1
                y1: ring._endpoints.y1
                x2: ring._endpoints.x2
                y2: ring._endpoints.y2

                GradientStop { position: Geometry.stopPosition(ring.stops, 0); color: Geometry.stopColor(ring.stops, 0) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 1); color: Geometry.stopColor(ring.stops, 1) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 2); color: Geometry.stopColor(ring.stops, 2) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 3); color: Geometry.stopColor(ring.stops, 3) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 4); color: Geometry.stopColor(ring.stops, 4) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 5); color: Geometry.stopColor(ring.stops, 5) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 6); color: Geometry.stopColor(ring.stops, 6) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 7); color: Geometry.stopColor(ring.stops, 7) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 8); color: Geometry.stopColor(ring.stops, 8) }
                GradientStop { position: Geometry.stopPosition(ring.stops, 9); color: Geometry.stopColor(ring.stops, 9) }
            }

            PathSvg { path: ring._path }
        }
    }
}
