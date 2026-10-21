pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Keeps Stylus (browser extension) userstyles in sync with the active
 * Omarchy theme palette.
 *
 * Stylus installs (e.g. ukishima, a dark Firefox-style theme for the
 * web) ship with their own color tokens. When the Omarchy theme changes
 * those tokens go stale unless something pushes the new palette out.
 * This singleton listens to ThemeSync.revision and regenerates a CSS
 * custom-property file at ~/.local/share/better/stylus-theme.css.
 * Stylus userstyles that use CSS variables can @import this file or
 * reference the variables to track the Omarchy palette.
 *
 * The CSS file is the single source of truth that Stylus styles read
 * from; updating it is enough to re-theme all browser windows without
 * restarting the browser.
 */
Singleton {
    id: root

    /** Path the generated CSS file is written to. */
    readonly property string outputPath: {
        var home = Quickshell.env("HOME") || ""
        return home + "/.local/share/better/stylus-theme.css"
    }

    /**
     * The script reads colors.toml (from the active theme) and writes
     * --theme-* custom properties that Stylus userstyles reference.
     * Uses Config.configDir (the plugin root) to resolve the script path.
     */
    readonly property string syncScriptPath: Config.configDir + "/scripts/stylus-sync.py"

    /** Whether the Stylus CSS file exists and is current. */
    property bool synced: false

    Component.onCompleted: {
        // Sync once at startup so the file exists before any browser opens.
        root.sync();
    }

    /**
     * Watch for theme changes. ThemeSync.revision bumps on every palette or
     * wallpaper swap, which is the cadence we mirror.
     *
     * This has to be a top-level Connections object with the handler written
     * as a function. Declared inside the Component.onCompleted block it is a
     * syntax error under QML's bound behaviour -- and because the whole
     * Singletons module fails to compile when one file in it is malformed,
     * that took the ENTIRE bar down to the stock omarchy one rather than
     * costing one feature. The singleton had never been registered in
     * Singletons/qmldir, which is the only reason the broken file had never
     * been compiled before.
     */
    Connections {
        target: ThemeSync
        function onRevisionChanged() { root.sync(); }
    }

    /**
     * Regenerates the Stylus CSS variables file from the current
     * theme colors.toml.
     */
    function sync() {
        syncProc.running = true;
    }

    Process {
        id: syncProc
        command: ["python3", root.syncScriptPath]
        stdout: StdioCollector {
            id: syncStdout
            waitForEnd: true
        }
        onRunningChanged: {
            if (!syncProc.running) {
                root.synced = syncProc.exitCode === 0;
            }
        }
    }
}
