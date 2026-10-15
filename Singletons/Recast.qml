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

    /**
     * What the service's own clock says the count should be right now. Pure:
     * it reads the anchored (count, stamp) pair and nothing else, so it can be
     * called from any slot without re-entering itself.
     */
    function projectedElapsed() {
        if (!(root.recording || root.paused))
            return 0;
        // Guard the anchor. Until the first stamped snapshot arrives
        // `serviceElapsedAtMs` is 0, and projecting from it means dividing the
        // current epoch by 1000 -- ~1.79e9 seconds, which formattedTime()
        // rendered as "497743:59:21". The raw count is the honest answer until
        // there is something to project from.
        if (!(root.serviceElapsedAtMs > 0))
            return root.serviceElapsed;
        var projected = root.serviceElapsed
            + Math.max(0, Math.floor((Date.now() - root.serviceElapsedAtMs) / 1000));
        // Belt and braces. A take is minutes to hours; anything beyond this is a
        // bad anchor rather than a long recording, and rendering it as a huge
        // count is worse than showing the number we actually have.
        if (projected > _maxPlausibleElapsed)
            return root.serviceElapsed;
        return projected;
    }

    /**
     * The running maximum actually on screen.
     *
     * A poll can land on a count one lower than the last one seen (the service
     * writes once a second, the poll runs every five), so re-anchoring on the
     * raw projection used to snap the display backwards by a second — the
     * freeze-then-carry-on stutter. Forward only, so a late or out-of-order
     * snapshot can never rewind the chip.
     *
     * The one exception is a projection of 0, which means the session is over:
     * the next take must not inherit the previous one's count.
     *
     * This value is written from here and from the reset paths ONLY — never from
     * a binding. It used to be assigned inside `elapsed`'s own binding while
     * that binding also read it, which is a binding loop: every tick re-ran the
     * binding, and Quickshell logged "Binding loop detected for property
     * "elapsed"" until the property settled by luck. Splitting the pure read
     * (`elapsed`) from the ratchet (here) removes it: nothing in a binding
     * writes anything a binding reads.
     */
    property int _lastShownElapsed: 0

    // 24h. Long enough that no plausible take is clipped, short enough that a
    // bad anchor is obvious rather than plausible. Guards the projection in
    // projectedElapsed() -- a bad clock would otherwise render as a count in
    // the centuries.
    readonly property int _maxPlausibleElapsed: 86400

    function refreshElapsed() {
        var projected = root.projectedElapsed();
        if (projected > root._lastShownElapsed || projected === 0)
            root._lastShownElapsed = projected;
    }

    /**
     * The displayed elapsed count: a pure read of the ratcheted value above.
     * No clock arithmetic, no branch, no write — a binding that only reads can
     * never loop, whatever else ticks underneath it.
     */
    readonly property int elapsed: root._lastShownElapsed

    onRecordingChanged: root.refreshElapsed()
    onPausedChanged: root.refreshElapsed()
    onServiceElapsedChanged: root.refreshElapsed()

    property int _tick: 0

    // Ticks the derived displays once a second. `elapsed` no longer depends on
    // this — the ratchet is advanced by refreshElapsed() — so the timer drives
    // an assignment rather than re-evaluating a property that writes.
    //
    // countdownPending is in that condition, and must be: the countdown's number
    // is a binding over Date.now(), which is not reactive, and root._tick is the
    // only thing that re-evaluates it. The timer used to run during recording and
    // paused only, so during a pre-roll nothing re-evaluated and the number read
    // once and froze — the chip sat at "STARTING 3…" until the service finished
    // and cleared the pending flag, at which point it jumped straight to REC.
    // The elapsed count is unaffected: refreshElapsed() only ever advances, and
    // during a pre-roll it projects 0, which it also writes through.
    Timer {
        interval: root.countdownPending ? 250 : 1000
        repeat: true
        running: root.recording || root.paused || root.countdownPending
        triggeredOnStart: true
        onTriggered: {
            root._tick = root._tick + 1;
            root.refreshElapsed();
        }
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
            // Same truncation window as an empty read. Resetting here blanked the
            // chip mid-recording for exactly the same reason, and a read that
            // fails because the writer was halfway through is not evidence that
            // the recorder stopped.
            root.updateState();
        }
    }

    function updateState() {
        root.applyState(stateFile.text());
    }

    // Parse is separate from the read so the fallback poll and the FileView
    // share one code path.
    function applyState(raw) {
        if (!raw || raw.trim().length === 0) {
            // Keep the last good state.
            //
            // The service writes this file with atomicWrites:false so its
            // inotify watchers see the change, which means the file is briefly
            // truncated while it is rewritten. Blanking the chip on that window
            // made recastActive flicker false for a frame: the REC face vanished
            // and stripSpecialFace -- gated on `!recastActive` -- took its
            // place, so the pill swapped faces mid-recording and read as two
            // pills. The catch block below has always kept the last good state
            // for a truncated read; an empty read is the same event.
            //
            // Safe to retain: a session that ends writes a real `idle`, so the
            // next successful read carries the truth.
            return;
        }

        try {
            var data = JSON.parse(raw);
            var st = data.recordingState || data.state || "idle";
            var readElapsed = typeof data.recordingElapsed === "number" ? data.recordingElapsed : 0;
            // The service stamps the count with the clock it measured it on, so
            // the anchor is the count's own age rather than this read's age.
            // A file from an older plugin has no stamp; fall back to "now",
            // which is what the old re-anchor assumed and loses at most a second.
            var readAt = typeof data.recordingElapsedAtMs === "number" && data.recordingElapsedAtMs > 0
                ? data.recordingElapsedAtMs
                : Date.now();
            // The count and its anchor are written BEFORE `recording` flips.
            // Flipping it first fires onRecordingChanged -> refreshElapsed()
            // synchronously, against whatever the previous anchor was -- 0 on a
            // cold start, which is what produced the epoch-sized count on the
            // chip. Assigning the pair first makes the change handler read a
            // coherent state instead of a half-applied one.
            if (st === "recording" || st === "paused") {
                root.serviceElapsed = readElapsed;
                root.serviceElapsedAtMs = readAt;
            } else {
                // Outside a live capture the service's elapsed is a leftover from
                // the previous take, so the anchor is dropped rather than stored —
                // otherwise the next take's 0 would look like a stale read and be
                // rejected against it.
                root.serviceElapsed = 0;
                root.serviceElapsedAtMs = 0;
                // Explicit reset rather than relying on the projected === 0
                // branch in refreshElapsed(): flipping `recording` off fires the
                // change handler, but clearing here means the ratchet cannot
                // survive a reset that arrives some other way.
                root._lastShownElapsed = 0;
            }
            root.recording = (st === "recording");
            root.paused = (st === "paused");
            var prevCountdownPending = root.countdownPending;
            root.countdownPending = data.countdownPending === true;
            var readCountdown = typeof data.countdownRemaining === "number" ? data.countdownRemaining : 0;
            if (root.countdownPending) {
                // Anchor exactly once, when the pre-roll starts. Re-anchoring on
                // every poll (the old `readCountdown !== stored` rule) made the
                // chip re-start from the service's latest number each time it
                // landed, so the display went 3 -> 2 -> 1 -> 2 -> 1 and then
                // sat, because the local clock had just been thrown back. The
                // service and the local clock disagree on the phase on purpose --
                // the service publishes once a second and the local clock ticks
                // every second -- so the only correction allowed is when the
                // service's number is HIGHER than the last one, i.e. a genuine
                // reset/restart, never a lower "in-progress" value.
                if (!prevCountdownPending || readCountdown > root.serviceCountdownRemaining) {
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
        fastBurstTimer.ticksRemaining = 10;
        fastBurstTimer.running = true;
    }

    Component.onCompleted: {
        root.updateState();
        root.refreshElapsed();
    }
}
