pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * One settings line: an optional leading kanji, a name and an optional faint sub
 * caption on the left, and a control slot on the right, capped by a single bottom
 * hairline. `control` is the default slot for the toggle, segmented control or
 * chevron. `surface` wires hover and activation back to the owning settings
 * surface so the soul seam tracks the focused row; scale derives from it.
 *
 * Colours come from the surface's `pal` (see SettingsPalette), so the same row
 * renders in the pill or in the dock's own settings panel without either host
 * borrowing the other's palette. The `Theme` fallbacks below only apply to a row
 * used with no surface at all.
 */
Item {
    id: srow

    property var surface: null
    property string glyph: ""
    property string icon: ""
    property string name: ""
    property string sub: ""
    property bool last: false
    property bool captionOnFocus: false
    property string badgeIcon: ""
    property string badgeText: ""
    property color badgeBg: "transparent"
    property color badgeFg: Theme.cream
    property color badgeBorder: "transparent"
    property bool badgeGlow: false
    default property alias control: controlSlot.data

    readonly property real s: srow.surface ? srow.surface.s : 1
    readonly property bool focused: srow.surface ? srow.surface.focusRowItem === srow : false

    /** The host's palette. Every colour below resolves through it. */
    readonly property var pal: srow.surface ? srow.surface.pal : null
    readonly property color ink: srow.pal ? srow.pal.ink : Theme.cream
    readonly property color subInk: srow.pal ? srow.pal.sub : Theme.subtle
    readonly property color faint: srow.pal ? srow.pal.faint : Theme.faint
    readonly property color iconIdle: srow.pal ? srow.pal.sub : Theme.iconDim
    readonly property color tile: srow.pal ? srow.pal.tile : Theme.frameBg
    readonly property color hair: srow.pal ? srow.pal.hair : Theme.hairSoft

    width: parent ? parent.width : 0
    /**
     * Tighter vertical padding than the shipped 12. A settings list is read
     * line-by-line, so the row's job is separation, not breathing room: at 12
     * a fourteen-row page ran to a scroll when it fit comfortably. 9 keeps
     * every row a finger-target while taking a third of the slack out.
     */
    height: Math.max(textCol.implicitHeight, controlSlot.childrenRect.height) + 9 * srow.s

    HoverHandler {
        id: srowHover
        onHoveredChanged: if (srow.surface) srow.surface.reportRowHover(srow, hovered)
    }

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 2 * srow.s
        anchors.bottomMargin: 2 * srow.s
        anchors.leftMargin: srow.badgeIcon.length > 0 || srow.badgeText.length > 0 ? 3 * srow.s : 0
        anchors.rightMargin: srow.badgeIcon.length > 0 || srow.badgeText.length > 0 ? 3 * srow.s : 0
        radius: 8 * srow.s
        color: srow.focused ? Qt.alpha(Theme.cream, 0.10) : (srowHover.hovered ? Qt.alpha(Theme.cream, 0.06) : "transparent")
        Behavior on color { ColorAnimation { duration: Motion.fast } }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (srow.surface) srow.surface.activateRow(srow)
    }

    Rectangle {
        id: badgeChip
        anchors.left: parent.left
        anchors.leftMargin: 12 * srow.s
        anchors.verticalCenter: parent.verticalCenter
        visible: srow.badgeIcon.length > 0 || srow.badgeText.length > 0
        width: 26 * srow.s
        height: 26 * srow.s
        radius: 6.5 * srow.s
        color: srow.badgeBg
        border.width: srow.badgeBorder !== "transparent" ? 1 : 0
        border.color: srow.badgeBorder

        GlyphIcon {
            anchors.centerIn: parent
            visible: srow.badgeIcon.length > 0
            width: 14 * srow.s
            height: 14 * srow.s
            name: srow.badgeIcon
            color: srow.badgeFg
            stroke: 2.0
        }

        Text {
            anchors.centerIn: parent
            visible: srow.badgeText.length > 0 && srow.badgeIcon.length === 0
            text: srow.badgeText
            color: srow.badgeFg
            font.family: Theme.font
            font.pixelSize: 12.5 * srow.s
            font.weight: Font.Bold
        }

        Rectangle {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: -2 * srow.s
            anchors.rightMargin: -2 * srow.s
            width: 7 * srow.s
            height: 7 * srow.s
            radius: width / 2
            color: Theme.accent
            visible: srow.badgeGlow
            border.width: 1.5 * srow.s
            border.color: srow.pal ? srow.pal.tile : Theme.tileBg
        }
    }

    GlyphIcon {
        id: ri
        anchors.left: parent.left
        anchors.leftMargin: 14 * srow.s
        anchors.verticalCenter: parent.verticalCenter
        visible: srow.icon.length > 0 && !badgeChip.visible
        width: 17 * srow.s
        height: 17 * srow.s
        name: srow.icon
        color: srow.focused ? srow.ink : srow.subInk
        stroke: 1.8
    }
    Column {
        id: textCol
        anchors.left: badgeChip.visible ? badgeChip.right : (ri.visible ? ri.right : parent.left)
        anchors.leftMargin: badgeChip.visible ? 12 * srow.s : (ri.visible ? 13 * srow.s : 12 * srow.s)
        anchors.right: controlSlot.left
        anchors.rightMargin: 14 * srow.s
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3 * srow.s

        Text {
            text: srow.name
            width: parent.width
            elide: Text.ElideRight
            color: srow.focused ? Theme.bright : (srow.pal ? srow.pal.ink : Theme.bright)
            font.family: Theme.font
            font.pixelSize: 12.5 * srow.s
            font.weight: Font.DemiBold
        }
        Text {
            width: parent.width
            visible: srow.sub.length > 0 && (!srow.captionOnFocus || srow.focused || srowHover.hovered)
            text: srow.sub
            color: srow.pal ? srow.pal.dim : Theme.dim
            font.family: Theme.font
            font.pixelSize: 10.5 * srow.s
            wrapMode: Text.WordWrap
            lineHeight: 1.2
            /* Two lines, elided. A caption that runs to a third line makes its
             * row taller than every neighbour, and a settings list of ragged
             * heights reads as broken even when each row is correct. */
            maximumLineCount: 2
            elide: Text.ElideRight
        }
    }

    Item {
        id: controlSlot
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: childrenRect.width
        height: implicitHeight
        implicitHeight: {
            var h = 0;
            for (var i = 0; i < children.length; i++) {
                var c = children[i];
                if (c.height > h) h = c.height;
            }
            return h;
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: badgeChip.visible ? textCol.left : parent.left
        anchors.right: parent.right
        anchors.rightMargin: badgeChip.visible ? 12 * srow.s : 0
        height: 1
        color: srow.hair
        visible: !srow.last
    }
}
