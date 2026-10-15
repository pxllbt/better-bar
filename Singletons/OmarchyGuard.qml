import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

/**
 * Omarchy survival guard for Better Bar.
 *
 * The other guard in this shell protects Better Bar from its own update. This
 * one protects it from Omarchy updating underneath it. It is deliberately slow
 * and cheap: a version probe every 15 minutes, one short process, and an
 * idempotent repair script that re-asserts Better Bar's custom menu row and
 * rescans the host.
 */
Item {
    id: root

    property bool busy: false
    property string statusMessage: ""
    property string lastError: ""
    property string lastVersion: ""
    property bool lastChanged: false

    readonly property string guardPath: Config.hyprPath("scripts", "omarchy-guard.sh")

    readonly property int autoCheckDelayMs: 30000
    readonly property int autoCheckIntervalMs: 15 * 60 * 1000

    /**
     * Run one guard pass. The flag is read here rather than only gating the
     * timers, because a manual repair can still be run while auto-check is off.
     */
    function check() {
        if (root.busy)
            return false;
        root.busy = true;
        root.statusMessage = "Checking Omarchy survival…";
        guardProc.command = [root.guardPath, "--json", "--repair"];
        guardProc.running = true;
        return true;
    }

    function applyStatus(text) {
        try {
            var parsed = JSON.parse(String(text || ""));
            root.lastVersion = String(parsed.version || "");
            root.lastChanged = parsed.changed === true;
            var actions = Array.isArray(parsed.actions) ? parsed.actions : [];
            if (root.lastChanged)
                root.statusMessage = "Omarchy updated · Better Bar re-asserted itself";
            else if (actions.length > 0)
                root.statusMessage = "Better Bar custom settings re-asserted";
            else
                root.statusMessage = "Omarchy survival OK";
            root.lastError = "";
        } catch (e) {
            root.lastError = "Omarchy guard returned no status";
            root.statusMessage = "Omarchy guard failed";
        }
    }

    Process {
        id: guardProc
        running: false
        command: []

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyStatus(String(text || ""));
        }

        onExited: function (code) {
            root.busy = false;
            if (code !== 0 && root.lastError.length === 0)
                root.lastError = "Omarchy guard exited with " + code;
        }
    }

    /**
     * Automatic pass: one shortly after boot, then on a slow clock. Both timers
     * stop when the flag is off, so a disabled guard costs no process at all.
     */
    Timer {
        id: guardBoot
        interval: root.autoCheckDelayMs
        repeat: false
        running: Flags.omarchySurvival
        onTriggered: {
            root.check();
            guardClock.restart();
        }
    }

    Timer {
        id: guardClock
        interval: root.autoCheckIntervalMs
        repeat: true
        running: false
        onTriggered: root.check()
    }
}
