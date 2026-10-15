import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

import "../lib/keybinds.js" as KeybindsModel

/**
 * Native Better Bar keybind manager state.
 *
 * The existing Omarchy backend stays the source of truth for Hyprland's
 * bindings.lua parsing, backup, writing and conflict detection. This singleton
 * is only the bar side of that contract: it reads the model when the surface is
 * opened, filters and shapes it in the tested JS module, and runs one action at a
 * time when the user asks for one.
 *
 * The optimisation constraint is deliberately narrow: no keybind polling lives
 * here. A list of 180+ bindings is read once when the surface opens and again
 * only after a write, never on a timer inside the long-lived shell.
 */
Item {
    id: root

    /** True only while the Keybinds settings surface is open. */
    property bool surfaceOpen: false

    /** active | modified | conflicts | catalog */
    property string tab: "active"

    /** Bound to the surface's own search field. */
    property string query: ""

    /** Backend model, normalized through lib/keybinds.js. */
    property var model: KeybindsModel.parseModel("{}")

    property bool busy: false
    property string busyAction: ""
    property string statusMessage: ""
    property string lastError: ""

    property bool listRunning: false
    property bool listRequested: false

    readonly property string backendPath: Quickshell.env("HOME")
        + "/.config/omarchy/plugins/meviusisback.keybinds/backend/keybinds_manager.py"

    readonly property string baseTitle: "python3"

    readonly property var allRows: KeybindsModel.rowsFor(root.model, root.tab)

    readonly property var filteredRows: {
        var rows = root.allRows;
        var q = root.query.trim();
        if (q.length === 0)
            return rows;
        return rows.filter(function (row) {
            return KeybindsModel.matches(row, q);
        });
    }

    readonly property var totals: root.model.totals || ({
        total_active: 0,
        total_modified: 0,
        total_conflicts: 0,
        total_catalog: 0
    })

    /**
     * Ask for a read. The process starts from the `running` expression, not
     * from a timer, and stops being requested once the read lands.
     */
    function refresh() {
        root.listRequested = true;
        root.lastError = "";
        root.statusMessage = "Reading Hyprland keybindings…";
    }

    function applyList(text) {
        try {
            root.model = KeybindsModel.parseModel(String(text || ""));
            root.statusMessage = root.totals.total_active + " active · "
                + root.totals.total_modified + " custom · "
                + root.totals.total_conflicts + " conflicts";
            root.lastError = "";
        } catch (e) {
            root.lastError = "could not parse the keybind list";
        }
    }

    function runAction(args, label) {
        if (root.busy)
            return false;
        if (!args || args.length === 0)
            return false;

        actionProc.command = [root.baseTitle, root.backendPath].concat(args);
        actionProc.running = true;
        root.busy = true;
        root.busyAction = label || "working";
        root.statusMessage = label + "…";
        return true;
    }

    function disable(key) {
        return root.runAction(["disable", String(key || "")], "Disabling binding");
    }

    function enable(key) {
        return root.runAction(["enable", String(key || "")], "Enabling binding");
    }

    function reset(key, defaultKey) {
        return root.runAction(["reset", String(key || ""), String(defaultKey || "")], "Resetting binding");
    }

    function setBinding(key, description, command, oldKey) {
        return root.runAction([
            "set",
            String(key || ""),
            String(description || ""),
            String(command || ""),
            "",
            String(oldKey || "")
        ], "Saving binding");
    }

    function applyActionOutput(text, code) {
        var ok = code === 0;
        var message = "";
        try {
            var parsed = JSON.parse(String(text || ""));
            if (parsed && typeof parsed === "object") {
                ok = parsed.success === true;
                message = String(parsed.error || parsed.message || "");
            }
        } catch (e) {
            // A non-JSON result is not necessarily a failure: the backend prints
            // plain text in some paths, but the exit code still carries truth.
        }

        if (ok) {
            root.lastError = "";
            root.statusMessage = "Keybindings updated";
            root.refresh();
        } else {
            root.lastError = message.length > 0 ? message : "keybind action failed";
            root.statusMessage = "Keybind action failed";
        }
    }

    Process {
        id: actionProc
        running: false
        command: []
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: actionProc.actionOutput = String(text || "").trim()
        }
        property string actionOutput: ""
        onExited: function (code) {
            root.busy = false;
            root.busyAction = "";
            root.applyActionOutput(actionProc.actionOutput, code);
            actionProc.actionOutput = "";
        }
    }

    Process {
        id: listProc
        running: root.surfaceOpen && root.listRequested && !root.busy
        command: [root.baseTitle, root.backendPath, "list"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyList(String(text || ""));
        }

        onStarted: root.listRunning = true

        onExited: function (code) {
            root.listRunning = false;
            root.listRequested = false;
            if (code !== 0)
                root.lastError = "keybind manager is not reachable";
            root.statusMessage = code === 0 ? root.statusMessage : root.statusMessage;
        }
    }

    Component.onCompleted: {
        // Keep the singleton inert at startup: the list process only runs once
        // the settings surface is actually on screen.
        root.surfaceOpen = false;
    }
}
