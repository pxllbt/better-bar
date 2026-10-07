pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * 常 Strip layout: the pill's order of record for the status-row cells --
 * native cells, separators and enabled plugins together -- persisted as a JSON
 * array in the pill state dir (pill/strip-layout.json) through a FileView, the
 * same pattern DockPins uses, so a drag or an inserted gap survives restarts.
 *
 * The file is an ordering, never a hide-list: entries the shell does not know
 * are dropped at resolve time, and any native cell or enabled plugin missing
 * from the file is appended in default order. That is what lets a newly
 * enabled plugin walk onto the end of the strip the moment it appears, while
 * a deleted or rewritten file simply means default order.
 *
 * What lives here is `resolved`: one flat array of `{kind, id}` records --
 * `kind` is "cell" (a native strip cell), "plugin" or "sep" -- that the pill's
 * status row renders directly. Any mutation (move, insertSeparator,
 * removeSeparator, reset) re-writes `resolved` and persists it, so the model
 * the Row shows and the file on disk never disagree.
 */
Singleton {
    id: root

    readonly property string layoutFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/pill/strip-layout.json"

    /**
     * The strip's long-standing physical order. `tray` is the whole
     * minimized-window cluster (MinimizedTray, its hair, the system Tray), one
     * movable unit; `dnd` is its own cell.
     */
    readonly property var nativeOrder: [
        "weather", "tray", "dnd",
        "wifi", "bt", "battery",
        "inbox", "mixer", "sysmon", "wallpaper", "clipboard",
        "launcher", "appearance", "power"
    ]

    readonly property var plugins: Plugins.pillWidgetsGeneric

    property var resolved: []

    FileView {
        id: store
        path: root.layoutFile
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Component.onCompleted: root.rebuild()

    onPluginsChanged: root.rebuild()

    function pluginActive(id) {
        for (var i = 0; i < root.plugins.length; i++)
            if (root.plugins[i].id === id) return true;
        return false;
    }

    function readLayout() {
        var raw = store.text();
        if (!raw || raw.length === 0) return [];
        try {
            var v = JSON.parse(raw);
            return Array.isArray(v) ? v : [];
        } catch (e) {
            return [];
        }
    }

    /**
     * Rebuild `resolved` from the stored order, filling the gaps: unknown ids
     * dropped, separators kept in place, native cells and enabled plugins
     * absent from the file appended in default order.
     */
    function rebuild() {
        var stored = root.readLayout();
        var out = [];
        var seenNative = {};
        var seenPlugin = {};
        for (var i = 0; i < stored.length; i++) {
            var e = stored[i];
            if (!e) continue;
            var kind = e.kind;
            var id = e.id;
            if (kind === "sep") {
                out.push({ kind: "sep" });
            } else if (kind === "cell" && root.nativeOrder.indexOf(id) >= 0 && !seenNative[id]) {
                out.push({ kind: "cell", id: id });
                seenNative[id] = true;
            } else if (kind === "plugin" && root.pluginActive(id) && !seenPlugin[id]) {
                out.push({ kind: "plugin", id: id });
                seenPlugin[id] = true;
            }
        }
        for (var n = 0; n < root.nativeOrder.length; n++) {
            var nid = root.nativeOrder[n];
            if (!seenNative[nid]) {
                out.push({ kind: "cell", id: nid });
                seenNative[nid] = true;
            }
        }
        for (var p = 0; p < root.plugins.length; p++) {
            var pid = root.plugins[p].id;
            if (!seenPlugin[pid]) {
                out.push({ kind: "plugin", id: pid });
                seenPlugin[pid] = true;
            }
        }
        root.resolved = out;
    }

    /** Persist the current resolved order as the layout file. */
    function save() {
        var out = [];
        for (var i = 0; i < root.resolved.length; i++) {
            var e = root.resolved[i];
            out.push(e.kind === "sep" ? { kind: "sep" } : { kind: e.kind, id: e.id });
        }
        store.setText(JSON.stringify(out));
    }

    /**
     * Move the entry at `from` to `to` in the resolved order and persist. The
     * removal-then-insertion dance is DockPins.move's, so all four directions
     * land correctly: move(0,2) and move(3,1) on [A,B,C,D] give [B,C,A,D] and
     * [A,D,B,C] with no index fixup.
     */
    function move(from, to) {
        var n = root.resolved.length;
        if (n < 2) return;
        from = Math.max(0, Math.min(n - 1, Math.trunc(from)));
        to = Math.max(0, Math.min(n - 1, Math.trunc(to)));
        if (from === to) return;
        var next = root.resolved.slice();
        next.splice(to, 0, next.splice(from, 1)[0]);
        root.resolved = next;
        root.save();
    }

    function insertSeparator(at) {
        at = Math.max(0, Math.min(root.resolved.length, Math.trunc(at)));
        var next = root.resolved.slice();
        next.splice(at, 0, { kind: "sep" });
        root.resolved = next;
        root.save();
    }

    function removeSeparator(at) {
        at = Math.trunc(at);
        if (at < 0 || at >= root.resolved.length || root.resolved[at].kind !== "sep")
            return;
        var next = root.resolved.slice();
        next.splice(at, 1);
        root.resolved = next;
        root.save();
    }

    /** Drop the stored order and rebuild the default one. */
    function reset() {
        store.setText("[]");
        root.rebuild();
    }
}