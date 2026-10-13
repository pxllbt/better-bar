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
 * Incurs zero CPU overhead at idle and during recording: FileView
 * watchChanges is disabled to avoid expensive inotify wakeups, while a
 * lightweight reload poll runs at 5s during live capture, 1s during pre-roll
 * countdown, and 2s at idle. The displayed elapsed count and countdown tick
 * smoothly every second via a local timer that re-anchors on each read.
 */
Item {
    id: root

    readonly property string stateFilePath: {
        var xdg = Quickshell.env("XDG_RUNTIME_DIR");
        if (!xdg || xdg.length === 0) xdg = "/tmp";
        return xdg + "/px-gsr/state.json";
    }

    property bool recording: false
    property bool paused: false
    // Last elapsed value read from the service's state file, and when it was
    // read. The displayed count is derived from these, not assigned by them.
    property int serviceElapsed: 0
    property double serviceElapsedAtMs: 0
    // Pre-roll countdown, mirrored from the service and ticked locally so the
    // chip smoothly counts 3… 2… 1… without freezing between file polls.
    property bool countdownPending: false
    property int serviceCountdownRemaining: 0
    property double serviceCountdownAtMs: 0

    readonly property int countdownRemaining: {
        root._tick
        if (root.countdownPending && root.serviceCountdownAtMs > 0) {
            var diff = Math.floor((Date.now() - root.serviceCountdownAtMs) / 1000);
            return Math.max(1, root.serviceCountdownRemaining - diff);
        }
        return root.serviceCountdownRemaining;
    }

    /**
     * The displayed elapsed count.
     *
     * Derived, not stored: between polls it advances off a local clock, so the
     * chip ticks once a second even though the state file is only read every
     * few seconds.
     *
     * Two rules make it exact rather than approximate:
     *
     *  - The anchor is the *service's* clock, taken from the file alongside the
     *    count. The service stamps the pair together, so `now - anchor` is the
     *    true age of the count instead of the age of this process's read of it.
     *  - The count is monotonic within a session. A poll can land on a count
     *    one lower than the last one seen (the service writes once a second, the
     *    poll runs every five, so which second a read catches is luck), and
     *    re-anchoring on it used to snap the display backwards by a second --
     *    the freeze-then-carry-on stutter. `Math.max` with the last shown value
     *    means a late or out-of-order snapshot can never rewind the chip.
     *
     * `_tick` exists purely to re-evaluate this binding once a second; no
     * process is spawned to do it.
     */
    readonly property int elapsed: {
        root._tick
        if (root.recording || root.paused) {
            var projected = root.serviceElapsed
                + Math.max(0, Math.floor((Date.now() - root.serviceElapsedAtMs) / 1000));
            // Ratchet: the chip only ever moves forward until the session ends.
            if (projected > root._elapsedFloor.v)
                root._elapsedFloor.v = projected;
            return root._elapsedFloor.v;
        }
        return 0;
    }

    // Held in an object rather than a plain property on purpose. Reading and
    // writing the same property inside one binding is a binding loop: QML warns
    // "Binding loop detected for property \"elapsed\"" and re-evaluates on every
    // pass. The floor is bookkeeping, not something the UI binds to, so it is
    // stored in an object whose field is mutated without notifying anything --
    // the binding above reads it without depending on it.
    property var _elapsedFloor: ({ v: 0 })

    property int _tick: 0
    Timer {
        interval: 1000
        repeat: true
        running: root.recording || root.countdownPending
        onTriggered: root._tick++
    }

    readonly property string formattedTime: {
        var s = root.elapsed % 60;
        var m = Math.floor(root.elapsed / 60) % 60;
        var h = Math.floor(root.elapsed / 3600);
        var mm = m < 10 ? "0" + m : "" + m;
        var ss = s < 10 ? "0" + s : "" + s;
        // Hours roll the minute field instead of running it past 59: a plain
        // mm:ss formatter printed "60:00" at the hour mark and kept counting.
        return h > 0 ? (h + ":" + mm + ":" + ss) : (mm + ":" + ss);
    }

    // watchChanges stays OFF, and that is deliberate — it looks wrong.
    //
    // With it on, every write the plugin makes to state.json (one per second
    // while recording) costs ~70ms inside Quickshell's FileView change path:
    // measured 7% CPU during a recording, which stalls input on this box (the
    // mouse drops for a moment and comes back). With it off, the poll below
    // re-reads through reload() — a plain read — and measures 0%.
    //
    // The event path is not needed: the poll already runs at 5s while a
    // recording is live, so the latency of losing the instant event is nil.
    FileView {
        id: stateFile
        path: root.stateFilePath
        blockLoading: false
        watchChanges: false
        printErrors: false

        onLoaded: root.updateState()
        onFileChanged: root.updateState()
        onLoadFailed: {
            root.recording = false;
            root.paused = false;
            root.serviceElapsed = 0;
            root.serviceElapsedAtMs = 0;
            root._elapsedFloor.v = 0;
            root.countdownPending = false;
            root.serviceCountdownRemaining = 0;
            root.serviceCountdownAtMs = 0;
        }
    }

    function updateState() {
        root.applyState(stateFile.text());
    }

    // Parse is separate from the read so the fallback poll and the FileView
    // share one code path.
    function applyState(raw) {
        if (!raw || raw.trim().length === 0) {
            root.recording = false;
            root.paused = false;
            root.serviceElapsed = 0;
            root.serviceElapsedAtMs = 0;
            root._elapsedFloor.v = 0;
            root.countdownPending = false;
            root.serviceCountdownRemaining = 0;
            root.serviceCountdownAtMs = 0;
            return;
        }

        try {
            var data = JSON.parse(raw);
            var st = data.recordingState || data.state || "idle";
            root.recording = (st === "recording");
            root.paused = (st === "paused");
            var readElapsed = typeof data.recordingElapsed === "number" ? data.recordingElapsed : 0;
            // The service stamps the count with the clock it measured it on, so
            // the anchor is the count's own age rather than this read's age.
            // A file from an older plugin has no stamp; fall back to "now",
            // which is what the old re-anchor assumed and loses at most a second.
            var readAt = typeof data.recordingElapsedAtMs === "number" && data.recordingElapsedAtMs > 0
                ? data.recordingElapsedAtMs
                : Date.now();
            // Outside a live capture the service's elapsed is a leftover from
            // the previous take, so the anchor is dropped rather than stored —
            // otherwise the next take's 0 would look like a stale read and be
            // rejected against it.
            if (!(root.recording || root.paused)) {
                root.serviceElapsed = 0;
                root.serviceElapsedAtMs = 0;
                root._elapsedFloor.v = 0;
            } else {
                // No monotonic guard on the stored pair: `elapsed` ratchets off
                // `_elapsedFloor` instead, so a late snapshot is corrected
                // by the clock without ever rewinding what is already on screen.
                root.serviceElapsed = readElapsed;
                root.serviceElapsedAtMs = readAt;
            }
            var prevCountdownPending = root.countdownPending;
            root.countdownPending = data.countdownPending === true;
            var readCountdown = typeof data.countdownRemaining === "number" ? data.countdownRemaining : 0;
            if (root.countdownPending) {
                if (!prevCountdownPending || readCountdown !== root.serviceCountdownRemaining) {
                    root.serviceCountdownRemaining = readCountdown;
                    root.serviceCountdownAtMs = Date.now();
                }
            } else {
                root.serviceCountdownRemaining = 0;
                root.serviceCountdownAtMs = 0;
            }
        } catch (e) {
            // A truncated read (the writer mid-flush) keeps the last good state:
            // blanking the chip on a partial write made it flicker out.
        }
    }

    // 1s while countdown is pending, 5s while live, 2s while idle.
    // The display does not depend on this cadence:
    // `elapsed` and `countdownRemaining` are derived from a local clock,
    // so they tick every second regardless.
    Timer {
        id: pollTimer
        interval: root.countdownPending ? 1000 : (root.recording ? 5000 : 2000)
        repeat: true
        running: true
        onTriggered: stateFile.reload()
    }

    // Snappy responsiveness when the user clicks record or stop: bursts 6 quick
    // reloads 300ms apart so the UI transitions instantly, then shuts off.
    Timer {
        id: fastBurstTimer
        interval: 300
        repeat: true
        running: false
        property int ticksRemaining: 0
        onTriggered: {
            stateFile.reload();
            ticksRemaining--;
            if (ticksRemaining <= 0) {
                running = false;
            }
        }
    }

    // Toggle through the plugin's own IPC target so the service's state machine
    // stays the single owner of the recorder's lifecycle.
    Process {
        id: toggleProc
        command: ["omarchy-shell", "px-recast", "toggle"]
    }

    function toggleRecording() {
        toggleProc.running = false;
        toggleProc.running = true;
        // Kick off immediate reload burst so the dynamic island updates in < 300ms
        fastBurstTimer.ticksRemaining = 6;
        fastBurstTimer.running = true;
    }

    Component.onCompleted: root.updateState()
}
