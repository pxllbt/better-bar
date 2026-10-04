pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "../Singletons"
import "../components"

/**
 * Standalone OSD overlay, fully decoupled from the pill. The pill never morphs
 * for volume/brightness/workspace flashes anymore; this capsule shows itself at
 * its final size, grows in from the screen top like a notch, holds for the
 * flash timeout, then shrinks away. Content stays at fixed geometry the whole
 * time, so the level bars never stretch with the transition.
 */
Item {
    id: popup

    property real s: 1
    property string screenName: ""
    property bool suppressed: false
    property bool expanded: false

    /**
     * 1 when the popup should dock flush to the screen top like the strip bar
     * (squared top corners); 0 for the rounded island capsule. Mirrors the
     * pill's own top-flat rule so the OSD keeps each display mode's silhouette.
     */
    property real topFlat: 0
    Behavior on topFlat { NumberAnimation { duration: Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }

    readonly property bool active: osd.flashing

    width: osd.desiredW
    height: osd.desiredH
    Behavior on width { NumberAnimation { duration: Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }
    Behavior on height { NumberAnimation { duration: Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }

    opacity: active ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: active ? Motion.fast : 220; easing.type: Easing.OutCubic } }

    transformOrigin: Item.Top
    scale: active ? 1 : 0.68
    Behavior on scale {
        NumberAnimation {
            duration: active ? Motion.standard : Motion.fast
            easing.type: active ? Easing.OutCubic : Easing.InCubic
        }
    }

    /**
     * The translucent capsule: the same material as the pill, with a small
     * veil so percentage and title copy keep contrast while flashing.
     */
    LiquidGlass {
        id: glass
        anchors.fill: parent
        radius: 22 * s
        topLeftRadius: 22 * s * (1 - topFlat)
        topRightRadius: 22 * s * (1 - topFlat)
        style: "regular"
        legacyOpacity: Flags.pillOpacity
        accent: 0.08
        veil: 0.10
        // Sit on the theme background exactly as the pill does, so the flash
        // that appears when you switch workspace reads as part of the same bar
        // rather than a separate capsule in a different colour.
        themeBackgroundFill: true
        sheenScale: 1.1
        borderColor: Theme.border
        /**
         * Shadow only while the capsule is actually on screen. This was
         * unconditionally `true`, which kept a live shadow FBO alive per monitor
         * for a popup that is `opacity: 0` and `visible: false` the entire time
         * between flashes — an offscreen render of the whole glass body that
         * nothing can see. Pill.qml already gates its equivalent layer on
         * visibility; this is the same rule applied here.
         */
        layer.enabled: glass.visible && glass.opacity > 0.01
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, Theme.shadowOpacity)
            shadowBlur: 0.7
            shadowVerticalOffset: 3 * s
        }
    }

    Osd {
        id: osd
        anchors.fill: parent
        anchors.topMargin: 12 * s
        anchors.leftMargin: 18 * s
        anchors.rightMargin: 18 * s
        anchors.bottomMargin: 12 * s
        s: popup.s
        screenName: popup.screenName
        suppressed: popup.suppressed
        expanded: popup.expanded
    }
}
