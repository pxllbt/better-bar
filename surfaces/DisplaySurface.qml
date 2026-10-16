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
        { item: vizStyleRow, kind: "seg", vals: ["bars", "wave"], get: function () { return Flags.musicStyle; }, set: function (v) { Flags.musicStyle = v; } },
        { item: auraRow, kind: "toggle", get: function () { return Flags.auraIntensity > 0; }, set: function (v) { Flags.auraIntensity = v ? 0.75 : 0; } },
        { item: vizRow, kind: "toggle", get: function () { return Flags.musicViz; }, set: function (v) { Flags.musicViz = v; } },
        { item: modulesTile, kind: "nav", surface: "modules" },
        { item: dockRow, kind: "toggle", get: function () { return Flags.dockEnabled; }, set: function (v) { Flags.dockEnabled = v; } },
        { item: clockIconRow, kind: "toggle", get: function () { return Flags.clockIcon; }, set: function (v) { Flags.clockIcon = v; } },
        // Bar behaviour. These used to live on their own INTERFACE page, which
        // meant a second hop for settings that are all about how this bar
        // behaves on screen — the same question DISPLAY already answers.
        { item: scaleRow, kind: "seg", vals: [0.9, 1.0, 1.1, 1.25], get: function () { return Flags.uiScale; }, set: function (v) { Flags.uiScale = v; } },
        { item: motionRow, kind: "toggle", get: function () { return Flags.reduceMotion; }, set: function (v) { Flags.reduceMotion = v; } },
        { item: autoHideRow, kind: "toggle", get: function () { return Flags.autoHide; }, set: function (v) { Flags.autoHide = v; } },
        { item: hideSpecialRow, kind: "toggle", get: function () { return Flags.hideOnSpecial; }, set: function (v) { Flags.hideOnSpecial = v; } },
        { item: cursorFollowRow, kind: "toggle", get: function () { return Flags.cursorFollow; }, set: function (v) { Flags.cursorFollow = v; } },
        { item: mediaAlwaysRow, kind: "toggle", get: function () { return Flags.mediaAlways; }, set: function (v) { Flags.mediaAlways = v; } },
        { item: omarchySurvivalRow, kind: "toggle", get: function () { return Flags.omarchySurvival; }, set: function (v) { Flags.omarchySurvival = v; } },
        { item: omarchyGuardStatusRow, kind: "toggle", get: function () { return false; }, activate: function () { OmarchyGuard.check(); } },
        { item: saverRow, kind: "toggle", get: function () { return Flags.memorySaver; }, set: function (v) { Flags.memorySaver = v; } }
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
            name: "Time icon"
            icon: "clock"
            sub: "Icon left of the time"

            LinkToggle {
                s: root.s
                on: Flags.clockIcon
                onToggled: Flags.clockIcon = !Flags.clockIcon
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

        /**
         * The ambient aura behind the pill: a soft accent bloom that tracks the
         * live audio spectrum. It is a switch rather than a slider because the
         * one thing a user needs to be able to do from here is turn it off — and
         * 0.75 is the value measured to read as a glow rather than a lamp.
         * Reduced motion is honoured on the pill's side: with it on the aura
         * becomes a single static bloom, so this row stays honest.
         */
        SettingsRow {
            id: auraRow
            surface: root
            icon: "music"
            name: "Ambient aura"
            sub: "Pill glows with the music · follows the accent colour"

            LinkToggle {
                s: root.s
                on: Flags.auraIntensity > 0
                onToggled: Flags.auraIntensity = Flags.auraIntensity > 0 ? 0 : 0.75
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

        SettingsRow {
            id: modulesTile
            surface: root
            name: "Pill modules"
            sub: "Optional icons the bar shows"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === modulesTile ? Theme.cream : Theme.iconDim
                stroke: 1.9
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

        /**
         * BAR BEHAVIOUR — the rows that used to justify their own INTERFACE
         * page. They are all "how does this bar behave on screen", which is the
         * same question DISPLAY answers, so they live here now and the extra hop
         * is gone. Kept as a visually separated block rather than eleven
         * undifferentiated rows, so the page still reads as two ideas.
         */
        Item { width: 1; height: 9 * root.s }

        Text {
            text: "BAR BEHAVIOUR"
            color: Theme.faint
            font.family: Theme.font
            font.pixelSize: 9.5 * root.s
            font.weight: Font.DemiBold
            font.letterSpacing: 1.4
            anchors.left: parent.left
            anchors.leftMargin: 15 * root.s
            height: 16 * root.s
            verticalAlignment: Text.AlignVCenter
        }

        Item { width: 1; height: 5 * root.s }

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
            id: motionRow
            surface: root
            name: "Reduce motion"
            icon: "waves"

            LinkToggle {
                s: root.s
                on: Flags.reduceMotion
                onToggled: Flags.reduceMotion = !Flags.reduceMotion
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
            id: hideSpecialRow
            surface: root
            name: "Hide on special workspace"
            icon: "eye-off"

            LinkToggle {
                s: root.s
                on: Flags.hideOnSpecial
                onToggled: Flags.hideOnSpecial = !Flags.hideOnSpecial
            }
        }

        SettingsRow {
            id: cursorFollowRow
            surface: root
            name: "Bar follows cursor"
            icon: "monitor"

            LinkToggle {
                s: root.s
                on: Flags.cursorFollow
                onToggled: Flags.cursorFollow = !Flags.cursorFollow
            }
        }

        SettingsRow {
            id: mediaAlwaysRow
            surface: root
            icon: "music"
            name: "Always show media"
            sub: "Keep the media entry even when nothing is playing"

            LinkToggle {
                s: root.s
                on: Flags.mediaAlways
                onToggled: Flags.mediaAlways = !Flags.mediaAlways
            }
        }

        SettingsRow {
            id: omarchySurvivalRow
            surface: root
            icon: "lock"
            name: "Omarchy survival"
            sub: "Rescan and re-assert custom rows after Omarchy updates"

            LinkToggle {
                s: root.s
                on: Flags.omarchySurvival
                onToggled: Flags.omarchySurvival = !Flags.omarchySurvival
            }
        }

        SettingsRow {
            id: omarchyGuardStatusRow
            surface: root
            icon: OmarchyGuard.busy ? "refresh" : "check"
            name: OmarchyGuard.busy ? "Checking Omarchy…" : "Run Omarchy check now"
            sub: OmarchyGuard.lastError.length > 0
                ? OmarchyGuard.lastError
                : (OmarchyGuard.statusMessage.length > 0 ? OmarchyGuard.statusMessage : "Check that Better Bar still matches the installed Omarchy")

            GlyphIcon {
                width: 15 * root.s
                height: 15 * root.s
                name: "chevron-right"
                color: root.focusRowItem === omarchyGuardStatusRow ? Theme.cream : Theme.iconDim
                stroke: 1.8
            }
        }

        SettingsRow {
            id: saverRow
            surface: root
            name: "Memory saver"
            icon: "stopwatch"
            last: true

            LinkToggle {
                s: root.s
                on: Flags.memorySaver
                onToggled: Flags.memorySaver = !Flags.memorySaver
            }
        }
    }
}
