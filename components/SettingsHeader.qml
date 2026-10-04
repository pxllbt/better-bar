import QtQuick
import "../Singletons"

/**
 * Settings surface header: the uppercase title on the left, with a cog at the
 * index or a back chevron on a sub-surface at the right. The header strip is the back target, but the click is
 * handled at the host level (a press anywhere on the top strip steps the surface
 * back), so this is a pure visual.
 *
 * `pal` is the host's SettingsPalette; null means the pill's own tokens, which
 * is every pill surface. The dock's settings panel passes the dock's palette.
 */
Item {
    id: head

    property real s: 1
    property string glyph: ""
    property string title: ""
    property bool showBack: false
    property var pal: null

    readonly property color ink: head.pal ? head.pal.ink : Theme.cream
    readonly property color subInk: head.pal ? head.pal.sub : Theme.subtle
    readonly property color iconInk: head.pal ? head.pal.sub : Theme.iconDim

    width: parent ? parent.width : 0
    height: 22 * head.s

    /**
     * Always false. The kanji header marks are gone, permanently: what used to
     * gate them on `Flags.showGlyphs` is now a readonly false, so a surface
     * that still passes a `glyph` string gets nothing rendered. `glyph` is kept
     * so the call sites still compile — headers are the title plus the trailing
     * cog/back icon.
     */
    readonly property bool glyphShown: false

    // Where the title sits, in SettingsRow's units. Not free choices — they are
    // that component's insets, read off its anchors:
    //   with an icon: icon left 14, width 17 -> right edge 31, label at 31 + 13 -> 44
    //   with neither: label at 12
    // If the icon width, or the icon-to-label gap, changes in SettingsRow, these
    // two numbers have to move with it or every settings surface goes crooked
    // again. Kept as literals rather than a shared constant because the two
    // components deliberately do not know about each other.
    readonly property real labelInset: 44
    readonly property real bareLabelInset: 12

    Text {
        id: headTitle
        //* On the label's guide, so the header word and the row words share a
        //* left edge. This is what a Row could not do: inside a Row the title
        //* follows the glyph by a fixed gap, which lands it at ~24 — between
        //* the icons and the labels, aligned with neither, which is how it read
        //* before.
        anchors.left: parent.left
        anchors.leftMargin: (head.glyphShown ? head.labelInset : head.bareLabelInset) * head.s
        anchors.verticalCenter: parent.verticalCenter
        text: head.title
        color: head.subInk
        font.family: Theme.font
        font.pixelSize: 10 * head.s
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1.6 * head.s
    }

    GlyphIcon {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 16 * head.s
        height: 16 * head.s
        name: head.showBack ? "chevron-left" : "cog"
        color: head.iconInk
        stroke: head.showBack ? 2.2 : 1.7
    }
}
