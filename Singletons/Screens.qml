pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

/**
 * SCREENS -- the model behind the monitor-layout surface.
 *
 * Holds the read-only `live` snapshot (hyprctl monitors / monitors all /
 * workspaces), the `draft` the canvas and editor bind to, and the saved
 * `profiles`. Polling runs only while `open` is true; a Hyprland event on
 * monitoradded / monitorremoved / configreloaded refreshes on demand, the same
 * three events components/Workspaces.qml already keys on.
 *
 * applyDraft ships the draft through `scripts/screens.sh apply` (one batched
 * hyprctl round-trip); persist rewrites the output's own monitors.lua block
 * there; rescue re-applies the last-good layout. The pure helpers at the bottom
 * (identityOf / pairByIdentity / buildDraft / refit / refuseApply) carry the
 * layout logic the unit tests lift out of this file and must stay free of QML
 * coupling.
 */
Singleton {
    id: root

    property bool open: false
    property var live: []
    property var draft: []
    property var profiles: []
    property int focusIndex: -1
    property string status: ""

    readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better/screens.json"
    readonly property string scriptPath: Config.hyprPath("scripts", "screens.sh")

    /**
     * The reflowed footprint of every draft screen, as
     * [{ name, x, y, width, height, ew, eh, scale, transform }]. It recomputes
     * whenever the draft changes, which is what makes a scale or rotation edit
     * move the neighbours' cards: the arrangement is the layout's target state,
     * so repositioning is a consequence of the footprint changing, not a second
     * bookkeeping step that can drift from it.
     */
    readonly property var layout: refit(draft)

    // The spec hyprctl wants: a desc: rule when the panel reports a make/model,
    // otherwise the bare connector name.
    function outputFor(mon) {
        if (mon && mon.make && mon.model && mon.make !== "" && mon.model !== "")
            return "desc:" + String(mon.make) + " " + String(mon.model);
        return (mon && mon.name) ? String(mon.name) : "";
    }

    // Flatten one monitor into the slim shape the surface binds to, merging the
    // modes/disabled from `monitors all -j` and the workspace chips from `workspaces -j`.
    function parseLive(mon, allMon, wsByMonitor) {
        if (!mon || !mon.name)
            return null;
        var a = allMon || mon;
        var modes = [];
        var raw = a.availableModes || mon.availableModes || [];
        for (var m = 0; m < raw.length; m++) {
            var p = parseMode(raw[m]);
            if (p)
                modes.push(p);
        }
        var ws = wsByMonitor ? wsByMonitor[mon.name] || [] : [];
        return {
            name: mon.name,
            output: outputFor(mon),
            identity: identityOf(mon),
            make: mon.make || "",
            model: mon.model || "",
            serial: mon.serial || "",
            width: mon.width, height: mon.height,
            refresh: (mon.refreshRate || 0) ? Math.round(mon.refreshRate) : 0,
            // The active mode, in the exact string the writer's mode field
            // takes. Hyprland reports it; deriving it from the geometry is the
            // fallback for a build that does not. Without it the editor had
            // nothing to show and nothing to send back.
            mode: mon.mode || (mon.width
                ? mon.width + "x" + mon.height + "@" + Math.round(mon.refreshRate || 0)
                : "preferred"),
            position: String(mon.x || 0) + "x" + String(mon.y || 0),
            scale: mon.scale, x: mon.x, y: mon.y,
            transform: mon.transform || 0,
            vrr: mon.vrr, mirror: mon.mirror || "",
            activeWsName: (mon.activeWorkspace && mon.activeWorkspace.name !== undefined)
                ? String(mon.activeWorkspace.name) : "",
            // `enabled` is the field everything else keys on -- the canvas dims a
            // screen that is off, enabledCount drives the last-screen refusal and
            // the toggle reflects it -- so it is set here rather than left to be
            // derived per consumer. Omitting it made every screen read as off:
            // an invisible canvas and an apply that was always refused.
            enabled: !a.disabled,
            disabled: !!a.disabled,
            modes: modes,
            workspaces: ws
        };
    }

    function parseMode(raw) {
        if (typeof raw !== "string")
            return null;
        var m = raw.match(/^(\d+)x(\d+)@([\d.]+)Hz$/);
        if (!m)
            return null;
        return { w: parseInt(m[1], 10), h: parseInt(m[2], 10), hz: Math.round(parseFloat(m[3])), raw: raw };
    }

    function deepCopy(x) {
        return JSON.parse(JSON.stringify(x));
    }

    // Build the Task 1 layout JSON the writer consumes, projecting the draft down
    // to the writer schema (output/mode/position/scale/transform/mirror/enabled).
    function draftToLayout(d) {
        var screens = [];
        for (var i = 0; i < d.length; i++) {
            var s = d[i];
            if (!s.output)
                continue;
            screens.push({
                output: s.output,
                mode: s.mode,
                position: s.position,
                scale: s.scale,
                transform: s.transform,
                mirror: s.mirror,
                enabled: !!s.enabled
            });
        }
        return JSON.stringify({ version: 1, screens: screens });
    }

    // ---- lifecycle ----

    function refresh() {
        if (!open)
            return;
        refreshProc.running = true;
    }

    function applyDraft() {
        if (!refuseApply(draft)) {
            status = "refused: every screen is disabled";
            return;
        }
        var layout = draftToLayout(draft);
        status = "";
        runner.command = ["sh", "-c", 'printf "%s" "$1" | "$0" apply', scriptPath, layout];
        runner.running = true;
    }

    function persist() {
        var layout = draftToLayout(draft);
        status = "";
        runner.command = ["sh", "-c", 'printf "%s" "$1" | "$0" persist', scriptPath, layout];
        runner.running = true;
    }

    function rescue() {
        status = "";
        runner.command = ["sh", "-c", '"$0" rescue', scriptPath];
        runner.running = true;
    }

    function profileId() {
        return "p" + Math.round(Math.random() * 1e12);
    }

    function readProfiles() {
        var raw = profileFile.text();
        try {
            var v = JSON.parse(raw || "[]");
            if (Array.isArray(v))
                profiles = v;
        } catch (e) { }
    }

    function writeProfiles() {
        profileFile.setText(JSON.stringify({ version: 1, profiles: profiles }, null, 2));
    }

    function saveProfile(name) {
        var prof = { id: profileId(), name: name, saved: Math.round(Date.now() / 1000), screens: [] };
        for (var i = 0; i < draft.length; i++) {
            var s = draft[i];
            prof.screens.push({
                output: s.output, identity: s.identity,
                mode: s.mode, position: s.position, scale: s.scale,
                transform: s.transform, mirror: s.mirror, enabled: !!s.enabled
            });
        }
        var next = profiles.slice();
        next.push(prof);
        profiles = next;
        writeProfiles();
    }

    function loadProfile(id) {
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i].id === id) {
                var r = buildDraft(live, profiles[i]);
                if (r.present < r.total) {
                    status = "profile not fully present: " + r.present + " of " + r.total + " screens";
                    return false;
                }
                draft = r.draft;
                return true;
            }
        }
        return false;
    }

    /** Drop a saved profile. The draft is untouched. */
    function forgetProfile(id) {
        var next = [];
        var dropped = false;
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i] && profiles[i].id === id)
                dropped = true;
            else if (profiles[i])
                next.push(profiles[i]);
        }
        if (!dropped)
            return false;
        profiles = next;
        writeProfiles();
        return true;
    }

    // ---- draft editing ----
    // Everything here mutates `draft` only. Screens.live is never written, so a
    // patch that Hyprland rejects leaves the canvas and reality in agreement --
    // which is the whole reason the draft exists as a separate property.

    function focusScreen() {
        if (root.focusIndex < 0 || root.focusIndex >= draft.length)
            return null;
        return draft[root.focusIndex];
    }

    function enabledCount() {
        var n = 0;
        for (var i = 0; i < draft.length; i++) {
            if (draft[i] && draft[i].enabled)
                n++;
        }
        return n;
    }

    function setFocus(i) {
        root.focusIndex = (i >= 0 && i < draft.length) ? i : -1;
    }

    /** Cycle focus to the next screen. */
    function focusNext() {
        if (!draft.length)
            return;
        setFocus((root.focusIndex + 1) % draft.length);
    }

    /**
     * Patch fields on one draft screen, reflow the layout so nothing overlaps,
     * and apply once. Returns false when the index or patch is unusable.
     */
    function updateDraft(i, patch) {
        if (i < 0 || i >= draft.length || !patch)
            return false;
        var next = draft.slice();
        var scr = Object.assign({}, next[i] || {});
        var keys = Object.keys(patch);
        for (var k = 0; k < keys.length; k++) {
            if (patch[keys[k]] !== undefined)
                scr[keys[k]] = patch[keys[k]];
        }
        next[i] = scr;
        draft = next;
        refit(draft);
        applyDraft();
        return true;
    }

    /** Arrow-key nudge: step by 8, or by 1 while Shift is held for fine work. */
    function nudge(dx, dy, fine) {
        var scr = focusScreen();
        if (!scr)
            return false;
        var step = fine ? 1 : 8;
        var x = Math.max(0, (scr.x || 0) + dx * step);
        var y = Math.max(0, (scr.y || 0) + dy * step);
        return updateDraft(root.focusIndex, { position: x + "x" + y });
    }

    /**
     * Ctrl-snap: flush the focused screen against the edge of its nearest
     * neighbour rather than nudging by a step, so a hand-tightened layout does
     * not need pixel dragging.
     */
    function snapEdge(dir) {
        var scr = focusScreen();
        if (!scr)
            return false;
        var boxes = refit(draft);
        var mine = null;
        for (var i = 0; i < boxes.length; i++) {
            if (boxes[i].name === scr.name)
                mine = boxes[i];
        }
        if (!mine)
            return false;
        var x = Math.max(0, scr.x || 0);
        var y = Math.max(0, scr.y || 0);
        for (var j = 0; j < boxes.length; j++) {
            var other = boxes[j];
            if (other.name === scr.name)
                continue;
            if (dir === "left")
                x = Math.min(x, other.x - mine.ew);
            else if (dir === "right")
                x = Math.max(x, other.x + other.ew);
            else if (dir === "up")
                y = Math.min(y, other.y - mine.eh);
            else if (dir === "down")
                y = Math.max(y, other.y + other.eh);
        }
        return updateDraft(root.focusIndex, { position: Math.max(0, x) + "x" + Math.max(0, y) });
    }

    /** The live field value a screen diverged from, for a per-field reset. */
    function liveValue(name, field) {
        for (var i = 0; i < live.length; i++) {
            if (live[i] && live[i].name === name)
                return live[i][field];
        }
        return undefined;
    }

    function resetField(field) {
        var scr = focusScreen();
        if (!scr)
            return false;
        var v = liveValue(scr.name, field);
        if (v === undefined)
            return false;
        var patch = {};
        patch[field] = v;
        return updateDraft(root.focusIndex, patch);
    }

    // ---- pure helpers (lifted by lib/screens-model.test.mjs) ----
    // These hold the layout rules the unit tests pin and must not touch QML state.

    function identityOf(mon) {
        if (mon && mon.serial != null && mon.serial !== "")
            return String(mon.serial);
        if (mon && mon.make != null && mon.make !== "" && mon.model != null && mon.model !== "")
            return "desc:" + String(mon.make) + " " + String(mon.model);
        return mon ? String(mon.name) : "";
    }

    // Match profile screens onto live screens by identity (serial -> desc -> name),
    // not by connector: a cable moved to another port still pairs. Reports how many
    // profile screens were found so a partial match can be refused.
    function pairByIdentity(live, profileScreens) {
        var matched = [];
        var present = 0;
        for (var pi = 0; pi < profileScreens.length; pi++) {
            var ps = profileScreens[pi];
            var hit = -1;
            for (var li = 0; li < live.length; li++) {
                if (live[li].identity === ps.identity) {
                    hit = li;
                    break;
                }
            }
            if (hit >= 0) {
                matched.push({ profile: ps, live: live[hit] });
                present++;
            } else {
                matched.push({ profile: ps, live: null });
            }
        }
        return { matched: matched, present: present, total: profileScreens.length, full: present === profileScreens.length };
    }

    // Start matched screens from the profile (their persisted mode/scale/etc.) and
    // leave unmatched live screens on their live values. Absent profile screens are
    // dropped -- they cannot be applied.
    function buildDraft(live, profile) {
        var pairing = pairByIdentity(live, profile.screens);
        var draft = [];
        var seen = [];
        for (var i = 0; i < pairing.matched.length; i++) {
            var entry = pairing.matched[i];
            var ps = entry.profile;
            if (entry.live) {
                seen.push(entry.live.name);
                var s = entry.live;
                draft.push({
                    name: s.name, output: s.output, identity: s.identity,
                    make: s.make, model: s.model, serial: s.serial,
                    width: s.width, height: s.height, refresh: s.refresh,
                    scale: ps.scale !== undefined ? ps.scale : s.scale,
                    x: s.x, y: s.y,
                    transform: ps.transform !== undefined ? ps.transform : s.transform,
                    vrr: s.vrr, mirror: ps.mirror !== undefined ? ps.mirror : s.mirror,
                    disabled: s.disabled, modes: s.modes, workspaces: s.workspaces,
                    mode: ps.mode !== undefined ? ps.mode : s.mode,
                    position: ps.position !== undefined ? ps.position : s.position,
                    enabled: ps.enabled !== undefined ? ps.enabled : s.enabled
                });
            }
        }
        for (var j = 0; j < live.length; j++) {
            var inProfile = false;
            for (var k = 0; k < seen.length; k++) {
                if (seen[k] === live[j].name) {
                    inProfile = true;
                    break;
                }
            }
            if (!inProfile) {
                var ls = live[j];
                draft.push({
                    name: ls.name, output: ls.output, identity: ls.identity,
                    make: ls.make, model: ls.model, serial: ls.serial,
                    width: ls.width, height: ls.height, refresh: ls.refresh,
                    scale: ls.scale, x: ls.x, y: ls.y, transform: ls.transform,
                    vrr: ls.vrr, mirror: ls.mirror, disabled: ls.disabled,
                    modes: ls.modes, workspaces: ls.workspaces,
                    mode: ls.mode, position: ls.position,
                    enabled: ls.enabled !== undefined ? ls.enabled : !ls.disabled
                });
            }
        }
        return { draft: draft, present: pairing.present, total: pairing.total };
    }

    // Recompute each screen's footprint after a scale or transform change and
    // pack them left-to-right (in name order) so no two overlap. Returns the new
    // footprints; also mutates each screen's x/y in the draft.
    function refit(draft) {
        var items = [];
        for (var i = 0; i < draft.length; i++) {
            var s = draft[i];
            var w = s.width, h = s.height;
            if (s.transform === 1 || s.transform === 3) {
                var sw = w; w = h; h = sw;
            }
            items.push({ s: s, ew: w * s.scale, eh: h * s.scale });
        }
        items.sort(function (a, b) {
            if (a.s.name < b.s.name) return -1;
            if (a.s.name > b.s.name) return 1;
            return 0;
        });
        var cursor = 0;
        for (var j = 0; j < items.length; j++) {
            items[j].s.x = cursor;
            items[j].s.y = 0;
            cursor += items[j].ew;
        }
        var out = [];
        for (var k = 0; k < items.length; k++) {
            var it = items[k];
            out.push({
                name: it.s.name, x: it.s.x, y: it.s.y,
                width: it.s.width, height: it.s.height,
                ew: it.ew, eh: it.eh,
                scale: it.s.scale, transform: it.s.transform
            });
        }
        return out;
    }

    // The same zero-enabled refusal the writer enforces: returns true when the set
    // may be applied, false when it would blank every screen.
    function refuseApply(draft) {
        var enabled = 0;
        for (var i = 0; i < draft.length; i++) {
            if (draft[i].enabled)
                enabled++;
        }
        return enabled > 0;
    }

    // ---- IO / wiring ----

    onOpenChanged: {
        if (open) {
            readProfiles();
            refresh();
        }
    }

    Connections {
        target: Hyprland
        enabled: root.open
        function onRawEvent(event) {
            if (event.name === "monitoradded" || event.name === "monitorremoved" || event.name === "configreloaded")
                root.refresh();
        }
    }

    FileView {
        id: profileFile
        path: root.stateFile
        blockLoading: false
        atomicWrites: true
        printErrors: false
    }

    Process {
        id: refreshProc
        command: ["sh", "-c", "hyprctl monitors -j; printf '@@@'; hyprctl monitors all -j; printf '@@@'; hyprctl workspaces -j"]
        stdout: StdioCollector {
            onStreamFinished: {
                var parts = this.text.split("@@@");
                var liveArr = [];
                try { liveArr = JSON.parse(parts[0] || "[]"); } catch (e) {}
                var allArr = [];
                try { allArr = JSON.parse(parts[1] || "[]"); } catch (e) {}
                var wsArr = [];
                try { wsArr = JSON.parse(parts[2] || "[]"); } catch (e) {}
                var wsByMonitor = {};
                for (var w = 0; w < wsArr.length; w++) {
                    var wm = wsArr[w].monitor;
                    if (!wsByMonitor[wm])
                        wsByMonitor[wm] = [];
                    wsByMonitor[wm].push({ id: wsArr[w].id, name: wsArr[w].name });
                }
                var allMap = {};
                for (var a = 0; a < allArr.length; a++)
                    if (allArr[a] && allArr[a].name)
                        allMap[allArr[a].name] = allArr[a];
                var parsed = [];
                for (var n = 0; n < liveArr.length; n++) {
                    var scr = parseLive(liveArr[n], allMap[liveArr[n].name], wsByMonitor[liveArr[n].name]);
                    if (scr)
                        parsed.push(scr);
                }
                root.live = parsed;
                root.draft = deepCopy(parsed);
                root.focusIndex = parsed.length > 0 ? 0 : -1;
                root.status = "";
            }
        }
    }

    Process {
        id: runner
        onRunningChanged: {
            if (!running)
                root.refresh();
        }
        stdout: StdioCollector {
            onStreamFinished: {
                var t = this.text;
                if (t && t.trim().length)
                    root.status = t.trim();
            }
        }
    }
}
