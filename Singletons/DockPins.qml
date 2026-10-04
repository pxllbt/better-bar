pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * 常 Dock pins: the ordered list of desktop-entry ids pinned to the bottom
 * dock, shared by every monitor's DockBar and by the launcher's right-click
 * pin action. Persisted as a plain JSON array in the state dir
 * (better/dock-pins.json) through a FileView, so pinning survives restarts
 * and is safe to touch from any surface.
 */
Singleton {
    id: root

    readonly property string pinsFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better/dock-pins.json"

    property var pins: []

    FileView {
        id: store
        path: root.pinsFile
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Component.onCompleted: root.load()

    function load() {
        var raw = store.text();
        try {
            var v = raw && raw.length > 0 ? JSON.parse(raw) : [];
            root.pins = Array.isArray(v) ? v : [];
        } catch (e) {
            root.pins = [];
        }
    }

    function save() {
        store.setText(JSON.stringify(root.pins));
    }

    function has(id) {
        return root.pins.indexOf(id) >= 0;
    }

    /**
     * Move the pin at `from` to `to`, both indices into the pins array. This is
     * the one write path for a drag-reorder in the dock: the array is the dock's
     * order of record, so a drop rewrites it and every monitor's DockBar (and
     * the launcher's pin badge) follows through the `pins` change.
     *
     * Removing first and inserting at `to` in the shortened array is what makes
     * all four directions land correctly — move(0,2) and move(3,1) on
     * [A,B,C,D] give [B,C,A,D] and [A,D,B,C] with no index fixup.
     */
    function move(from, to) {
        var n = root.pins.length;
        if (n < 2)
            return;
        from = Math.max(0, Math.min(n - 1, Math.trunc(from)));
        to = Math.max(0, Math.min(n - 1, Math.trunc(to)));
        if (from === to)
            return;
        var next = root.pins.slice();
        next.splice(to, 0, next.splice(from, 1)[0]);
        root.pins = next;
        root.save();
    }

    function toggle(id) {
        if (!id) return;
        var next = root.pins.slice();
        var i = next.indexOf(id);
        if (i >= 0) next.splice(i, 1); else next.push(id);
        root.pins = next;
        root.save();
    }
}