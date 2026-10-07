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
        { item: expandRow, kind: "seg", vals: ["media", "pill"], get: function () { return Flags.expandTo; }, set: function (v) { Flags.expandTo = v; } },
        { item: timeRow, kind: "seg", vals: [false, true], get: function () { return Flags.time12h; }, set: function (v) { Flags.time12h = v; } },
        { item: secRow, kind: "toggle", get: function () { return Flags.clockSeconds; }, set: function (v) { Flags.clockSeconds = v; } },
        { item: vizRow, kind: "toggle", get: function () { return Flags.musicViz; }, set: function (v) { Flags.musicViz = v; } },
        { item: dockRow, kind: "toggle", get: function () { return Flags.dockEnabled; }, set: function (v) { Flags.dockEnabled = v; } },
        { item: clockIconRow, kind: "toggle", get: function () { return Flags.clockIcon; }, set: function (v) { Flags.clockIcon = v; } }
    ]

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "DISPLAY"
            showBack: true
        }

Item { width: 1; height: 10 * root.s }
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
            id: expandRow
            surface: root
            name: "Media expand"
            icon: "layers"

            SettingsSeg {
                s: root.s
                options: [{ label: "Media", value: "media" }, { label: "Full pill", value: "pill" }]
                value: Flags.expandTo
                onPicked: (v) => Flags.expandTo = v
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

        /**
         * The 時 glyph used to be a setting with a row of its own here. It is
         * now this build's house style — `Flags.showGlyphs` is a readonly
         * false — so the row is gone rather than disabled, since a switch that
         * can never change anything in a settings list reads as a bug.
         *
         * 時 and the clock face compete for the same slot in the resting pill, so
         * this row used to be hidden whenever the glyphs were on. With the glyph
         * permanently off it always applies, hence no `visible` gate.
         */
        SettingsRow {
            id: clockIconRow
            surface: root
            name: "Clock icon"
            icon: "clock"
            sub: "Icon left of the time"

            LinkToggle {
                s: root.s
                on: Flags.clockIcon
                onToggled: Flags.clockIcon = !Flags.clockIcon
            }
        }

        SettingsRow {
            id: vizRow
            surface: root
            name: "Music visualizer"
            icon: "music"

            LinkToggle {
                s: root.s
                on: Flags.musicViz
                onToggled: Flags.musicViz = !Flags.musicViz
            }
        }

        /**
         * 泊 The bottom dock's on/off switch — the ONE dock setting the pill
         * keeps, and it is here for a structural reason rather than a tidy one.
         *
         * Everything else the dock can be told lives on the dock itself, in the
         * panel its own gear chip opens. But that panel can only be opened from
         * the gear, and the gear is on the bar, and the bar is what slides off
         * the bottom edge when the dock is disabled. A switch that can switch
         * off the only thing you can reach it through is a one-way door, so this
         * row is the way back — here, in the pill, which is always on screen.
         *
         * It is a switch and not a link into the dock's settings, on purpose:
         * the pill must not become a second front door to a panel that belongs to
         * the dock, or the two would drift apart again. Turning the dock on puts
         * its gear within reach; the gear leads to everything else.
         */
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
