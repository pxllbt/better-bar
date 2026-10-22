import QtQuick
import QtQuick.Effects
import "../Singletons"

/**
 * MediaDisc: the rotating album-art disc.
 *
 * It is one object in two places: a compact CD in the pill's media bud, and
 * the hero of the now-playing card. One component, so the two can never
 * drift apart.
 *
 * The disc is built like the thing it pretends to be. The art is clipped to a
 * circle; the surface carries a dome of light and an inner shadow, so it
 * reads as a physical object rather than a picture of a circle; the rim
 * catches the light on one side and falls away on the other; the spindle hole
 * sits in the middle. With no artwork it falls back to a record — concentric
 * grooves and a label tinted with the theme's accent.
 *
 * The light is painted once into a canvas and afterwards only rotated, so a
 * spinning disc costs one transform and nothing else: no shader, no blur, no
 * per-frame repaint of anything around it.
 *
 * The motion is a platter. It winds up to speed when the music starts and
 * coasts to a stop when the music stops, and it resumes from the angle it was
 * left at instead of snapping back to zero. With reduced motion on, the disc
 * holds still, and the ring and the state still say what the music is doing.
 */
Item {
    id: root

    property real s: 1
    property bool spinning: false
    /** Album art URL; empty falls back to the groove-only vinyl disc. */
    property string coverUrl: ""
    /** Hover lift: the host binds its own pointer state to this. */
    property bool hovered: false

    /** Seconds for one turn at the steady speed. */
    readonly property real spinSeconds: 6.0
    /** Degrees per second at the steady speed. */
    readonly property real spinRate: 360 / Math.max(1, root.spinSeconds)
    /** How long the platter takes to wind up, and to coast back down. */
    readonly property int spinUpMs: 520
    readonly property int coastMs: 900
    /**
     * Motion is a preference, not a decoration. With reduced motion on the
     * disc holds still — and the ring, the art and the state all still say
     * what the music is doing.
     */
    readonly property bool motion: !Flags.reduceMotion
    readonly property bool turning: root.spinning && root.motion
    /** Fine detail only pays for itself on a disc big enough to show it. */
    readonly property bool fine: root.width >= 40
    /** The angle the loop resumes from, so a resume never snaps back. */
    property real spinFrom: 0

    /**
     * The rim carries the state: the theme's accent while the music plays or
     * the pointer is on the disc, a plain hairline the rest of the time.
     */
    readonly property color rimColor: root.hovered
        ? Qt.alpha(Theme.accent, 0.95)
        : (root.spinning ? Qt.alpha(Theme.accent, 0.55) : Qt.alpha(Theme.cream, 0.28))

    readonly property color light: "#ffffff"

    /**
     * The specular highlight.
     *
     * Light is light: a highlight is the colour of the light, not the colour
     * of the theme's text, so it has to stay bright on a light palette. A
     * little of the accent is mixed in so the glint still belongs to the
     * theme.
     */
    readonly property color sheenColor: root.mix(root.light, Theme.accent, 0.25)

    /**
     * Everything the finish is painted with, in one string, so a theme change
     * can ask for a repaint without the canvas having to know what it
     * depends on.
     */
    readonly property string themeStamp: Theme.mode + "|" + Theme.cream + "|"
        + Theme.accent + "|" + Theme.tileBg + "|" + root.sheenColor

    /** Mix two colours in the engine's own colour space. */
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }

    /**
     * A CSS colour for the canvas.
     *
     * The canvas wants `rgba(r,g,b,a)` in 0-255 channels, while a QML colour
     * prints as `#rrggbb` when it is opaque and `#aarrggbb` when it is not —
     * so the alpha comes out of the string rather than off the colour's own
     * channels, which keeps this right on either scale.
     */
    function css(c, a) {
        var s = String(c);
        if (s.charAt(0) === "#")
            s = s.slice(1);
        var alpha = 1;
        if (s.length === 8) {
            alpha = parseInt(s.slice(0, 2), 16) / 255;
            s = s.slice(2);
        }
        return "rgba(" + parseInt(s.slice(0, 2), 16) + "," + parseInt(s.slice(2, 4), 16)
            + "," + parseInt(s.slice(4, 6), 16) + "," + (alpha * a) + ")";
    }

    /**
     * The drop shadow, under the disc and outside it: the disc sits above the
     * card rather than printed on it. It stays still while the disc turns — a
     * shadow that orbited the disc would read as a mistake.
     */
    Canvas {
        id: shadow
        width: parent.width * 1.26
        height: parent.height * 1.26
        anchors.centerIn: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d");
            const w = width, h = height;
            ctx.clearRect(0, 0, w, h);
            if (!root.fine || w <= 0 || h <= 0)
                return;
            const r = Math.min(w, h) / 2;
            const cx = w / 2;
            const cy = h / 2 + Math.max(1, 1.5 * root.s);
            const g = ctx.createRadialGradient(cx, cy, r * 0.6, cx, cy, r);
            g.addColorStop(0.0, "rgba(0,0,0,0.40)");
            g.addColorStop(0.45, "rgba(0,0,0,0.26)");
            g.addColorStop(0.78, "rgba(0,0,0,0.08)");
            g.addColorStop(1.0, "rgba(0,0,0,0)");
            ctx.fillStyle = g;
            ctx.fillRect(0, 0, w, h);
        }
    }

    Item {
        id: disc
        anchors.centerIn: parent
        width: root.width
        height: root.height

        // The disc body: the theme's own surface, so light themes get a light
        // disc and dark themes a dark one.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.tileBg
        }

        // The record: concentric grooves and a label, painted under the art so
        // a slow decode shows a record rather than an empty circle.
        Item {
            id: grooves
            anchors.fill: parent
            visible: art.status !== Image.Ready

            // The label: the coloured centre of a record, tinted with the
            // theme's accent so the empty disc still belongs to the palette.
            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.46
                height: parent.width * 0.46
                radius: width / 2
                color: Qt.alpha(Theme.accent, 0.14)
                border.width: Math.max(1, 1 * root.s)
                border.color: Qt.alpha(Theme.accent, 0.24)
                visible: root.fine
            }

            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.62
                height: parent.width * 0.62
                radius: width / 2
                color: "transparent"
                border.width: Math.max(1, 1 * root.s)
                border.color: Qt.alpha(Theme.cream, 0.10)
            }

            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.76
                height: parent.width * 0.76
                radius: width / 2
                color: "transparent"
                border.width: Math.max(1, 1 * root.s)
                border.color: Qt.alpha(Theme.cream, 0.08)
            }

            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.90
                height: parent.width * 0.90
                radius: width / 2
                color: "transparent"
                border.width: Math.max(1, 1 * root.s)
                border.color: Qt.alpha(Theme.cream, 0.06)
            }
        }

        // The album art, clipped to a circle by the mask effect below. A
        // plain `clip` cannot do it: Qt Quick clips to the bounding rectangle,
        // so a rounded rectangle clips square.
        Item {
            id: artWrap
            anchors.fill: parent
            visible: root.coverUrl.length > 0
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: discMask
            }

            Image {
                id: art
                anchors.fill: parent
                source: root.coverUrl
                sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                mipmap: true
                cache: String(source).indexOf("file:") !== 0
                visible: status === Image.Ready || status === Image.Loading
            }
        }

        // The circular mask the art is cut to.
        Rectangle {
            id: discMask
            anchors.fill: parent
            radius: width / 2
            color: "black"
            visible: false
            layer.enabled: true
        }

        // The light on the disc: a dome from the upper left, an inner shadow
        // at the rim, a specular sweep across the surface, and the edge itself
        // lit on one side and in shadow on the other.
        Canvas {
            id: finish
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative
            onPaint: {
                const ctx = getContext("2d");
                const w = width, h = height;
                ctx.clearRect(0, 0, w, h);
                if (w <= 0 || h <= 0)
                    return;
                const r = Math.min(w, h) / 2;
                const cx = w / 2, cy = h / 2;

                ctx.save();
                ctx.beginPath();
                ctx.arc(cx, cy, r - 0.5, 0, Math.PI * 2);
                ctx.clip();

                // The dome: light falls from the upper left, so the disc is
                // brightest a little above and left of its centre.
                const dome = ctx.createRadialGradient(cx - r * 0.20, cy - r * 0.24, r * 0.04,
                        cx - r * 0.20, cy - r * 0.24, r * 0.98);
                dome.addColorStop(0.0, root.css(root.sheenColor, 0.11));
                dome.addColorStop(0.55, root.css(root.sheenColor, 0.04));
                dome.addColorStop(1.0, root.css(root.sheenColor, 0.0));
                ctx.fillStyle = dome;
                ctx.fillRect(0, 0, w, h);

                // The inner shadow: the rim falls away into shadow.
                const vig = ctx.createRadialGradient(cx, cy, r * 0.40, cx, cy, r);
                vig.addColorStop(0.0, "rgba(0,0,0,0)");
                vig.addColorStop(0.70, "rgba(0,0,0,0.04)");
                vig.addColorStop(0.90, "rgba(0,0,0,0.16)");
                vig.addColorStop(1.0, "rgba(0,0,0,0.30)");
                ctx.fillStyle = vig;
                ctx.fillRect(0, 0, w, h);

                if (root.fine) {
                    // The specular sweep: a soft band of light crossing the
                    // surface, the way light crosses a record.
                    const ang = -Math.PI / 3;
                    const dx = Math.cos(ang), dy = Math.sin(ang);
                    const mid = -r * 0.28;
                    const mx = cx + dx * mid, my = cy + dy * mid;
                    const band = ctx.createLinearGradient(mx - dy * r, my + dx * r,
                            mx + dy * r, my - dx * r);
                    band.addColorStop(0.00, root.css(root.sheenColor, 0.0));
                    band.addColorStop(0.34, root.css(root.sheenColor, 0.10));
                    band.addColorStop(0.50, root.css(root.sheenColor, 0.17));
                    band.addColorStop(0.66, root.css(root.sheenColor, 0.10));
                    band.addColorStop(1.00, root.css(root.sheenColor, 0.0));
                    ctx.fillStyle = band;
                    ctx.fillRect(0, 0, w, h);

                    // The lit edge: the rim catches the light on the upper
                    // left and falls into shadow on the lower right.
                    ctx.lineWidth = Math.max(1, 1.2 * root.s);
                    ctx.lineCap = "round";
                    ctx.strokeStyle = root.css(Theme.cream, 0.42);
                    ctx.beginPath();
                    ctx.arc(cx, cy, r - ctx.lineWidth * 0.5, Math.PI * 1.12, Math.PI * 1.62);
                    ctx.stroke();
                    ctx.strokeStyle = "rgba(0,0,0,0.35)";
                    ctx.beginPath();
                    ctx.arc(cx, cy, r - ctx.lineWidth * 0.5, Math.PI * 0.12, Math.PI * 0.62);
                    ctx.stroke();
                }
                ctx.restore();
            }
        }

        // The rim: a hairline that keeps the edge crisp over a busy pill.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1, 1 * root.s)
            border.color: root.rimColor
            Behavior on border.color { ColorAnimation { duration: Motion.fast } }
        }

        // Spindle hub, in the media surface's idiom: dark centre with a light
        // ring, so it reads as a hole rather than a flat dot.
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.24
            height: parent.width * 0.24
            radius: width / 2
            color: Qt.darker(Theme.tileBg, 1.7)
            border.width: Math.max(1, 1 * root.s)
            border.color: Qt.alpha(Theme.cream, 0.25)
        }
    }

    // --- the platter --------------------------------------------------------

    /**
     * The steady loop.
     *
     * `from` is not a constant: it is the angle the disc is already at, so a
     * resume picks up where the coast left off instead of snapping back to
     * zero. The loop itself has no seam, because a full turn lands exactly
     * where it started.
     */
    RotationAnimation {
        id: spin
        target: disc
        property: "rotation"
        from: root.spinFrom
        to: root.spinFrom + 360
        duration: Math.round(root.spinSeconds * 1000)
        loops: Animation.Infinite
        alwaysRunToEnd: false
    }

    /**
     * The wind-up. Its easing ends at exactly the loop's own speed, so the
     * hand-over from the wind-up to the loop is a change of acceleration and
     * never a change of pace.
     */
    NumberAnimation {
        id: spinUp
        target: disc
        property: "rotation"
        easing.type: Easing.InQuad
        duration: root.spinUpMs
        onFinished: {
            root.spinFrom = disc.rotation;
            spin.start();
        }
    }

    /**
     * The coast-down: the platter keeps turning for a moment and slows to a
     * stop, the way a record does when the music ends. Its easing starts at
     * the loop's own speed, so the hand-over out of the loop is seamless too.
     */
    NumberAnimation {
        id: coast
        target: disc
        property: "rotation"
        easing.type: Easing.OutCubic
        duration: root.coastMs
        onStopped: root.spinFrom = disc.rotation
    }

    /**
     * Start the platter: the wind-up first, and the loop takes over from the
     * angle the wind-up finished on.
     */
    function startSpin() {
        if (!root.turning)
            return;
        if (coast.running)
            coast.stop();
        if (spin.running || spinUp.running)
            return;
        spinUp.from = disc.rotation;
        spinUp.to = disc.rotation + root.spinRate * root.spinUpMs / 2000;
        spinUp.start();
    }

    /**
     * Stop the platter: a disc that was turning keeps turning for a moment
     * and slows to a stop. One that never got up to speed simply stops where
     * it is.
     */
    function stopSpin() {
        if (spinUp.running) {
            spinUp.stop();
            root.spinFrom = disc.rotation;
            return;
        }
        if (!spin.running)
            return;
        spin.stop();
        root.spinFrom = disc.rotation;
        if (!root.motion)
            return;
        coast.from = disc.rotation;
        coast.to = disc.rotation + root.spinRate * root.coastMs / 3000;
        coast.start();
    }

    onTurningChanged: {
        if (root.turning)
            root.startSpin();
        else
            root.stopSpin();
    }

    onFineChanged: {
        shadow.requestPaint();
        finish.requestPaint();
    }

    onThemeStampChanged: finish.requestPaint()

    Component.onCompleted: {
        if (root.turning)
            root.startSpin();
    }
}
