pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"

/**
 * 時 DISPLAY sub-surface: how the pill itself looks and what the clock shows —
 * the resting display mode, the 12/24h format, running seconds, the Japanese
 * header glyphs and the music visualizer — plus the bottom dock's on/off switch.
 * Reached from the Appearance index and folds back to it on the back chevron or
 * an empty click.
 *
 * The dock's switch is the only dock control here; the rest of the dock's
 * settings are on the dock, in the panel its own gear opens. See `dockRow` for
 * why the switch has to live where the dock cannot reach.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    rows: [
        { item: mainRow, kind: "seg", vals: ["minimal", "classic", "system", "strip"], get: function () { return Flags.mainDisplay; }, set: function (v) { Flags.mainDisplay = v; } },
        { item: timeRow, kind: "seg", vals: [false, true], get: function () { return Flags.time12h; }, set: function (v) { Flags.time12h = v; } },
        { item: secRow, kind: "toggle", get: function () { return Flags.clockSeconds; }, set: function (v) { Flags.clockSeconds = v; } },
        { item: vizStyleRow, kind: "seg", vals: ["bars", "wave"], get: function () { return Flags.musicStyle; }, set: function (v) { Flags.musicStyle = v; } },
        { item: scaleRow, kind: "seg", vals: [0.9, 1.0, 1.1, 1.25], get: function () { return Flags.uiScale; }, set: function (v) { Flags.uiScale = v; } },
        { item: autoHideRow, kind: "toggle", get: function () { return Flags.autoHide; }, set: function (v) { Flags.autoHide = v; } },
        { item: dockRow, kind: "toggle", get: function () { return Flags.dockEnabled; }, set: function (v) { Flags.dockEnabled = v; } }
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

Item { width: 1; height: 7 * root.s }
        SettingsRow {
            id: mainRow
            surface: root
            name: "Main display"
            icon: "clock"

            SettingsSeg {
                s: root.s
                options: [{ label: "Minimal", value: "minimal" }, { label: "Classic", value: "classic" }, { label: "System", value: "system" }, { label: "Strip", value: "strip" }]
                value: Flags.mainDisplay
                onPicked: (v) => Flags.mainDisplay = v
            }
        }

        SettingsRow {
            id: timeRow
            surface: root
            name: "Time format"
            icon: "clock"

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
            icon: "stopwatch"

            LinkToggle {
                s: root.s
                on: Flags.clockSeconds
                onToggled: Flags.clockSeconds = !Flags.clockSeconds
            }
        }

        SettingsRow {
            id: vizStyleRow
            surface: root
            name: "Visualizer style"
            icon: "music"

            SettingsSeg {
                s: root.s
                options: [{ label: "Bars", value: "bars" }, { label: "Waveform", value: "wave" }]
                value: Flags.musicStyle
                onPicked: (v) => Flags.musicStyle = v
            }
        }

        SettingsRow {
            id: scaleRow
            surface: root
            name: "UI scale"
            icon: "scaling"

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
            icon: "eye-off"

            LinkToggle {
                s: root.s
                on: Flags.autoHide
                onToggled: Flags.autoHide = !Flags.autoHide
            }
        }

        SettingsRow {
            id: dockRow
            surface: root
            name: "Dock"
            icon: "dock"
            last: true

            LinkToggle {
                s: root.s
                on: Flags.dockEnabled
                onToggled: Flags.dockEnabled = !Flags.dockEnabled
            }
        }

    }
}
