pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * Rest-pill spectrum: one rounded ember bar per cava band, packed into the
 * clock-glyph slot so the cluster never widens the pill. Heights chase
 * Cava.levels with a short ease so the motion stays liquid instead of strobing
 * on every frame cava emits.
 *
 * Two styles live here, picked by `Flags.musicStyle`:
 *  - "bars": the original ember bars
 *  - "wave": one smooth amplitude wave drawn on a canvas, the same slot but a
 *    different silhouette — try it from Appearance > Display > Visualizer style.
 */
Item {
    id: root

    property real s: 1
    property real span: 18
    property string style: Flags.musicStyle
    readonly property real barW: 1.8 * s
    readonly property real barGap: 1.2 * s

    // Explicit width so the wave canvas has a real size even while the bars
    // Repaper is hidden (a Row with no sized children would leave it at 0).
    width: Math.max(1, Cava.bars) * barW + Math.max(0, Math.max(0, Cava.bars - 1)) * barGap
    height: span * s

    // Bars style
    Row {
        id: barRow
        anchors.fill: parent
        visible: root.style !== "wave"
        spacing: root.barGap
        Repeater {
            model: Cava.bars

            Rectangle {
                required property int index

                width: root.barW
                height: Math.max(3 * root.s, (Cava.levels[index] || 0) * root.span * root.s)
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.omarchyAccent || Theme.accent }
                    GradientStop { position: 0.5; color: Theme.vermLit }
                    GradientStop { position: 1.0; color: Theme.omarchyAccent || Theme.accent }
                }

                Behavior on height {
                    enabled: root.visible
                    NumberAnimation { duration: Motion.fast; easing.type: Easing.OutQuad }
                }
            }
        }
    }

    /* Wavefront style: a single cardinal-spline pass through the band peaks,
     * filled with the same accent/vermilion gradient as the bars. It repaints on
     * every cava frame, on first show and on style change. */
    Canvas {
        id: wave
        anchors.fill: parent
        visible: root.style === "wave"
        onPaint: {
            const ctx = getContext("2d");
            const w = width, h = height;
            ctx.clearRect(0, 0, w, h);
            const n = Cava.bars;
            if (n < 2)
                return;
            const step = w / (n - 1);
            let prev = null;
            ctx.beginPath();
            ctx.moveTo(0, h);
            for (let i = 0; i < n; i++) {
                const pt = { x: i * step, y: h - (Cava.levels[i] || 0) * h };
                if (i === 0)
                    ctx.lineTo(pt.x, pt.y);
                else
                    ctx.quadraticCurveTo(prev.x, prev.y, (prev.x + pt.x) / 2, (prev.y + pt.y) / 2);
                prev = pt;
            }
            ctx.lineTo(w, h);
            ctx.closePath();
            const g = ctx.createLinearGradient(0, 0, 0, h);
            g.addColorStop(0.0, Theme.accent);
            g.addColorStop(1.0, Theme.vermLit);
            ctx.fillStyle = g;
            ctx.fill();
        }

        Component.onCompleted: if (wave.visible) wave.requestPaint()
        onVisibleChanged: if (wave.visible) wave.requestPaint()
        Connections {
            target: Cava
            function onLevelsChanged() { if (wave.visible) wave.requestPaint(); }
        }
        Connections {
            target: root
            function onStyleChanged() { wave.requestPaint(); }
        }
    }
}
