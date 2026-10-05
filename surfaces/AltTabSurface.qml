pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import "../Singletons"

/**
 * Windows-style Alt-Tab switcher, drawn over the desktop while the gesture is
 * held.
 *
 * Deliberately not a pill surface. Every other surface grows out of the bar's
 * pill, which is right for a panel you summon and then dismiss, and wrong here:
 * this has to cover the middle of the screen, take the keyboard, and not shift
 * a single pixel when the highlight moves. So it is its own full-screen item,
 * hosted by the overlay window in shell.qml.
 *
 * Two parts, matching the two things asked for:
 *
 *  - the switcher itself: a live screenshot per window, its title, and an accent
 *    highlight box that moves as you Tab. Windows never switches focus while the
 *    gesture is held; neither does this (see AltTab).
 *
 *  - a selection rectangle: press and drag to sweep a box over the tiles, and
 *    the tile it covers is the one you land on. This is the "blue square that
 *    can be any size" half of the gesture, and it works the same whether it
 *    starts on a tile or on the backdrop.
 *
 * Only the switcher part is keyboard-driven, and only while Alt is down — see
 * `latched` for why the overlay survives losing keyboard focus.
 */
Item {
    id: root

    /** Scale factor for the monitor this overlay is on. */
    property real s: 1

/** True while the switcher should be on screen. */
    property bool open: false

    /** Tile geometry. */
    readonly property int tileW: Math.round(268 * s)
    readonly property int tileH: Math.round(168 * s)
    readonly property int gap: Math.round(14 * s)
    readonly property int pad: Math.round(22 * s)
    readonly property int captionH: Math.round(34 * s)

    readonly property int cols: 4
    readonly property int maxRows: 2

    readonly property int n: AltTab.items.length

    /** Rows are capped so the switcher never grows taller than the screen; the
     *  overflow scrolls with the highlight rather than shrinking the tiles. */
    readonly property int perPage: cols * maxRows
    readonly property int pages: Math.max(1, Math.ceil(n / perPage))
    readonly property int page: Math.max(0, Math.min(pages - 1, Math.floor(AltTab.index / perPage)))

    readonly property int first: page * perPage
    readonly property int shown: Math.min(perPage, n - first)

    readonly property int gridW: cols * tileW + (cols - 1) * gap
    readonly property int gridH: Math.ceil(shown / cols) * tileH
        + Math.max(0, Math.ceil(shown / cols) - 1) * gap

    readonly property int cardW: gridW + pad * 2
    readonly property int cardH: gridH + pad * 2 + captionH

    readonly property int cardX: Math.round((width - cardW) / 2)
    readonly property int cardY: Math.round((height - cardH) / 2)

    readonly property real gridX: Math.round((width - gridW) / 2)
    readonly property real gridY: Math.round((height - cardH) / 2) + pad

    /**
     * Which slots are on screen this page, and where each one sits.
     *
     * Published back to AltTab as `rects` so the marquee hit test uses the same
     * numbers the tiles are drawn with. It is recomputed here rather than in the
     * singleton because it depends on the monitor's scale, which the singleton
     * has no way to know.
     */
    function tileRect(slot) {
        var c = slot % root.cols;
        var r = Math.floor(slot / root.cols);
        return {
            x: root.gridX + c * (root.tileW + root.gap),
            y: root.gridY + r * (root.tileH + root.gap),
            w: root.tileW,
            h: root.tileH
        };
    }

    function publishRects() {
        var out = [];
        for (var slot = 0; slot < root.shown; slot++)
            out.push(tileRect(slot));
        AltTab.rects = out;
    }

    onWidthChanged: publishRects()
    onGridXChanged: publishRects()
    onGridYChanged: publishRects()
    onShownChanged: publishRects()
    Component.onCompleted: publishRects()

    /** Absolute item index of a slot on this page. */
    function absOf(slot) {
        return root.first + slot;
    }

    /**
     * Reveal timing.
     *
     * The card fades and scales in once per gesture, but the highlight itself is
     * instant — Windows moves the box with no animation at all, and a highlight
     * that eases between tiles makes rapid Tabbing feel like it is lagging behind
     * your fingers.
     *
     * Driven straight off `open` with a Behavior rather than a hand-rolled
     * reveal property plus a restart-on-change animation. The animation version
     * could be started twice in one tick (the host sets `open` and the host's own
     * monitor-resolution both land together), and whichever restart lost was the
     * one that left the card stuck at zero opacity — invisible, but still mapped
     * and still eating the keyboard. A binding cannot lose that race.
     */
    readonly property real reveal: open ? 1 : 0

    // ---- input ----------------------------------------------------------

    /**
     * The whole screen catches presses so a drag can start anywhere, including
     * the backdrop — a marquee that only exists once the pointer is already over
     * a tile is not a marquee.
     */
    MouseArea {
        id: catcher
        anchors.fill: parent
        hoverEnabled: false
        acceptedButtons: Qt.LeftButton
        onPressed: (m) => {
            AltTab.beginDrag(m.x, m.y);
        }
        onPositionChanged: (m) => AltTab.updateDrag(m.x, m.y)
        onReleased: (m) => AltTab.endDrag(m.x, m.y)
    }

    // ---- card ------------------------------------------------------------

/**
 * A full-screen scrim behind the card.
 *
 * Windows' switcher dims the desktop behind it, and it is not decoration: the
 * thumbnails you are choosing between are captured from that same desktop, so
 * without a scrim the panel competes with the real windows behind it and the
 * switcher is hard to read. The scrim is inside the card's fade, so the whole
 * thing appears and disappears as one object.
 */
Rectangle {
    id: scrim

    anchors.fill: parent
    color: Color.menu.scrim
    opacity: root.reveal

    Behavior on opacity {
        enabled: !Flags.reduceMotion
        NumberAnimation {
            duration: Motion.fast
            easing.type: Easing.OutCubic
        }
    }
}

Rectangle {
    id: card

        width: root.cardW
        height: root.cardH
        x: root.cardX
        y: root.cardY

        radius: 22 * root.s
        // The shell's own popup surface tokens rather than a hand-mixed rgba: the
        // switcher then reads as the same kind of panel as every other surface,
        // and follows whatever the active theme defines for popups.
        color: Color.popups.background
        border.width: Math.max(1, Style.normalBorderWidth)
        border.color: Color.popups.border

        opacity: root.reveal
        visible: opacity > 0.001

        /**
         * The fade is a Behavior on the binding above rather than an imperative
         * animation, so it cannot be left half-applied. `Motion.fast` is short on
         * purpose: this appears under a held key, and anything slower is felt on
         * every single press of a gesture that is repeated dozens of times a
         * session.
         */
        Behavior on opacity {
            enabled: !Flags.reduceMotion
            NumberAnimation {
                duration: Motion.fast
                easing.type: Easing.OutCubic
            }
        }

        /**
         * Scales from slightly under, the way the Windows switcher pops in. The
         * bare `scale` property (rather than a Scale transform) because the
         * implicit centred origin is what the rest of the shell uses, and it is
         * one less thing to get right. Kept subtle (0.96): the gesture is fast
         * and repeated, so a pronounced animation would be felt on every Tab.
         */
        scale: 0.96 + 0.04 * card.opacity

        // ---- selection rectangle -----------------------------------------
        //
        // Drawn above the tiles, so it reads as a lasso over them rather than
        // something behind them. Filled lightly and outlined in the accent so
        // it is visible over both a bright and a dark thumbnail.
        Rectangle {
            id: selBox

            visible: AltTab.dragging && (AltTab.selWidth > 1 || AltTab.selHeight > 1)

            x: AltTab.selLeft
            y: AltTab.selTop - root.gridY + card.pad
            width: AltTab.selWidth
            height: AltTab.selHeight

            radius: 6 * root.s
            color: Qt.alpha(Theme.accent, 0.18)
            border.width: Math.max(1, Math.round(1.5 * root.s))
            border.color: Theme.accent
        }

        // ---- tiles --------------------------------------------------------

        Item {
            id: grid
            x: root.pad
            y: root.pad
            width: root.gridW
            height: root.gridH

            Repeater {
                model: root.shown

                Rectangle {
                    id: tile

                    required property int index

                    readonly property int abs: root.absOf(tile.index)
                    readonly property bool on: tile.abs === AltTab.index

                    readonly property var item: AltTab.items[tile.abs] || null

                    x: (tile.index % root.cols) * (root.tileW + root.gap)
                    y: Math.floor(tile.index / root.cols) * (root.tileH + root.gap)
                    width: root.tileW
                    height: root.tileH

                    radius: Motion.rTile * root.s
                    // Slightly raised off the card so an unfilled tile still has
                    // an edge of its own while its capture is in flight.
                    color: Theme.ghost
                    border.width: tile.on ? Math.max(2, Math.round(2.5 * root.s)) : 1
                    border.color: tile.on ? Theme.accent : Theme.hairSoft

                    clip: true

                    /**
                     * The highlight lifts the tile slightly. Instant, no
                     * Behavior, for the reason given on `reveal`.
                     */
                    scale: tile.on ? 1.0 : 0.985
                    Behavior on scale {
                        enabled: !Flags.reduceMotion
                        NumberAnimation {
                            duration: Motion.fast / 2
                            easing.type: Easing.OutCubic
                        }
                    }
                    Behavior on border.color {
                        enabled: !Flags.reduceMotion
                        ColorAnimation { duration: Motion.fast / 3 }
                    }

                    // ---- workspace card body -----------------------------------------------
                    //
                    // Shown instead of the screenshot when the switcher is
                    // switching workspaces. There is no live capture available
                    // for a workspace you are not standing on, so this says what
                    // is actually there: the workspace's own name, and the apps
                    // open on it. A fake thumbnail of the current screen would
                    // look more like the window cards and be worth less.
                    Column {
                        anchors.fill: parent
                        anchors.margins: 18 * root.s
                        spacing: 12 * root.s
                        visible: AltTab.workspaceMode

                        Text {
                            width: parent.width
                            text: tile.item ? String(tile.item.wsId) : ""
                            color: tile.on ? Theme.accent : Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 46 * root.s
                            font.weight: Font.Bold
                            renderType: Text.NativeRendering
                        }

                        Text {
                            width: parent.width
                            text: tile.item && tile.item.count > 0
                                ? (tile.item.count + (tile.item.count === 1 ? " window" : " windows"))
                                : "empty"
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 12 * root.s
                            font.weight: Font.DemiBold
                        }

                        // The apps open on that workspace, as icons. Deduped in
                        // the snapshot, so this is a set rather than a list of
                        // every window.
                        Flow {
                            width: parent.width
                            spacing: 8 * root.s

                            Repeater {
                                model: tile.item ? (tile.item.apps || []) : []

                                Image {
                                    required property string modelData
                                    width: 26 * root.s
                                    height: 26 * root.s
                                    sourceSize.width: 52
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true
                                    source: modelData.length > 0 ? Quickshell.iconPath(modelData, true) : ""
                                }
                            }
                        }

                        Item { width: 1; height: 1 }
                    }

                    // ---- window card body --------------------------------------
                    //
                    // The live capture. Present but transparent until its grab
                    // lands, so the tile reserves its space from the first frame
                    // and the grid never reflows as images arrive. The rounding
                    // comes from the tile's own `clip: true` — an Image has no
                    // radius of its own.
                    Image {
                        id: shot

                        anchors.fill: parent
                        anchors.margins: 1

                        source: tile.item && tile.item.thumb.length > 0 ? tile.item.thumb : ""
                        sourceSize.width: Math.round(root.tileW * 2)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                        visible: !AltTab.workspaceMode && status === Image.Ready
                        cache: true
                    }

                    /**
                     * Icon + class, shown only while the capture is in flight (or
                     * failed). Once a real screenshot is there it is redundant,
                     * and it is a genuine fallback rather than decoration: a
                     * window that is itself a GPU surface can capture blank.
                     */
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 20 * root.s
                        spacing: 9 * root.s
                        visible: !AltTab.workspaceMode && !shot.visible

                        Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 44 * root.s
                            height: 44 * root.s
                            sourceSize.width: 88
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            source: tile.item && tile.item.cls.length > 0
                                ? Quickshell.iconPath(tile.item.cls, true)
                                : ""
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: parent.width
                            text: tile.item ? tile.item.cls : ""
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.DemiBold
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }
                    }

                    /**
                     * A capture can legitimately come back blank — the window may
                     * be a GPU surface, or mid-redraw — and a capture of a
                     * fullscreen window is mostly black anyway. The icon column
                     * underneath stays visible until the capture has something to
                     * show, so a tile is never an empty frame.
                     */
                }
            }
        }

        // ---- caption ------------------------------------------------------

        Text {
            id: caption

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: grid.bottom
            anchors.topMargin: 14 * root.s
            anchors.leftMargin: root.pad
            anchors.rightMargin: root.pad

            // While dragging, say what the box covers — the marquee needs to be
            // able to *change* the target, so it has to show which target it
            // currently means.
            readonly property var shownItem: AltTab.dragging
                ? (AltTab.hitTest() >= 0 ? AltTab.items[AltTab.hitTest()] : null)
                : AltTab.current

            text: AltTab.dragging
                ? (shownItem ? shownItem.title : "drag to select")
                : (shownItem ? shownItem.title : "")
            color: Theme.cream
            font.family: Theme.font
            font.pixelSize: 13 * root.s
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
        }
    }

    /**
     * Page dots, only when the switcher has outgrown one screen. Three windows
     * never need them and they would just be furniture.
     */
    Row {
        visible: root.pages > 1
        anchors.horizontalCenter: card.horizontalCenter
        anchors.top: card.bottom
        anchors.topMargin: 16 * root.s
        spacing: 7 * root.s
        opacity: root.reveal

        Repeater {
            model: root.pages

            Rectangle {
                required property int index
                width: (index === root.page ? 16 : 6) * root.s
                height: 6 * root.s
                radius: 3 * root.s
                color: index === root.page ? Theme.accent : Theme.hair
                Behavior on width {
                    enabled: !Flags.reduceMotion
                    NumberAnimation { duration: Motion.fast; easing.type: Easing.OutCubic }
                }
            }
        }
    }
}