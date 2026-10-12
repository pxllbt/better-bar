pragma ComponentBehavior: Bound
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

/**
 * Recast screen recorder integration for Better Bar.
 *
 * Monitors the live recording state of Better Recast (`pix.recast`)
 * via its runtime state file in `$XDG_RUNTIME_DIR/px-gsr/state.json`.
 *
 * Uses Quickshell's event-driven FileView (kernel inotify) so it incurs
 * zero CPU overhead while idle. When screen recording is active, it exposes
 * `recording`, `elapsed`, and `formattedTime` to display a live REC pill chip
 * in the dynamic island.
 */
Item {
    id: root

    readonly property string stateFilePath: {
        var xdg = Quickshell.env("XDG_RUNTIME_DIR");
        if (!xdg || xdg.length === 0) xdg = "/tmp";
        return xdg + "/px-gsr/state.json";
    }

    readonly property string ipcScriptPath: {
        var home = Quickshell.env("HOME") || "";
        return home + "/.config/omarchy/plugins/pix.recast/scripts/ipc.sh";
    }

    property bool recording: false
    property bool paused: false
    property int elapsed: 0

    readonly property string formattedTime: {
        var m = Math.floor(root.elapsed / 60);
        var s = root.elapsed % 60;
        var mm = m < 10 ? "0" + m : "" + m;
        var ss = s < 10 ? "0" + s : "" + s;
        return mm + ":" + ss;
    }

    FileView {
        id: stateFile
        path: root.stateFilePath
        blockLoading: false
        printErrors: false

        onLoaded: root.updateState()
        onFileChanged: root.updateState()
        onLoadFailed: {
            root.recording = false;
            root.paused = false;
            root.elapsed = 0;
        }
    }

    function updateState() {
        var raw = stateFile.text();
        if (!raw || raw.trim().length === 0) {
            root.recording = false;
            root.paused = false;
            root.elapsed = 0;
            return;
        }

        try {
            var data = JSON.parse(raw);
            var st = data.recordingState || data.state || "idle";
            root.recording = (st === "recording");
            root.paused = (st === "paused");
            root.elapsed = typeof data.recordingElapsed === "number" ? data.recordingElapsed : 0;
        } catch (e) {
            root.recording = false;
            root.paused = false;
            root.elapsed = 0;
        }
    }

    Process {
        id: toggleProc
        command: ["bash", "-c", "if [ -f '" + root.ipcScriptPath + "' ]; then bash '" + root.ipcScriptPath + "' toggle; else pkill -SIGINT -f gpu-screen-recorder || true; fi"]
    }

    function toggleRecording() {
        toggleProc.running = true;
    }

    Component.onCompleted: root.updateState()
}
