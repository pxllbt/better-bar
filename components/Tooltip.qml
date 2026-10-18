import QtQuick
import QtQuick.Effects
import "../Singletons"
import "../Commons" as Commons

/**
 * Washi hint bubble for pill controls. Anchored to its parent control;
 * `placement` decides whether the bubble floats above (pointer down) or below
 * (pointer up), and `align` whether its left/right edge or centre lines up
 * with the control, so bubbles near the pill edge never clip off-screen. The
 * host sets `show` from the control's own HoverHandler; the bubble arms after
 * a hover delay, fades in slowly and out fast.
 *
 * Colours pull from Omarchy's native tooltip role in shell.toml via Commons.Color
 * — the same source the bar and panels use — so the pill's tooltips read as one
 * surface with the rest of the shell rather than the pill's own surface palette.
 *
 * Non-interactive by design: no MouseArea or HoverHandler lives here, so it
 * never steals pointer events from the controls or the mixer's hover tracker.
 * It is `visible: false` whenever fully faded, for the same reason.
 */
Item {
    id: root

    property real s: 1
    property string title: ""
    property string desc: ""
    property bool show: false
    property string placement: "above"
    property string align: "center"

    readonly property bool below: placement === "below"
    readonly property real pointerH: 5 * s
    readonly property real gap: 5 * s

    property bool armed: false

    width: bubble.width
    height: bubble.height + pointerH
    z: 1000

    anchors.horizontalCenter: root.align === "center" ? parent.horizontalCenter : undefined
    anchors.left: root.align === "left" ? parent.left : undefined
    anchors.right: root.align === "right" ? parent.right : undefined
    anchors.bottom: below ? undefined : parent.top
    anchors.bottomMargin: below ? 0 : gap
    anchors.top: below ? parent.bottom : undefined
    anchors.topMargin: below ? gap : 0

    visible: armed || opacity > 0.01
    opacity: armed ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: root.armed ? Motion.standard : Motion.fast } }

    Timer {
        id: delay
        interval: 470
        onTriggered: root.armed = true
    }
    onShowChanged: {
        if (show) {
            delay.restart();
        } else {
            delay.stop();
            armed = false;
        }
    }

    Rectangle {
        id: bubble
        anchors.centerIn: parent
        width: Math.max(titleText.implicitWidth, descText.implicitWidth) + 24 * root.s
        height: column.implicitHeight + 16 * root.s
        radius: 8 * root.s
        border.width: 1
        border.color: Commons.Color.tooltip.border
        color: Commons.Color.tooltip.background

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.55)
            shadowBlur: 0.7
            shadowVerticalOffset: 5 * root.s
        }
    }

    Column {
        id: column
        z: 5
        anchors.centerIn: bubble
        anchors.margins: 6 * root.s
        spacing: 3 * root.s

        Text {
            id: titleText
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.title
            color: Commons.Color.tooltip.text
            font.family: Theme.font
            font.pixelSize: 11 * root.s
            font.weight: Font.Bold
        }
        Text {
            id: descText
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.desc.length > 0
            text: root.desc
            color: Qt.alpha(Commons.Color.tooltip.text, 0.6)
            font.family: Theme.font
            font.pixelSize: 10 * root.s
        }
    }

    Canvas {
        anchors.horizontalCenter: root.align === "center" ? parent.horizontalCenter : undefined
        anchors.left: root.align === "left" ? parent.left : undefined
        anchors.right: root.align === "right" ? parent.right : undefined
        anchors.top: root.below ? bubble.bottom : undefined
        anchors.bottom: root.below ? undefined : bubble.top
        width: 11 * root.s
        height: root.pointerH
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            ctx.fillStyle = root.below ? Commons.Color.tooltip.background : Commons.Color.tooltip.background;
            ctx.beginPath();
            if (root.below) {
                ctx.moveTo(0, 0);
                ctx.lineTo(width, 0);
                ctx.lineTo(width / 2, height);
            } else {
                ctx.moveTo(0, height);
                ctx.lineTo(width, height);
                ctx.lineTo(width / 2, 0);
            }
            ctx.closePath();
            ctx.fill();
        }
    }
}