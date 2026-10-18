pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import "../Singletons"
import "../components"

/**
 * 相 APPEARANCE sub-index: the appearance & styling category inside Settings.
 * Unifies desktop customization:
 *   - Accent harmony & custom color overrides
 *   - Glass opacity, material & copy contrast
 *   - Font colors & text palette
 *   - Desktop wallpapers & backgrounds
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    rows: [
        { item: accentTile, kind: "nav", surface: "accent" },
        { item: glassTile, kind: "nav", surface: "glass" },
        { item: fontColorTile, kind: "nav", surface: "fontcolor" },
        { item: wallpaperTile, kind: "nav", surface: "wallpaper" }
    ]

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

        Item { width: 1; height: 8 * root.s }

        Column {
            width: parent.width
            spacing: 11 * root.s

            // Section 1: Colour & Material
            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "COLOUR & MATERIAL"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: colorCardCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: colorCardCol
                        width: parent.width

                        SettingsRow {
                            id: accentTile
                            surface: root
                            name: "Accent harmony"
                            sub: "Accent color palette and custom override"
                            badgeIcon: "sparkles"
                            badgeBg: Qt.alpha(Theme.accent, 0.16)
                            badgeBorder: Qt.alpha(Theme.accent, 0.28)
                            badgeFg: Theme.accent

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === accentTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: glassTile
                            surface: root
                            name: "Glass transparency"
                            sub: "Pill opacity · material · text contrast"
                            badgeIcon: "droplet"
                            badgeBg: Qt.rgba(0.12, 0.74, 0.85, 0.16)
                            badgeBorder: Qt.rgba(0.12, 0.74, 0.85, 0.28)
                            badgeFg: "#38bdf8"

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === glassTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: fontColorTile
                            surface: root
                            name: "Font color"
                            sub: "Recolour primary and secondary text"
                            badgeText: "Aa"
                            badgeBg: Qt.rgba(0.96, 0.62, 0.15, 0.16)
                            badgeBorder: Qt.rgba(0.96, 0.62, 0.15, 0.28)
                            badgeFg: "#fbbf24"
                            last: true

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === fontColorTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }
                    }
                }
            }

            // Section 2: Desktop & Wallpaper
            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "DESKTOP & WALLPAPER"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: desktopCardCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: desktopCardCol
                        width: parent.width

                        SettingsRow {
                            id: wallpaperTile
                            surface: root
                            name: "Wallpapers"
                            sub: "Desktop background gallery · dynamic colors"
                            badgeIcon: "wallpaper"
                            badgeBg: Qt.rgba(0.65, 0.45, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.65, 0.45, 0.98, 0.28)
                            badgeFg: "#c084fc"
                            last: true

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === wallpaperTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }
                    }
                }
            }
        }
    }
}
