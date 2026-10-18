import QtQuick
import "../Singletons"

/**
 * MediaDisc: a centered circular media card. In the pill bud it is a compact CD
 * that rotates; in the media surface it grows into a vinyl-framed album art disc.
 *
 * Album art is optional — pass it via `coverUrl` and the disc paints the art
 * clipped to a circle, falling back to the vinyl groove pattern when no art is
 * available (no player, or artwork not yet decoded). The physical deck styling
 * — outer rim, micro-grooves, spindle hub — is always present so the card reads
 * as a media object even in silence.
 *
 * Rotation is always tied to a live reason — the pointer hovering the bud, or
 * an actual playing track — so an idle pill does not spin a CD forever.
 */
Item {
    id: root

    property real s: 1
    property bool spinning: false
    /** Album art URL; empty falls back to the groove-only vinyl disc. */
    property string coverUrl: ""

    readonly property real spinSeconds: 6.0

    Item {
        id: disc
        anchors.centerIn: parent
        width: root.width
        height: root.height

        // Vinyl base: the theme's own surface so light themes get a light disc
        // and dark themes get a dark one.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Theme.tileBg
        }

        // Album art clipped to a circle when present; hidden entirely when empty.
        Rectangle {
            anchors.fill: parent
            clip: true
            radius: width / 2
            visible: root.coverUrl.length > 0

            Image {
                anchors.fill: parent
                source: root.coverUrl
                sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: String(source).indexOf("file:") !== 0
                visible: status === Image.Ready || status === Image.Loading
            }
        }

        // Outer rim: enough contrast for the disc to survive over a busy pill.
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1, 1 * root.s)
            border.color: Qt.alpha(Theme.cream, 0.28)
        }

        // Grooves — only visible when no cover art, so the vinyl aesthetic
        // grounds the card without competing with the album artwork.
        Item {
            anchors.fill: parent
            visible: root.coverUrl.length === 0

            // Two declarative rings, not a canvas of concentric strokes.
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
        }

        // Spindle hub, in the media surface's idiom: dark centre with a light
        // ring, so it reads as a hole rather than a flat dot.
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
