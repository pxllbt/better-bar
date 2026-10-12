pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"

/**
 * 相 SETTINGS index: the door into the settings, split into
 * nine category tiles — THEME (light, dark, dynamic or
 * manual), DISPLAY (pill layout, time · glyphs), APPEARANCE
 * (accent, glass and font colour — opens its own sub-index),
 * FONT (the family picker), INTERFACE (scale, motion,
 * auto-hide), PLUGINS (install, enable, strip icons), DOCK
 * SETTINGS (the bottom app dock — its panel lives in the dock
 * window, so this tile folds the settings back and opens it
 * there) and UPDATE (pull latest). Picking a tile morphs the
 * pill into that category's surface; the back chevron on each
 * returns here, and an empty click or the cog closes.
 * Reached from the pill's hover row and folds back into it on
 * a dismiss.
 */
SettingsSurface {
    id: root

    backSurface: ""
    implicitHeight: content.implicitHeight

    rows: [
        { item: themeTile, kind: "nav", surface: "theme" },
        { item: appearTile, kind: "nav", surface: "appcat" },
        { item: fontTile, kind: "nav", surface: "fontpicker" },
        { item: dispTile, kind: "nav", surface: "display" },
        { item: dockTile, kind: "nav", surface: "dock" },
        { item: ifaceTile, kind: "nav", surface: "interface" },
        { item: pluginsTile, kind: "nav", surface: "plugins" },
        { item: updateTile, kind: "nav", surface: "update" }
    ]

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "SETTINGS"
            showBack: false
        }

        Item { width: 1; height: 8 * root.s }

        // --- Visuals & Theme ---
        SettingsRow {
            id: themeTile
            surface: root
            glyph: "🎨"
            name: "Theme"
            sub: "Theme gallery · 27 themes"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === themeTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: appearTile
            surface: root
            glyph: "✦"
            name: "Appearance"
            sub: "Accent harmony · glass · font colour"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === appearTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: fontTile
            surface: root
            glyph: "Aa"
            name: "Font"
            sub: "UI family and typography fallback"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === fontTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        // --- Bar & Dock Layout ---
        SettingsRow {
            id: dispTile
            surface: root
            glyph: "◫"
            name: "Display & Pill"
            sub: "Pill layout · time format · glyphs"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === dispTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: dockTile
            surface: root
            glyph: "⎍"
            name: "Dock Settings"
            sub: "Auto-hide · theme · glass · pins"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === dockTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        // --- System & Extensions ---
        SettingsRow {
            id: ifaceTile
            surface: root
            glyph: "⚙"
            name: "Interface"
            sub: "Scale · motion · auto-hide"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === ifaceTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: pluginsTile
            surface: root
            glyph: "⬡"
            name: "Plugins"
            sub: "Install · enable · strip icons"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === pluginsTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: updateTile
            surface: root
            glyph: "↻"
            name: "Update"
            sub: Updater.checked && Updater.pending > 0
                ? Updater.pending + (Updater.pending === 1 ? " commit behind · view in UPDATE" : " commits behind · view in UPDATE")
                : "Pull latest · re-applies the patch"
            last: true

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === updateTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }
    }
}
