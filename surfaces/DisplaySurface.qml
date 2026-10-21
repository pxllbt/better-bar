pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"

/**
 * 時 DISPLAY sub-surface: how the pill itself looks and what the clock shows —
 * the resting display mode, the 12/24h format, running seconds, visualizer style,
 * ambient aura, scale, auto-hide and the bottom dock's switch.
 * Reached from the Appearance index and folds back to it on the back chevron or
 * an empty click.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    rows: [
        { item: mainRow, kind: "seg", vals: ["minimal", "classic", "system", "strip", "notch"], get: function () { return Flags.mainDisplay; }, set: function (v) { Flags.mainDisplay = v; } },
        { item: timeRow, kind: "seg", vals: [false, true], get: function () { return Flags.time12h; }, set: function (v) { Flags.time12h = v; } },
        { item: secRow, kind: "toggle", get: function () { return Flags.clockSeconds; }, set: function (v) { Flags.clockSeconds = v; } },
        { item: vizStyleRow, kind: "seg", vals: ["bars", "wave"], get: function () { return Flags.musicStyle; }, set: function (v) { Flags.musicStyle = v; } },
        { item: auraRow, kind: "toggle", get: function () { return Flags.auraIntensity > 0; }, set: function (v) { Flags.auraIntensity = v ? 0.75 : 0; } },
        { item: mediaAlwaysRow, kind: "toggle", get: function () { return Flags.mediaAlways; }, set: function (v) { Flags.mediaAlways = v; } },
        { item: scaleRow, kind: "seg", vals: [0.9, 1.0, 1.1, 1.25], get: function () { return Flags.uiScale; }, set: function (v) { Flags.uiScale = v; } },
        { item: autoHideRow, kind: "toggle", get: function () { return Flags.autoHide; }, set: function (v) { Flags.autoHide = v; } },
        { item: dockRow, kind: "toggle", get: function () { return Flags.dockEnabled; }, set: function (v) { Flags.dockEnabled = v; } },
        { item: omarchySurvivalRow, kind: "toggle", get: function () { return Flags.omarchySurvival; }, set: function (v) { Flags.omarchySurvival = v; } }
    ]

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "DISPLAY & BAR"
            showBack: true
        }

        Item { width: 1; height: 8 * root.s }

        Column {
            width: parent.width
            spacing: 11 * root.s

            // Section 1: Clock & Display
            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "CLOCK & DISPLAY"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: clockCardCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: clockCardCol
                        width: parent.width

                        SettingsRow {
                            id: mainRow
                            surface: root
                            name: "Main display"
                            sub: "Resting pill face layout"
                            badgeIcon: "clock"
                            badgeBg: Qt.rgba(0.24, 0.55, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.24, 0.55, 0.98, 0.28)
                            badgeFg: "#60a5fa"

                            SettingsSeg {
                                s: root.s
                                options: [{ label: "Minimal", value: "minimal" }, { label: "Classic", value: "classic" }, { label: "System", value: "system" }, { label: "Strip", value: "strip" }, { label: "Notch", value: "notch" }]
                                value: Flags.mainDisplay
                                onPicked: (v) => Flags.mainDisplay = v
                            }
                        }

                        SettingsRow {
                            id: timeRow
                            surface: root
                            name: "Time format"
                            sub: "12-hour or 24-hour cycle"
                            badgeIcon: "clock"
                            badgeBg: Qt.rgba(0.65, 0.45, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.65, 0.45, 0.98, 0.28)
                            badgeFg: "#c084fc"

                            SettingsSeg {
                                s: root.s
                                options: [{ label: "24H", value: false }, { label: "12H", value: true }]
                                value: Flags.time12h
                                onPicked: (v) => Flags.time12h = v
                            }
                        }

                        SettingsRow {
                            id: secRow
                            surface: root
                            name: "Clock seconds"
                            sub: "Running seconds ticker"
                            badgeIcon: "clock"
                            badgeBg: Qt.rgba(0.96, 0.62, 0.15, 0.16)
                            badgeBorder: Qt.rgba(0.96, 0.62, 0.15, 0.28)
                            badgeFg: "#fbbf24"
                            last: true

                            LinkToggle {
                                s: root.s
                                on: Flags.clockSeconds
                                onToggled: Flags.clockSeconds = !Flags.clockSeconds
                            }
                        }
                    }
                }
            }

            // Section 2: Media & Audio
            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "MEDIA & AUDIO"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: mediaCardCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: mediaCardCol
                        width: parent.width

                        SettingsRow {
                            id: vizStyleRow
                            surface: root
                            name: "Visualizer style"
                            sub: "Audio reactive bars or waveform"
                            badgeIcon: "waves"
                            badgeBg: Qt.rgba(0.95, 0.35, 0.55, 0.16)
                            badgeBorder: Qt.rgba(0.95, 0.35, 0.55, 0.28)
                            badgeFg: "#f43f5e"

                            SettingsSeg {
                                s: root.s
                                options: [{ label: "Bars", value: "bars" }, { label: "Waveform", value: "wave" }]
                                value: Flags.musicStyle
                                onPicked: (v) => Flags.musicStyle = v
                            }
                        }

                        SettingsRow {
                            id: auraRow
                            surface: root
                            name: "Ambient aura"
                            sub: "Pill glows with live audio spectrum"
                            badgeIcon: "sparkles"
                            badgeBg: Qt.alpha(Theme.accent, 0.16)
                            badgeBorder: Qt.alpha(Theme.accent, 0.28)
                            badgeFg: Theme.accent

                            LinkToggle {
                                s: root.s
                                on: Flags.auraIntensity > 0
                                onToggled: Flags.auraIntensity = Flags.auraIntensity > 0 ? 0 : 0.75
                            }
                        }

                        SettingsRow {
                            id: mediaAlwaysRow
                            surface: root
                            name: "Always show media"
                            sub: "Retain media entry with no active player"
                            badgeIcon: "music"
                            badgeBg: Qt.rgba(0.92, 0.35, 0.65, 0.16)
                            badgeBorder: Qt.rgba(0.92, 0.35, 0.65, 0.28)
                            badgeFg: "#f472b6"
                            last: true

                            LinkToggle {
                                s: root.s
                                on: Flags.mediaAlways
                                onToggled: Flags.mediaAlways = !Flags.mediaAlways
                            }
                        }
                    }
                }
            }

            // Section 3: Layout & Behavior
            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "LAYOUT & BEHAVIOR"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: layoutCardCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: layoutCardCol
                        width: parent.width

                        SettingsRow {
                            id: scaleRow
                            surface: root
                            name: "UI scale"
                            sub: "Overall bar scale factor"
                            badgeIcon: "scaling"
                            badgeBg: Qt.rgba(0.12, 0.74, 0.85, 0.16)
                            badgeBorder: Qt.rgba(0.12, 0.74, 0.85, 0.28)
                            badgeFg: "#38bdf8"

                            SettingsSeg {
                                s: root.s
                                options: [{ label: "90%", value: 0.9 }, { label: "100%", value: 1.0 }, { label: "110%", value: 1.1 }, { label: "125%", value: 1.25 }]
                                value: Flags.uiScale
                                onPicked: (v) => Flags.uiScale = v
                            }
                        }

                        SettingsRow {
                            id: autoHideRow
                            surface: root
                            name: "Auto hide"
                            sub: "Slide bar away when unfocused"
                            badgeIcon: "eye-off"
                            badgeBg: Qt.rgba(0.16, 0.78, 0.65, 0.16)
                            badgeBorder: Qt.rgba(0.16, 0.78, 0.65, 0.28)
                            badgeFg: "#2dd4bf"

                            LinkToggle {
                                s: root.s
                                on: Flags.autoHide
                                onToggled: Flags.autoHide = !Flags.autoHide
                            }
                        }

                        SettingsRow {
                            id: dockRow
                            surface: root
                            name: "Bottom dock"
                            sub: "Floating app dock at screen bottom"
                            badgeIcon: "dock"
                            badgeBg: Qt.rgba(0.24, 0.55, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.24, 0.55, 0.98, 0.28)
                            badgeFg: "#60a5fa"

                            LinkToggle {
                                s: root.s
                                on: Flags.dockEnabled
                                onToggled: Flags.dockEnabled = !Flags.dockEnabled
                            }
                        }

                        SettingsRow {
                            id: omarchySurvivalRow
                            surface: root
                            name: "Omarchy survival"
                            sub: "Auto rescan and sync after updates"
                            badgeIcon: "lock"
                            badgeBg: Qt.rgba(0.68, 0.42, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.68, 0.42, 0.98, 0.28)
                            badgeFg: "#c084fc"
                            last: true

                            LinkToggle {
                                s: root.s
                                on: Flags.omarchySurvival
                                onToggled: Flags.omarchySurvival = !Flags.omarchySurvival
                            }
                        }
                    }
                }
            }
        }
    }
}
