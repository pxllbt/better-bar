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

    readonly property string helperDir: "/home/pixllbeat/.config/omarchy/plugins/omarchy-lock-style"
    readonly property string pluginLockViewPath: "/home/pixllbeat/.config/omarchy/plugins/omarchy-lock-style/LockView.qml"
    readonly property string configFilePath: "/home/pixllbeat/.config/omarchy/lock-style.json"
    readonly property string backupFilePath: "/home/pixllbeat/.config/omarchy/lock-style/backup/LockView.original.qml"
    readonly property var presets: LHelper.PRESETS

    property var config: LHelper.defaultConfig()

    FileView {
        id: configFile
        path: root.configFilePath
        watchChanges: false
        atomicWrites: true
        printErrors: false

        onLoaded: {
            var raw = typeof configFile.text === "function" ? configFile.text() : configFile.text;
            if (raw && String(raw).trim().length > 0)
                root.config = LHelper.deepMerge(LHelper.defaultConfig(), JSON.parse(String(raw)));
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

    property string statusMessage: ""

    function loadConfig() {
        configFile.reload()
    }

    function saveConfig() {
        configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
    }

    function applyLockStyle() {
        root.saveConfig()
        var qmlContent = LGenerator.generateLockViewQml(root.config)
        lockViewFile.setText(qmlContent)
        applyProc.command = [
            "bash", "-c",
            'rm -rf "$HOME/.cache/quickshell/qmlcache" 2>/dev/null || true; omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true; omarchy restart shell >/dev/null 2>&1 || true',
            "safe-apply"
        ]
        applyProc.running = true
        root.statusMessage = "✓ Lock screen style applied"
    }

    function applyPreset(key) {
        if (!LHelper.PRESETS[key]) return
        root.config = LHelper.deepMerge(LHelper.defaultConfig(), LHelper.PRESETS[key].config)
        root.statusMessage = "Preset '" + LHelper.PRESETS[key].name + "' loaded. Applying…"
        root.applyLockStyle()
    }

    function testLock() {
        Quickshell.execDetached(["omarchy-system-lock"])
    }

    function restoreStock() {
        root.config = LHelper.deepMerge(LHelper.defaultConfig(), LHelper.PRESETS.stock_omarchy.config)
        root.applyLockStyle()
    }

    Process {
        id: applyProc
        command: []
        onExited: function(code) {
            if (code !== 0)
                root.statusMessage = "✗ Error applying lock screen style"
        }
    }

    Component.onCompleted: {
        root.loadConfig()
    }

    rows: [
        { item: modernTile, activate: () => root.applyPreset("modern_elegance") },
        { item: cyberTile, activate: () => root.applyPreset("cyberpunk_neon") },
        { item: minimalTile, activate: () => root.applyPreset("minimalist_clean") },
        { item: retroTile, activate: () => root.applyPreset("retro_hacker") },
        { item: stockTile, activate: () => root.applyPreset("stock_omarchy") },
        { item: restoreTile, activate: () => root.restoreStock() },
        { item: testTile, activate: () => root.testLock() }
    ]

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

        SettingsRow { id: modernTile; surface: root; glyph: "✦"; name: "Modern Elegance"; sub: "Vertical 12-hour clock, date on top, avatar and quote"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === modernTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
        SettingsRow { id: cyberTile; surface: root; glyph: "‣"; name: "Cyberpunk Terminal"; sub: "Monospace 24-hour clock, asterisk PIN, sharp corners"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === cyberTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
        SettingsRow { id: minimalTile; surface: root; glyph: "•"; name: "Minimalist Focus"; sub: "Clean horizontal clock with pill PIN, no extras"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === minimalTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
        SettingsRow { id: retroTile; surface: root; glyph: "▣"; name: "Retro Terminal"; sub: "Dashes PIN, stacked time, dev quotes"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === retroTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
        SettingsRow { id: stockTile; surface: root; glyph: "Returns"; name: "Stock Omarchy"; sub: "Factory layout (clock and extras hidden)"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === stockTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
        SettingsRow { id: restoreTile; surface: root; glyph: "☼"; name: "Restore Original"; sub: "Restore the untouched stock LockView"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === restoreTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }
        SettingsRow { id: testTile; surface: root; glyph: ",address"; name: "Test Lock Screen"; sub: "Run omarchy-system-lock to preview"
            GlyphIcon { width: 16 * root.s; height: 16 * root.s; name: "chevron-right"; color: root.focusRowItem === testTile ? Theme.cream : Theme.iconDim; stroke: 1.9 }
        }

        Item { width: 1; height: 10 * root.s }

        SettingsRow {
            surface: root
            glyph: "✓"
            name: "Status"
            sub: root.statusMessage.length ? root.statusMessage : "Select a preset to apply and restart the shell"
            last: true
        }
    }
}