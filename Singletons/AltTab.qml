pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io

/**
 * State for the Windows-style Alt-Tab switcher.
 *
 * The shell never focuses a window while the switcher is up — it only moves a
 * highlight around this list and focuses on commit. That is the whole point of
 * the gesture: Windows does not switch as you tab, it shows what you are about
 * to land on and switches when you let go of Alt. So the list is snapshotted on
 * open and the compositor is untouched until `commit()`.
 *
 * Ordering is Hyprland's own focus history (MRU), not a guess made here:
 * `Hyprland.toplevels` arrives focus-ordered, and it is what the eye expects
 * when it tabs — the window you were in last is the one you get back on the
 * first press.
 *
 * Windows on the current workspace, the current monitor only. That is what
 * Windows does, and it is also what makes the switcher predictable on a
 * multi-monitor desk: tabbing never throws you onto the other screen.
 */
Singleton {
    id: root

    /** True while the switcher is up. Drives the overlay's visibility. */
    property bool active: false

    /**
     * What the switcher is switching: "window" (Alt+Tab) or "workspace"
     * (Super+Tab). Both gestures share this one switcher — same cards, same
     * highlight, same selection box, same hold-to-preview-then-commit timing —
     * so it is one component with two sources rather than two components that
     * would drift apart.
     */
    property string mode: "window"

    readonly property bool workspaceMode: mode === "workspace"

    /** Monotonic id per open, so a stale thumbnail from a previous gesture can
     *  never be mistaken for this one's. Bumped on open, not per cycle. */
    property int session: 0

    /** Snapshotted candidates for this gesture, focus-ordered (most recent first).
     *  Plain objects, not HyprlandWindow handles: a window may close while the
     *  switcher is up and the row must survive to be drawn (and be skipped). */
    property var items: []

    /** Index into `items`. -1 means "not opened yet". */
    property int index: -1

    /** Tile rectangles published by the overlay, parallel to `items`, in
     *  overlay-local pixels. The marquee hit test reads these so the rule
     *  ("every tile the box touches") cannot drift from what is drawn. */
    property var rects: []

    /** Selection rectangle for click-drag picking, in overlay-local pixels. */
    property bool dragging: false
    property real startX: 0
    property real startY: 0
    property real dragX: 0
    property real dragY: 0

    readonly property bool hasItems: items.length > 0
    readonly property var current: (index >= 0 && index < items.length) ? items[index] : null

    /** The address whose thumbnail a capture is in flight for. */
    property string thumbAddr: ""

    property var thumbProc: thumbProc
    property var thumbQueue: []
    property bool thumbBusy: false

    function classOf(t) {
        if (!t || !t.lastIpcObject)
            return "";
        return t.lastIpcObject.class || t.lastIpcObject.initialClass || "";
    }

    /**
     * Open the switcher, or advance it if it is already up.
     *
     * `mon` is the monitor to show it on. An empty string means "the one you are
     * on", resolved here rather than at the call site so the overlay and the
     * window list can never disagree about which screen they belong to.
     */
    /**
     * Open the switcher, or advance it if it is already up.
     *
     * `mon` is the monitor to show it on. An empty string means "the one you are
     * on", resolved here rather than at the call site so the overlay and the
     * window list can never disagree about which screen they belong to.
     *
     * `wantMode` is "window" or "workspace"; it selects what is being switched.
     * It is a parameter rather than a property the caller sets beforehand because
     * a mid-gesture press must not be able to change the subject underneath the
     * highlight that is already on screen.
     */
    function open(mon, dir, wantMode) {
        var m = wantMode === "workspace" ? "workspace" : "window";
        if (root.active && root.mode !== m)
            return true;
        root.mode = m;

        // Nothing to switch between: do not open. In window mode this is the
        // empty-workspace case, and it must be inert rather than merely empty —
        // on a workspace with no windows there is nothing to show, and the
        // release that follows the press must not move focus either, or tabbing
        // on an empty workspace silently drags you back to wherever the last
        // window was.
        var list = root.workspaceMode ? snapshotWorkspaces(mon) : snapshot(mon);
        if (list.length === 0) {
            close();
            return false;
        }
        if (!root.workspaceMode && !hasSwitchableWindows(mon)) {
            close();
            return false;
        }

        // Already up: this is the second (or third…) Tab, so just move. Keeping
        // the snapshot from the first press is deliberate — Windows does not
        // rebuild the list mid-gesture either, so a window opening under your
        // fingers cannot shift the target out from under the highlight.
        if (root.active) {
            if (list.length > root.items.length)
                root.items = list;
            step(dir);
            return true;
        }

        root.items = list;
        root.session += 1;
        root.index = list.length > 1 ? 1 : 0;
        root.active = true;
        root.dragging = false;
        return true;
    }

    /**
     * Workspaces as switcher rows, in the order Super+Tab walks them.
     *
     * The current workspace is first, then the rest cyclically: current+1,
     * current+2 … wrapping round to 1. That ordering is what makes stepping by one
     * mean the same thing here as it does for the stock Super+Tab bind, which
     * steps `workspace = "e+1"` — the next workspace in cyclic order — so the
     * highlight on the first press lands exactly where the old bind would have
     * taken you.
     *
     * A workspace row carries the app classes open on it rather than a live
     * capture. A screenshot is not available for a workspace you are not on, and
     * faking one from the current screen would be worse than saying what is
     * actually there: the icons and the count are the information a workspace
     * card can honestly give.
     */
    function snapshotWorkspaces(mon) {
        Hyprland.refreshWorkspaces();
        var cur = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1;
        var all = Hyprland.workspaces.values;
        var byId = {};
        for (var i = 0; i < all.length; i++) {
            var w = all[i];
            if (w && !w.special)
                byId[w.id] = w;
        }

        var ids = Object.keys(byId);
        if (ids.length === 0)
            return [];

        // Rotate so the current workspace leads, preserving numeric order in the
        // rest so "next" really is the next number rather than an arbitrary one.
        ids.sort(function (a, b) { return parseInt(a) - parseInt(b); });
        var ordered = [];
        var startAt = 0;
        for (var k = 0; k < ids.length; k++) {
            if (parseInt(ids[k]) === cur) {
                startAt = k;
                break;
            }
        }
        for (var j = 0; j < ids.length; j++)
            ordered.push(ids[(startAt + j) % ids.length]);

        var out = [];
        for (var m = 0; m < ordered.length; m++) {
            var ws = byId[ordered[m]];
            var cls = [];
            var tls = Hyprland.toplevels.values;
            for (var t = 0; t < tls.length; t++) {
                var o = tls[t] ? tls[t].lastIpcObject : null;
                if (!o || !o.mapped || o.hidden)
                    continue;
                if (!o.workspace || parseInt(o.workspace.id) !== ws.id)
                    continue;
                var c = root.classOf(tls[t]);
                if (c.length > 0 && cls.indexOf(c) < 0)
                    cls.push(c);
            }
            out.push({
                address: String(ws.id),
                cls: "",
                apps: cls,
                count: ws.windows !== undefined ? ws.windows : cls.length,
                wsId: ws.id,
                title: (ws.name && ws.name.length ? ws.name : String(ws.id)) + (cls.length > 0 ? " · " + cls.length + (cls.length === 1 ? " app" : " apps") : " · empty"),
                at: { x: 0, y: 0 },
                size: { w: 0, h: 0 },
                thumb: "",
            });
        }
        return out;
    }

    /**
     * Whether there is anything for the switcher to work with on `mon`.
     *
     * Separate from `snapshot()` so the "is there anything to switch to?" question
     * is answered before any state is built, and so the empty case is decided in
     * one obvious place rather than inferred from a zero-length list that three
     * different callers then have to remember to check.
     */
    function hasSwitchableWindows(mon) {
        Hyprland.refreshToplevels();
        var ws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
        var monId = resolveMonitor(mon);
        var tls = Hyprland.toplevels.values;

        for (var i = 0; i < tls.length; i++) {
            var o = tls[i] ? tls[i].lastIpcObject : null;
            if (!o || !o.address)
                continue;
            if (!o.mapped || o.hidden)
                continue;
            if (ws >= 0 && o.workspace && o.workspace.id !== ws)
                continue;
            if (monId >= 0 && o.monitor !== monId)
                continue;
            return true;
        }
        return false;
    }

    /**
     * Candidates for `mon`, most-recently-focused first.
     *
     * Hyprland.toplevels is maintained focus-ordered by the compositor, so that
     * ordering is the MRU order and is preserved rather than re-sorted. The
     * filter is the current workspace on the current monitor: a switcher that
     * spans monitors is how you end up tabbing into a screen you did not mean
     * to leave.
     */
    function snapshot(mon) {
        Hyprland.refreshToplevels();
        var out = [];
        var ws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1;
        var monId = resolveMonitor(mon);
        var tls = Hyprland.toplevels.values;

        for (var i = 0; i < tls.length; i++) {
            var t = tls[i];
            var o = t.lastIpcObject;
            if (!o || !o.address)
                continue;
            // `hidden` is Hyprland's swallowed/occluded flag, not "minimized into
            // a stash"; a hidden window cannot be focused, so it cannot be a
            // tab target.
            if (!o.mapped || o.hidden)
                continue;
            if (ws >= 0 && o.workspace && o.workspace.id !== ws)
                continue;
            if (monId >= 0 && o.monitor !== monId)
                continue;
            out.push({
                address: o.address,
                cls: root.classOf(t),
                title: o.title || "",
                at: (o.at && o.at.length >= 2) ? { x: o.at[0], y: o.at[1] } : { x: 0, y: 0 },
                size: (o.size && o.size.length >= 2) ? { w: o.size[0], h: o.size[1] } : { w: 0, h: 0 },
                thumb: "",
            });
        }
        return out;
    }

    function resolveMonitor(mon) {
        if (mon && mon.length) {
            var m = Hyprland.monitors.find(function(x) { return x.name === mon; });
            if (m)
                return m.id;
        }
        var a = Hyprland.focusedMonitor;
        return a ? a.id : -1;
    }

    /**
     * The same resolution as `resolveMonitor`, but yielding a monitor NAME.
     *
     * The overlay window is keyed by name (it is a per-screen Variants
     * delegate), so the shell needs the name, not the id. Kept as its own
     * function rather than made to happen at the call site so the two cannot
     * disagree about which screen the gesture belongs to.
     */
    function monitorName(mon) {
        if (mon && mon.length)
            return mon;
        var a = Hyprland.focusedMonitor;
        return a ? a.name : "";
    }

    /** Move the highlight. `dir` < 0 walks backwards (Alt+Shift+Tab). */
    function step(dir) {
        var n = root.items.length;
        if (n === 0) {
            close();
            return;
        }
        if (n === 1) {
            root.index = 0;
            return;
        }
        // On open the highlight sits on 1 so the first Tab lands on 2. Stepping
        // from there by one wraps past 0 to n-1 — the window behind the one you
        // started in, which is what the second Tab should show.
        var i = root.index + (dir < 0 ? -1 : 1);
        root.index = ((i % n) + n) % n;
    }

    /**
     * Land on the highlighted window and close.
     *
     * Bails out unless the switcher is genuinely open with a real target. This is
     * the other half of the empty-workspace guard: a press that found nothing to
     * switch to never opened anything, so the release that follows must not focus
     * anything either. Without it, tabbing on an empty workspace focuses a stale
     * address and drags you off the workspace you were standing on.
     */
    function commit(focusWindow) {
        var target = root.current;
        var wasOpen = root.active;
        close();
        if (wasOpen && target && typeof focusWindow === "function")
            focusWindow(target.address);
        return wasOpen && !!target;
    }

    function close() {
        root.active = false;
        root.dragging = false;
        root.rects = [];
        root.items = [];
        root.index = -1;
        root.thumbQueue = [];
        root.thumbAddr = "";
    }

    // ---- selection rectangle --------------------------------------------

    function beginDrag(x, y) {
        root.startX = x;
        root.startY = y;
        root.dragX = x;
        root.dragY = y;
        root.dragging = true;
    }

    function updateDrag(x, y) {
        if (!root.dragging)
            return;
        root.dragX = x;
        root.dragY = y;
    }

    /**
     * Finish a drag and move the highlight onto whatever it covered.
     *
     * The topmost-leftmost hit wins, not the last one in the list: dragging a
     * box across a row should select the tile the box started on, which is the
     * one the eye reads as "the one I grabbed".
     */
    function endDrag(x, y) {
        if (!root.dragging)
            return -1;
        root.updateDrag(x, y);
        root.dragging = false;
        var hit = hitTest();
        if (hit >= 0)
            root.index = hit;
        return hit;
    }

    function hitTest() {
        if (!root.rects || root.rects.length === 0)
            return -1;
        var l = Math.min(root.dragX, root.startX);
        var t = Math.min(root.dragY, root.startY);
        var r = Math.max(root.dragX, root.startX);
        var b = Math.max(root.dragY, root.startY);
        var best = -1;
        for (var i = 0; i < root.rects.length; i++) {
            var q = root.rects[i];
            if (!q)
                continue;
            if (r >= q.x && l <= q.x + q.w && b >= q.y && t <= q.y + q.h) {
                if (best < 0 || i < best)
                    best = i;
            }
        }
        return best;
    }

    readonly property real selLeft: Math.min(dragX, startX)
    readonly property real selTop: Math.min(dragY, startY)
    readonly property real selWidth: Math.abs(dragX - startX)
    readonly property real selHeight: Math.abs(dragY - startY)

    // ---- live thumbnails --------------------------------------------------

    /**
     * Grab one real screenshot of a window's own rectangle.
     *
     * A live capture rather than a remembered icon, because the reason to open a
     * switcher is to find *this* window — a page, a terminal, a document — and an
     * icon cannot tell two browser windows apart. `grim` is given the exact
     * at/size Hyprland reports, so a scaled or fractional-position window still
     * lands where the tile says it does.
     *
     * Written to a cache dir and handed to the overlay as a `file://` URL, which
     * QML's image loader treats as local and caches. One capture at a time: five
     * simultaneous `grim` invocations contend for the same GPU pipe and the whole
     * switcher visibly stutters.
     */
    function requestThumb(item) {
        if (!item || item.thumb.length > 0)
            return;
        var s = item.size;
        if (!s || s.w < 8 || s.h < 8)
            return;
        root.thumbQueue.push(item);
        pumpThumbs();
    }

    function pumpThumbs() {
        if (root.thumbBusy || root.thumbQueue.length === 0)
            return;
        var item = root.thumbQueue.shift();
        var s = item.size;
        var at = item.at;
        // Cap the long edge: a 4K window captured at full size is several MB per
        // tile and the loader decodes it at texture size, for a thumbnail that is
        // never more than a few hundred pixels wide on screen.
        var cap = (s.w >= s.h) ? "640x640>" : "x640>";
        root.thumbAddr = item.address;
        root.thumbBusy = true;
        thumbProc.command = [
            "sh", "-c",
            "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/better/alttab\";"
            + " mkdir -p \"$d\";"
            + " f=\"$d/" + root.session + "-" + String(item.address).replace(/[^0-9a-fx]/g, "") + ".png\";"
            + " grim -g \"" + Math.round(at.x) + "," + Math.round(at.y) + " "
            + Math.round(s.w) + "x" + Math.round(s.h) + "\" \"$f\" || exit 1;"
            + " magick \"$f\" -strip -resize \"" + cap + "\" \"$f\" || exit 1;"
            + " printf %s \"$f\""
        ];
        thumbProc.running = true;
    }

    Process {
        id: thumbProc

        stdout: StdioCollector {
            onStreamFinished: {
                var path = String(text || "").trim();
                if (path.length > 0) {
                    // Hand the path back to the row it belongs to, matched on
                    // address rather than index: the list is rebuilt on open, so
                    // an index can point at a different window by now.
                    var addr = root.thumbAddr;
                    var list = root.items;
                    for (var i = 0; i < list.length; i++) {
                        if (list[i].address === addr && list[i].thumb.length === 0) {
                            var next = list.slice();
                            var patched = {};
                            for (var k in next[i])
                                patched[k] = next[i][k];
                            patched.thumb = "file://" + path;
                            next[i] = patched;
                            root.items = next;
                            break;
                        }
                    }
                }
                root.thumbBusy = false;
                root.pumpThumbs();
            }
        }
    }

    /** Kick off captures for every row that does not have one yet. */
    function captureAll() {
        for (var i = 0; i < root.items.length; i++)
            root.requestThumb(root.items[i]);
    }
}