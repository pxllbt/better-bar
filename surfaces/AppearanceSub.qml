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
        { item: hyprTile, activate: () => Quickshell.execDetached(["omarchy-launch-config-editor", (Quickshell.env("HOME") || "") + "/.config/hypr/looknfeel.lua"]) },
        { item: lockTile, kind: "nav", surface: "lockstyle" },
        { item: plymouthTile, kind: "nav", surface: "plymouth" },
        { item: screensaverTile, activate: () => Quickshell.execDetached(["omarchy-branding-screensaver", "text"]) }
    ]

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "APPEARANCE & STYLE"
            showBack: true
        }

        Item { width: 1; height: 10 * root.s }

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

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === fontColorTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: hyprTile
            surface: root
            glyph: "❖"
            name: "Window Effects & Borders"
            sub: "Hyprland borders · gaps · blur · animations"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === hyprTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: lockTile
            surface: root
            glyph: "🔒"
            name: "Lock Screen Theme"
            sub: "Customise the session lock screen, clock & blur"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === lockTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: plymouthTile
            surface: root
            glyph: "▶"
            name: "Plymouth Unlock"
            sub: "Custom boot colors and logo, or theme presets"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === plymouthTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: screensaverTile
            surface: root
            glyph: "✨"
            name: "Screensaver"
            sub: "Configure screensaver text & branding"
            last: true

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === screensaverTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }
    }
}