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
        { item: dispTile, kind: "nav", surface: "display" },
        { item: appearTile, kind: "nav", surface: "appcat" },
        { item: fontTile, kind: "nav", surface: "fontpicker" },
        { item: ifaceTile, kind: "nav", surface: "interface" },
        { item: lockTile, kind: "nav", surface: "locksettings" },
        { item: pluginsTile, kind: "nav", surface: "plugins" },
        { item: updateTile, kind: "nav", surface: "update" },
        { item: dockTile, kind: "nav", surface: "dock" }
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

Item { width: 1; height: 10 * root.s }
        SettingsRow {
            id: themeTile
            surface: root
            name: "Theme"
            sub: "Light, dark, dynamic or manual"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === themeTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: dispTile
            surface: root
            name: "Display"
            sub: "Pill layout · time · glyphs"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === dispTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: appearTile
            surface: root
            name: "Appearance"
            sub: "Accent, glass, font colour"

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
            name: "Font"
            sub: "UI family and fallback"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === fontTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: ifaceTile
            surface: root
            name: "Interface"
            sub: "Scale, motion, auto-hide"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === ifaceTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: lockTile
            surface: root
            name: "Lock screen"
            sub: "Session lock background, blur, indicators"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === lockTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        // better: plugins settings tile
        SettingsRow {
            id: pluginsTile
            surface: root
            glyph: "⬡"
            name: "Plugins"
            sub: "Install, enable, strip icons"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === pluginsTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        // better: update settings tile — pull the latest Better Bar whenever
        // upstream adds or changes something. UpdateSurface owns the flow.
        SettingsRow {
            id: updateTile
            surface: root
            glyph: "↻"
            name: "Update"
            sub: "Pull latest · re-applies the patch"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === updateTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        // better: dock settings tile — the dock's own panel, opened from
        // the settings index instead of the gear the dock's right end
        // used to carry. "dock" is not a pill surface: toggleSurface's
        // dock case folds the settings back and opens the panel the
        // dock window hosts.
        SettingsRow {
            id: dockTile
            surface: root
            name: "Dock Settings"
            sub: "Auto-hide, theme, glass, minimal"
            last: true

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === dockTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }
    }
}
