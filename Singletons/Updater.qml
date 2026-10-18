pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool busy: false
    property bool checked: false
    property int pending: 0
    property string head: ""
    property string collected: ""
    property real lastCheck: 0
    readonly property int intervalMs: 6 * 3600 * 1000

    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            if (!root.busy && (!root.checked || Date.now() - root.lastCheck > root.intervalMs))
                root.checkNow();
        }
    }
    Timer {
        interval: 15 * 60 * 1000
        running: true
        repeat: true
        onTriggered: {
            if (!omarchyProc.running)
                omarchyProc.running = true;
        }
    }

    Timer { id: first; interval: 4000; running: true; onTriggered: root.checkNow() }

    property bool omarchyUpdateAvailable: false
    onOmarchyUpdateAvailableChanged: {
        if (omarchyUpdateAvailable) {
            if (typeof Plugins !== "undefined") {
                try { Plugins.enable("omarchy.system-update"); } catch (e) {}
            }
        }
    }
    function runOmarchyUpdate() {
        Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"]);
    }

    Process {
        id: omarchyProc
        command: ["omarchy-update-available"]
        onExited: function(exitCode) {
            root.omarchyUpdateAvailable = (exitCode === 0);
        }
    }

    function checkNow() {
        root.busy = true;
        root.lastCheck = Date.now();
        probeProc.running = true;
        if (!omarchyProc.running)
            omarchyProc.running = true;
    }

    Process {
        id: probeProc
        command: ["timeout", "15", "bash", "-c",
            "set -eu; cd \"$1\"; remote_sha=$(git ls-remote --heads origin refs/heads/master 2>/dev/null | awk '{print $1}'); current_sha=$(git rev-parse HEAD 2>/dev/null || true); file=\"${XDG_STATE_HOME:-$HOME/.local/state}/better/update-notified\"; if [ -n \"$remote_sha\" ] && [ -n \"$current_sha\" ] && [ \"$remote_sha\" != \"$current_sha\" ]; then sha=${remote_sha:0:7}; old=\"$(cat \"$file\" 2>/dev/null || true)\"; [ \"$old\" = \"$sha\" ] && { echo same; exit 0; }; mkdir -p \"$(dirname \"$file\")\"; printf \"%s\" \"$sha\" > \"$file\"; echo \"notify $sha 1\"; else rm -f \"$file\"; echo uptodate; fi", "bash", Config.configDir]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.collected = text;
                var parts = text.trim().split(/\s+/);
                var kind = parts[0] || "";
                if (kind === "notify") {
                    root.checked = true;
                    root.head = parts[1] || "";
                    root.pending = parseInt(parts[2] || "0", 10) || 0;
                    Notifs.notify("Pill update available", root.pending + (root.pending === 1 ? " commit behind origin/master" : " commits behind origin/master"), [
                        { text: "Update", invoke: function() { Quickshell.execDetached(["bash", "-c", "omarchy-shell better page '' update 2>/dev/null || qs -p \"$1\" ipc call better page '' update", "bash", Config.configDir]); } }
                    ], 6000);
                } else if (kind === "uptodate" || kind === "same") {
                    root.checked = true;
                    if (kind === "uptodate") {
                        root.pending = 0;
                        root.head = "";
                    }
                } else {
                    root.checked = false;
                }
            }
        }
        onExited: function(exitCode) {
            root.busy = false;
            if (exitCode !== 0 && root.collected === "")
                root.checked = false;
            root.collected = "";
        }
    }
}
