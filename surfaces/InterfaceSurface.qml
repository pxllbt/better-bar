pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"

/**
 * 面 INTERFACE sub-surface: general shell behaviour that is not tied to the
 * clock, the theme or the dock — the UI scale, reduced motion, whether the pill
 * auto-hides, and the memory saver. Reached from the Appearance index and folds
 * back to it on the back chevron or an empty click. Dock settings live on their
 * own 泊 DOCK sub-surface.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    rows: [
        { item: scaleRow, kind: "seg", vals: [0.9, 1.0, 1.1, 1.25], get: function () { return Flags.uiScale; }, set: function (v) { Flags.uiScale = v; } },
        { item: motionRow, kind: "toggle", get: function () { return Flags.reduceMotion; }, set: function (v) { Flags.reduceMotion = v; } },
        { item: autoHideRow, kind: "toggle", get: function () { return Flags.autoHide; }, set: function (v) { Flags.autoHide = v; } },
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
            title: "INTERFACE"
            showBack: true
        }

Item { width: 1; height: 7 * root.s }
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
            last: false

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
            last: false

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
