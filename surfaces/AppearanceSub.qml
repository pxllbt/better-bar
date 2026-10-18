pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import "../Singletons"
import "../components"

/**
 * 相 APPEARANCE sub-index: the appearance & styling category inside Settings.
 * Unifies all desktop customization in one home:
 *   - Accent harmony & custom color overrides
 *   - Glass opacity, material & copy contrast
 *   - Font colors & text palette
 *   - Desktop wallpapers & backgrounds
 *   - Hyprland window effects (borders, gaps, blur, animations)
 *   - Lock screen & Plymouth themes
 *   - Screensaver branding & text
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    rows: [
        { item: accentTile, kind: "nav", surface: "accent" },
        { item: glassTile, kind: "nav", surface: "glass" },
        { item: fontColorTile, kind: "nav", surface: "fontcolor" },
    ]

    /**
     * The page is split into two labelled halves. It used to be one flat run of
     * seven tiles under the single heading APPEARANCE, mixing two different
     * questions — "what colour is this" and "what happens when I lock or boot".
     * Nobody looking for the Plymouth theme would guess it sat between "Font
     * colour" and a Hyprland editor link. The labels are what make the group
     * names mean something.
     */
    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "LOOK & SCREEN"
            showBack: true
        }

        Item { width: 1; height: 7 * root.s }

        Text {
            text: "COLOUR & MATERIAL"
            color: Theme.faint
            font.family: Theme.font
            font.pixelSize: 9.5 * root.s
            font.weight: Font.DemiBold
            font.letterSpacing: 1.4
            anchors.left: parent.left
            anchors.leftMargin: 15 * root.s
            topPadding: 2 * root.s
            bottomPadding: 3 * root.s
        }

        SettingsRow {
            id: accentTile
            surface: root
            glyph: "✦"
            name: "Accent"
            sub: "Override the warm accent colour"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === accentTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: glassTile
            surface: root
            glyph: "✧"
            name: "Glass"
            sub: "Pill material and copy contrast"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === glassTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: fontColorTile
            surface: root
            glyph: "Aa"
            name: "Font colour"
            sub: "Recolour the text family"

            last: true
            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === fontColorTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }
    }
}