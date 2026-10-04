pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Which monitor the pointer is on.
 *
 * Quickshell 0.3.1's Hyprland singleton exposes no cursor position at all --
 * `Hyprland.cursorX`/`cursorY` are undefined and `hyprland monitors` carries
 * no cursor field -- so `hyprctl -j cursorpos` is the only source there is. One
 * call costs about 11ms, which is why this polls on a slow timer rather than
 * per frame.
 *
 * Cost is paid only while the feature is on. With `Flags.cursorFollow` off the
 * timer is not running, neither Process is ever started, and this singleton
 * holds an empty geometry cache: the feature costs nothing when it is unused.
 *
 * Monitor rectangles come from `hyprctl -j monitors` and are cached. They are
 * refetched only when a cursor position lands outside every cached rectangle,
 * which is what a monitor being added, removed or re-laid-out looks like, so
 * there is no second timer and no second periodic cost to keep in step.
 */
Singleton {
    id: root

    /** The monitor holding the pointer, or "" while unknown. */
    property string cursorMonitor: ""

    /** monitor name -> {x, y, w, h}, in the same logical space as cursorpos. */
    property var rects: ({})

    /** Consecutive cursor reads that matched no monitor; drives rect refetching. */
    property int misses: 0

    /**
     * True when cursor-follow is on and `name` is not the monitor the pointer is
     * on. This is the single definition of "this bar is not where the user is",
     * shared by the pill's hide gate and the shell's reserved band so the two
     * cannot disagree about whether a monitor is holding a bar.
     *
     * The empty `cursorMonitor` case reads as false: until the pointer has been
     * located, no bar is hidden, so a slow or failed first read leaves the shell
     * exactly as it was rather than blanking every monitor but one.
     */
    function offCursor(name: string): bool {
        return Flags.cursorFollow && cursorMonitor !== "" && cursorMonitor !== name;
    }

    function readCursor(text: string) {
        const raw = (text || "").trim();
        if (raw === "")
            return;
        let pos;
        try {
            pos = JSON.parse(raw);
        } catch (e) {
            return;
        }
        if (!pos || pos.x === undefined || pos.y === undefined)
            return;

        cursorMonitor = monitorAt(pos.x, pos.y);
        if (cursorMonitor !== "") {
            misses = 0;
            return;
        }

        // Off every known monitor: stale geometry, or the pointer is between
        // layouts. Refetch on the first miss and then about every 5s, so a
        // monitor that never matches cannot double the process spawn rate.
        misses += 1;
        if (misses === 1 || misses % 16 === 0)
            readRects();
    }

    // Deliberately unannotated: QML treats an annotated JS function's
    // parameters as type-checked, and JSON numbers arrive untyped, which it
    // reports on every poll. Plain JS keeps the hot path quiet.
    function monitorAt(x, y) {
        for (const name in rects) {
            const r = rects[name];
            if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
                return name;
        }
        return "";
    }

    function readRects() {
        if (!rectsProc.running)
            rectsProc.running = true;
    }

    function parseRects(text: string) {
        let list;
        try {
            list = JSON.parse((text || "").trim());
        } catch (e) {
            return;
        }
        if (!Array.isArray(list))
            return;

        const next = {};
        for (const m of list)
            next[m.name] = { x: m.x, y: m.y, w: m.width, h: m.height };
        rects = next;
    }

    Process {
        id: cursorProc
        command: ["hyprctl", "-j", "cursorpos"]
        stdout: StdioCollector {
            onStreamFinished: root.readCursor(text)
        }
    }

    Process {
        id: rectsProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            onStreamFinished: root.parseRects(text)
        }
    }

    Timer {
        interval: 300
        running: Flags.cursorFollow
        repeat: true
        onTriggered: cursorProc.running = true
    }

    Component.onCompleted: if (Flags.cursorFollow) readRects()
}