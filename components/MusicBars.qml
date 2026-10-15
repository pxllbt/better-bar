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
 *    different silhouette — try it from Appearance > Visualizer style.
 */
Row {
    id: root

    property real s: 1
    property real span: 18
    property string style: Flags.musicStyle

    height: span * s
    spacing: 1.2 * s

    Repeater {
        model: Cava.bars

        Rectangle {
            required property int index

            width: 1.8 * root.s
            radius: width / 2
            anchors.bottom: parent.bottom
            height: Math.max(2 * root.s, (Cava.levels[index] || 0) * root.span * root.s)

            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.accent }
                GradientStop { position: 1.0; color: Theme.vermLit }
            }

            visible: root.style !== "wave"

            Behavior on height {
                enabled: root.visible
                NumberAnimation { duration: Motion.fast; easing.type: Easing.OutQuad }
            }
        }
    }

    /* Wavefront style: a single cardinal-spline pass through the band peaks,
     * filled with the same accent/vermilion gradient as the bars. Canvas is
     * only repainted when cava hands us a new frame, so the renderer never
     * chases the 60Hz levels tick while audio is flat. */
    Canvas {
        id: wave
        anchors.fill: parent
        visible: root.style === "wave"
        z: 1

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