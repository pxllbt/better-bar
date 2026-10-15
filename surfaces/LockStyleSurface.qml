pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"
import "/home/pixllbeat/.config/omarchy/plugins/omarchy-lock-style/LockStyleHelper.js" as LHelper
import "/home/pixllbeat/.config/omarchy/plugins/omarchy-lock-style/LockViewGenerator.js" as LGenerator

SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    readonly property string homeDir: Quickshell.env("HOME") || "/home/pixllbeat"
    readonly property string pluginLockViewPath: homeDir + "/.config/omarchy/plugins/omarchy-lock-style/LockView.qml"
    readonly property string configFilePath: homeDir + "/.config/omarchy/lock-style.json"
    readonly property string backupFilePath: homeDir + "/.config/omarchy/lock-style/backup/LockView.original.qml"
    readonly property string stockLockViewPath: "/usr/share/omarchy/shell/plugins/lock/LockView.qml"

    property var config: LHelper.defaultConfig()
    property bool pendingApply: false
    property string statusMessage: ""

    readonly property var dateOptions: [
        { label: "Full", value: "dddd, MMMM d" },
        { label: "Compact", value: "ddd, d MMM yyyy" },
        { label: "ISO", value: "yyyy-MM-dd" }
    ]

    readonly property var clockPositionOptions: [
        { label: "Above", value: "above_pin" },
        { label: "Below", value: "below_pin" }
    ]

    readonly property var layoutOptions: [
        { label: "Center", value: "center" },
        { label: "Top", value: "top_center" },
        { label: "Bottom", value: "bottom_center" },
        { label: "Left", value: "center_left" },
        { label: "Right", value: "center_right" }
    ]

    readonly property var pinModeOptions: [
        { label: "Dots", value: "dots" },
        { label: "Stars", value: "asterisks" },
        { label: "Dashes", value: "dashes" },
        { label: "Hidden", value: "stealth" }
    ]

    readonly property var pinShapeOptions: [
        { label: "Sharp", value: 4 },
        { label: "Soft", value: 14 },
        { label: "Pill", value: 32 }
    ]

    readonly property var blurOptions: [
        { label: "Off", value: 0 },
        { label: "Light", value: 0.5 },
        { label: "Normal", value: 1 },
        { label: "Heavy", value: 1.5 }
    ]

    readonly property var dimOptions: [
        { label: "Light", value: 0.06 },
        { label: "Normal", value: 0.16 },
        { label: "Dark", value: 0.26 },
        { label: "Darker", value: 0.36 }
    ]

    function section(sec) {
        if (!root.config || typeof root.config !== "object")
            root.config = LHelper.defaultConfig();
        if (!root.config[sec] || typeof root.config[sec] !== "object")
            root.config[sec] = {};
        return root.config[sec];
    }

    function valueIn(v, vals, fallback) {
        for (var i = 0; i < vals.length; i++)
            if (vals[i].value === v) return vals[i].value;
        return fallback;
    }

    function setValue(sec, key, value, label) {
        var next = LHelper.deepMerge({}, root.config);
        if (!next[sec] || typeof next[sec] !== "object") next[sec] = {};
        next[sec][key] = value;
        root.config = next;
        root.scheduleApply(label);
    }

    FileView {
        id: configFile
        path: root.configFilePath
        watchChanges: false
        atomicWrites: true
        printErrors: false

        onLoaded: {
            var raw = typeof configFile.text === "function" ? configFile.text() : configFile.text;
            var parsed = null;
            try { parsed = raw ? JSON.parse(String(raw)) : null; } catch (e) { parsed = null; }
            if (parsed && typeof parsed === "object")
                root.config = LHelper.deepMerge(LHelper.defaultConfig(), parsed);
            else
                configFile.setText(JSON.stringify(root.config, null, 2) + "\n");
        }
        onLoadFailed: configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
    }

    FileView {
        id: lockViewFile
        path: root.pluginLockViewPath
        watchChanges: false
        atomicWrites: true
        printErrors: false
    }

    Timer {
        id: applyTimer
        interval: 700
        repeat: false
        running: false
        onTriggered: root.commitApply()
    }

    function scheduleApply(message) {
        root.pendingApply = true;
        root.statusMessage = message + " · applying…";
        applyTimer.restart();
    }

    function saveConfig() {
        configFile.setText(JSON.stringify(root.config, null, 2) + "\n");
    }

    function applyLockStyle() {
        root.pendingApply = false;
        root.saveConfig();

        try {
            var qmlContent = LGenerator.generateLockViewQml(root.config);
            lockViewFile.setText(qmlContent);
        } catch (e) {
            root.statusMessage = "Lock generator failed: " + e;
            return;
        }

        root.statusMessage = "Lock screen updated";
        applyProc.command = [
            "bash", "-c",
            'rm -rf "$HOME/.cache/quickshell/qmlcache" 2>/dev/null || true; omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true; omarchy restart shell >/dev/null 2>&1 || true',
            "safe-apply"
        ];
        applyProc.running = true;
    }

    Process {
        id: applyProc
        running: false
        onExited: function(code) {
            if (code !== 0)
                root.statusMessage = "Could not apply the lock screen";
        }
    }

    function loadPreset(key) {
        var preset = LHelper.PRESETS[key];
        if (!preset) return;
        root.config = LHelper.deepMerge(LHelper.defaultConfig(), preset.config);
        root.scheduleApply("Preset " + preset.name);
    }

    function restoreOriginal() {
        restoreProc.command = [
            "bash", "-c",
            'if [ -f "$2" ]; then cp -f "$2" "$1"; elif [ -f "$3" ]; then cp -f "$3" "$1"; fi\nrm -rf "$HOME/.cache/quickshell/qmlcache" 2>/dev/null || true\nomarchy-shell shell rescanPlugins >/dev/null 2>&1 || true\nomarchy restart shell >/dev/null 2>&1 || true',
            "safe-restore",
            root.pluginLockViewPath,
            root.backupFilePath,
            root.stockLockViewPath
        ];
        restoreProc.running = true;
        root.statusMessage = "Stock lock view restored";
    }

    Process {
        id: restoreProc
        running: false
    }

    function testLock() {
        Quickshell.execDetached(["omarchy-system-lock"]);
    }

    Component.onCompleted: {
        configFile.reload();
    }

    rows: [
        { item: modernTile, activate: () => root.loadPreset("modern_elegance") },
        { item: cyberTile, activate: () => root.loadPreset("cyberpunk_neon") },
        { item: minimalTile, activate: () => root.loadPreset("minimalist_clean") },
        { item: retroTile, activate: () => root.loadPreset("retro_hacker") },
        { item: stockTile, activate: () => root.loadPreset("stock_omarchy") },

        { item: clockEnabledRow, kind: "toggle", get: function () { return root.section("clock").enabled !== false; }, set: function (v) { root.setValue("clock", "enabled", v, "Clock"); } },
        { item: clockFormatRow, kind: "seg", vals: ["24h", "12h"], get: function () { return root.section("clock").format; }, set: function (v) { root.setValue("clock", "format", v, "Clock format"); } },
        { item: clockLayoutRow, kind: "seg", vals: ["horizontal", "vertical"], get: function () { return root.section("clock").layout; }, set: function (v) { root.setValue("clock", "layout", v, "Clock layout"); } },
        { item: clockPositionRow, kind: "seg", vals: ["above_pin", "below_pin"], get: function () { return root.section("clock").position; }, set: function (v) { root.setValue("clock", "position", v, "Clock position"); } },

        { item: dateEnabledRow, kind: "toggle", get: function () { return root.section("date").enabled !== false; }, set: function (v) { root.setValue("date", "enabled", v, "Date"); } },
        { item: datePresetRow, kind: "seg", vals: ["dddd, MMMM d", "ddd, d MMM yyyy", "yyyy-MM-dd"], get: function () { return root.valueIn(root.section("date").format, root.dateOptions, root.dateOptions[0].value); }, set: function (v) { root.setValue("date", "format", v, "Date format"); } },

        { item: pinModeRow, kind: "seg", vals: ["dots", "asterisks", "dashes", "stealth"], get: function () { return root.section("pinBox").mode; }, set: function (v) { root.setValue("pinBox", "mode", v, "PIN input"); } },
        { item: pinShapeRow, kind: "seg", vals: [4, 14, 32], get: function () { return root.section("pinBox").radius; }, set: function (v) { root.setValue("pinBox", "radius", v, "PIN shape"); } },
        { item: pinWidthRow, kind: "seg", vals: [320, 360, 380, 420], get: function () { return root.section("pinBox").width; }, set: function (v) { root.setValue("pinBox", "width", v, "PIN size"); } },

        { item: layoutRow, kind: "seg", vals: ["center", "top_center", "bottom_center", "center_left", "center_right"], get: function () { return root.valueIn(root.section("layout").position, root.layoutOptions, root.layoutOptions[0].value); }, set: function (v) { root.setValue("layout", "position", v, "Layout"); } },
        { item: blurRow, kind: "seg", vals: [0, 0.5, 1, 1.5], get: function () { return root.section("wallpaper").blur; }, set: function (v) { root.setValue("wallpaper", "blur", v, "Wallpaper blur"); } },
        { item: dimRow, kind: "seg", vals: [0.06, 0.16, 0.26, 0.36], get: function () { return root.section("wallpaper").dim; }, set: function (v) { root.setValue("wallpaper", "dim", v, "Darkness"); } },

        { item: avatarRow, kind: "toggle", get: function () { return root.section("user").avatarEnabled !== false; }, set: function (v) { root.setValue("user", "avatarEnabled", v, "Avatar"); } },
        { item: quoteRow, kind: "toggle", get: function () { return root.section("user").quoteEnabled === true; }, set: function (v) { root.setValue("user", "quoteEnabled", v, "Quote"); } },
        { item: mediaRow, kind: "toggle", get: function () { return root.section("media").enabled !== false; }, set: function (v) { root.setValue("media", "enabled", v, "Media"); } },
        { item: animationRow, kind: "toggle", get: function () { return root.section("visuals").animations !== false; }, set: function (v) { root.setValue("visuals", "animations", v, "Animations"); } },

        { item: restoreTile, activate: () => root.restoreOriginal() },
        { item: testTile, activate: () => root.testLock() }
    ]

    Component.onDestruction: {
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "LOCK SCREEN · STYLES"
            showBack: true
        }

        Item { width: 1; height: 10 * root.s }

        SettingsRow {
            id: modernTile
            surface: root
            glyph: "✦"
            name: "Modern Elegance"
            sub: "Vertical 12h clock · avatar and quote"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === modernTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        SettingsRow {
            id: cyberTile
            surface: root
            glyph: "‣"
            name: "Cyberpunk Terminal"
            sub: "24h terminal · sharp PIN and quotes"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === cyberTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        SettingsRow {
            id: minimalTile
            surface: root
            glyph: "•"
            name: "Minimalist Focus"
            sub: "Clean horizontal clock · pill PIN"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === minimalTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        SettingsRow {
            id: retroTile
            surface: root
            glyph: "▣"
            name: "Retro Terminal"
            sub: "Stacked time · dashes and quotes"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === retroTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        SettingsRow {
            id: stockTile
            surface: root
            glyph: "Returns"
            name: "Stock Omarchy"
            sub: "Hide clock, date and user extras"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === stockTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        Item { width: 1; height: 8 * root.s }

        SettingsRow {
            id: clockEnabledRow
            surface: root
            name: "Clock"
            icon: "clock"
            sub: "Show the time above or below the input"
            LinkToggle { s: root.s; on: root.section("clock").enabled !== false; onToggled: { root.setValue("clock", "enabled", !on, "Clock") } }

        }

        SettingsRow {
            id: clockFormatRow
            surface: root
            name: "Clock format"
            icon: "type"
            sub: ""
            SettingsSeg {
                s: root.s
                options: [
                    { label: "24h", value: "24h" },
                    { label: "12h", value: "12h" }
                ]
                value: root.section("clock").format
                onPicked: (v) => root.setValue("clock", "format", v, "Clock format")
            }
        }

        SettingsRow {
            id: clockLayoutRow
            surface: root
            name: "Clock layout"
            icon: "type"
            sub: ""
            SettingsSeg {
                s: root.s
                options: [
                    { label: "Horizontal", value: "horizontal" },
                    { label: "Vertical", value: "vertical" }
                ]
                value: root.section("clock").layout
                onPicked: (v) => root.setValue("clock", "layout", v, "Clock layout")
            }
        }

        SettingsRow {
            id: clockPositionRow
            surface: root
            name: "Clock position"
            icon: "type"
            sub: ""
            SettingsSeg {
                s: root.s
                options: root.clockPositionOptions
                value: root.section("clock").position
                onPicked: (v) => root.setValue("clock", "position", v, "Clock position")
            }
        }

        SettingsRow {
            id: dateEnabledRow
            surface: root
            name: "Date"
            icon: "clock"
            sub: "Show the date beside the clock"
            LinkToggle { s: root.s; on: root.section("date").enabled !== false; onToggled: { root.setValue("date", "enabled", !on, "Date") } }
        }

        SettingsRow {
            id: datePresetRow
            surface: root
            name: "Date format"
            icon: "clock"
            sub: ""
            SettingsSeg {
                s: root.s
                options: root.dateOptions
                value: root.valueIn(root.section("date").format, root.dateOptions, root.dateOptions[0].value)
                onPicked: (v) => root.setValue("date", "format", v, "Date format")
            }
        }

        Item { width: 1; height: 8 * root.s }

        SettingsRow {
            id: pinModeRow
            surface: root
            name: "Password style"
            icon: "lock"
            sub: ""
            SettingsSeg {
                s: root.s
                options: root.pinModeOptions
                value: root.section("pinBox").mode
                onPicked: (v) => root.setValue("pinBox", "mode", v, "Password style")
            }
        }

        SettingsRow {
            id: pinShapeRow
            surface: root
            name: "Input shape"
            icon: "lock"
            sub: ""
            SettingsSeg {
                s: root.s
                options: root.pinShapeOptions
                value: root.section("pinBox").radius
                onPicked: (v) => root.setValue("pinBox", "radius", v, "Input shape")
            }
        }

        SettingsRow {
            id: pinWidthRow
            surface: root
            name: "Input size"
            icon: "layers"
            sub: ""
            SettingsSeg {
                s: root.s
                options: [
                    { label: "Narrow", value: 320 },
                    { label: "Normal", value: 360 },
                    { label: "Wide", value: 380 },
                    { label: "XL", value: 420 }
                ]
                value: root.section("pinBox").width
                onPicked: (v) => root.setValue("pinBox", "width", v, "Input size")
            }
        }

        Item { width: 1; height: 8 * root.s }

        SettingsRow {
            id: layoutRow
            surface: root
            name: "Screen layout"
            icon: "monitor"
            sub: "Where the lock column sits"
            SettingsSeg {
                s: root.s
                options: root.layoutOptions
                value: root.valueIn(root.section("layout").position, root.layoutOptions, root.layoutOptions[0].value)
                onPicked: (v) => root.setValue("layout", "position", v, "Layout")
            }
        }

        SettingsRow {
            id: blurRow
            surface: root
            name: "Wallpaper blur"
            icon: "droplet"
            sub: ""
            SettingsSeg {
                s: root.s
                options: root.blurOptions
                value: root.section("wallpaper").blur
                onPicked: (v) => root.setValue("wallpaper", "blur", v, "Wallpaper blur")
            }
        }

        SettingsRow {
            id: dimRow
            surface: root
            name: "Darkening"
            icon: "eye-off"
            sub: "Black overlay over the wallpaper"
            SettingsSeg {
                s: root.s
                options: root.dimOptions
                value: root.section("wallpaper").dim
                onPicked: (v) => root.setValue("wallpaper", "dim", v, "Darkening")
            }
        }

        Item { width: 1; height: 8 * root.s }

        SettingsRow {
            id: avatarRow
            surface: root
            name: "Avatar"
            icon: "sparkles"
            sub: "Use ~/.face or ~/.face.icon"
            LinkToggle { s: root.s; on: root.section("user").avatarEnabled !== false; onToggled: { root.setValue("user", "avatarEnabled", !on, "Avatar") } }
        }

        SettingsRow {
            id: quoteRow
            surface: root
            name: "Motivational quote"
            icon: "language"
            sub: "One developer quote per wake"
            LinkToggle { s: root.s; on: root.section("user").quoteEnabled === true; onToggled: { root.setValue("user", "quoteEnabled", !on, "Motivational quote") } }
        }

        SettingsRow {
            id: mediaRow
            surface: root
            name: "Media card"
            icon: "music"
            sub: "Show playing track when visible"
            LinkToggle { s: root.s; on: root.section("media").enabled !== false; onToggled: { root.setValue("media", "enabled", !on, "Media card") } }
        }

        SettingsRow {
            id: animationRow
            surface: root
            name: "Animations"
            icon: "sparkles"
            sub: "Softer clock and focus transitions"
            LinkToggle { s: root.s; on: root.section("visuals").animations !== false; onToggled: { root.setValue("visuals", "animations", !on, "Animations") } }
        }

        Item { width: 1; height: 8 * root.s }

        SettingsRow {
            id: restoreTile
            surface: root
            glyph: "☼"
            name: "Restore Original"
            sub: "Put back the untouched stock LockView"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === restoreTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        SettingsRow {
            id: testTile
            surface: root
            glyph: "▶"
            name: "Preview lock"
            sub: "Change applies shortly, then lock to check"
            last: true
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === testTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
    }
}