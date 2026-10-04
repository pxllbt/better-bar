pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * Text painted one character at a time, cycling through the
 * theme's own palette: the accent, the primary ink, the lit
 * vermilion, the bright ink and the full vermilion — "2:49"
 * reads as accent / cream / vermLit / bright, and "12:49"
 * completes the sweep with verm. Every colour is a live,
 * auto-synced theme value, read per character on each
 * evaluation, so the sweep follows the theme as it changes.
 *
 * Used for the bar's text labels. Layout is a Row of
 * per-character Text items, so implicitWidth/Height measure
 * exactly like the single-line Text they replace (the strip
 * face reads `stripTime.implicitWidth` for its width budget).
 *
 * `maxWidth` right-elides the label the way Text.ElideRight
 * would: the whole text when it fits, else a proportional cut
 * ending in "…".
 */
Item {
    id: root

    property string text: ""
    /**
     * The palette the characters cycle through — one colour per
     * character, wrapping around. A function rather than a list
     * property: the theme values are read on every call, so a
     * palette that moves (a wallpaper switch on a dynamic theme)
     * re-colours the text with it, where a var property would
     * have snapshotted the colours at creation and kept the old
     * sweep.
     */
    function colorAt(index) {
        var palette = [Theme.accent, Theme.cream, Theme.vermLit,
                       Theme.bright, Theme.verm];
        return palette[index % palette.length];
    }
    property font font: Qt.font({})
    property real letterSpacing: 0
    /** Right-edge budget; 0 (the default) never elides. */
    property real maxWidth: 0

    implicitWidth: row.implicitWidth
    implicitHeight: metric.implicitHeight

    /**
     * The label as painted: the whole text when it fits the
     * budget, else cut against an average glyph width with an
     * ellipsis. The cut is an estimate — fine for a media title,
     * which only needs to stop at its slot.
     */
    readonly property string shown: {
        if (root.maxWidth <= 0 || measure.implicitWidth <= root.maxWidth)
            return root.text;
        var avg = measure.implicitWidth / root.text.length;
        if (avg <= 0)
            return root.text;
        var keep = Math.floor(root.maxWidth / avg) - 1;
        if (keep < 1)
            keep = 1;
        if (keep >= root.text.length)
            keep = root.text.length - 1;
        return root.text.slice(0, keep) + "…";
    }

    Row {
        id: row
        spacing: root.letterSpacing
        Repeater {
            model: root.shown.length
            delegate: Text {
                required property int index
                text: root.shown.charAt(index)
                color: root.colorAt(index)
                font.family: root.font.family
                font.pixelSize: root.font.pixelSize
                font.weight: root.font.weight
                font.features: root.font.features
                font.capitalization: root.font.capitalization
            }
        }
    }

    // Hidden single character used only to measure the line height
    // for the same font the characters render with.
    Text {
        id: metric
        visible: false
        text: "0"
        font.family: root.font.family
        font.pixelSize: root.font.pixelSize
        font.weight: root.font.weight
        font.features: root.font.features
        font.capitalization: root.font.capitalization
    }

    // Hidden full label: how wide the whole text wants to be, which
    // is what the elide budget is measured against.
    Text {
        id: measure
        visible: false
        text: root.text
        font.family: root.font.family
        font.pixelSize: root.font.pixelSize
        font.weight: root.font.weight
        font.features: root.font.features
        font.capitalization: root.font.capitalization
    }
}
