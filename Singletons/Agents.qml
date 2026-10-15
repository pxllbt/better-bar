pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * AGENTS -- which workspaces have a coding agent on them, and what state it is
 * in, so the bar can badge them.
 *
 * The write side is scripts/agents.sh: one small JSON file per session, which
 * any agent can drive from a hook without knowing anything about the bar. This
 * is the read side, and it holds no state of its own -- it watches the directory
 * and derives everything, so a reporter that dies mid-session cannot leave a
 * badge stuck here.
 *
 * Three states, in ascending order of wanting your attention: `working` (a
 * spinner), `done` (a check), `waiting` (a pulsing "!"). A workspace with more
 * than one agent shows the one that wants you most, because a workspace that
 * needs you is the only one whose badge is worth interrupting you for.
 *
 * Sessions are matched to a workspace by pid: a session that names one of the
 * terminal pids Hyprland reports is on that terminal's workspace. A session with
 * no pid, or one whose pid is no longer a terminal, is unattributed and left
 * out rather than guessed at.
 */
Singleton {
    id: root

    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
        || (Quickshell.env("HOME") + "/.local/state")) + "/better/agents"

    readonly property string agentScript: Config.hyprPath("scripts", "agents.sh")

    /** Every live session, newest write last. Read from disk, never cached. */
    property var sessions: []

    /** The strip's own refresh cadence while a badge is live, else its idle one. */
    readonly property int pollMs: root.urgent > 0 ? 1000 : 5000

    // A watched directory is a single object rather than one per session, so a
    // reporter starting or finishing costs nothing to observe.
    FileView {
        id: dir
        path: root.stateDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.reload()
        onLoaded: root.reload()
        onLoadFailed: root.sessions = []
    }

    Timer {
        interval: root.pollMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.reload()
    }

    Process {
        id: reader
        // `agents.sh list` is the read side of the same script the reporters
        // write through, so there is exactly one place that knows the on-disk
        // shape -- and it already emits a single valid JSON array. Reading the
        // files here instead meant re-implementing that parse, and parsing the
        // pretty-printed files line by line silently yielded nothing.
        command: ["sh", "-c", "\"$1\" list; printf '[[[]]]\\n'; hyprctl clients -j 2>/dev/null"
            , "_", root.agentScript]
        stdout: StdioCollector {
            onStreamFinished: {
                var text = this.text;
                var cut = text.lastIndexOf("[[[]]]");
                if (cut < 0)
                    return;
                var sessions = [];
                var clients = [];
                try { sessions = JSON.parse(text.slice(0, cut).trim() || "[]"); } catch (e) { }
                try { clients = JSON.parse(text.slice(cut + 7).trim() || "[]"); } catch (e) { }
                root.apply(sessions, clients);
            }
        }
    }

    // ---- derived views ----------------------------------------------------

    /** pid -> the workspace that terminal is on, from Hyprland's own view. */
    property var pidWorkspace: ({})

    /**
     * workspace name -> the badge it should show. Only `waiting` and `working`
     * are recorded: a finished agent has nothing left to say, and leaving its
     * check on the bar forever would be noise.
     */
    readonly property var badges: {
        var out = {};
        for (var i = 0; i < root.sessions.length; i++) {
            var s = root.sessions[i];
            if (!s || (s.status !== "waiting" && s.status !== "working"))
                continue;
            var ws = root.workspaceOf(s);
            if (!ws)
                continue;
            if (out[ws] !== "waiting")
                out[ws] = s.status;
        }
        return out;
    }

    /** How many workspaces are waiting on you. The bar can pulse on this. */
    readonly property int urgent: {
        var n = 0;
        for (var k in root.badges) {
            if (root.badges[k] === "waiting")
                n++;
        }
        return n;
    }

    /** The badge for one workspace, or "" for none. */
    function badgeFor(workspace) {
        return root.badges[String(workspace || "")] || "";
    }

    function workspaceOf(session) {
        var pids = String((session && session.pids) || "");
        if (!pids.length)
            return "";
        var list = pids.split(",");
        for (var i = 0; i < list.length; i++) {
            var p = list[i].trim();
            if (p && root.pidWorkspace[p])
                return root.pidWorkspace[p];
        }
        return "";
    }

    // ---- internals --------------------------------------------------------

    function apply(sessions, clients) {
        root.sessions = sessions || [];
        var map = {};
        for (var i = 0; i < (clients || []).length; i++) {
            var c = clients[i];
            // A workspace lives on the focused workspace of its monitor.
            if (c && c.workspace && c.workspace.name)
                map[String(c.pid)] = c.workspace.name;
        }
        root.pidWorkspace = map;
    }

    function reload() {
        reader.running = true;
    }

    Component.onCompleted: root.reload()
}
