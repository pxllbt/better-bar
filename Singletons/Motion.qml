pragma Singleton
import QtQuick
import Quickshell

Singleton {
    readonly property real mult: Flags.reduceMotion ? 0.35 : 0.85
    readonly property int fast:     Math.round(120 * mult)
    readonly property int standard: Math.round(240 * mult)
    readonly property int morph:    Math.round(320 * mult)
    readonly property int shapeshift: Math.round(480 * mult)
    readonly property int glide:    Math.round(180 * mult)
    readonly property int heat:     Math.round(900 * mult)
    readonly property int easeStandard: Easing.OutCubic
    readonly property int easeMorph:    Easing.OutCubic

    /**
     * Smooth, responsive morph curve: Fast initial travel with an ultra-clean settle.
     */
    readonly property var morphCurve: [0.16, 1, 0.3, 1, 1, 1]
    readonly property real rSmall: 7
    readonly property real rTile:  13

    /** Looping scan/pairing breath pulse. */
    readonly property int pulse: Math.round(360 * mult)
}
