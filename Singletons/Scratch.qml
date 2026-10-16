pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Scratchpad model: a shelf of plain-text notes, one file per note, so the
 * pill's scratchpad and any editor see the same bytes. Notes live in
 * `better/notes` under the state dir and the title IS the filename -- renaming
 * a note is an `mv`, and a note with no extension surprise stays openable with
 * `cat`. Bodies are read on selection and written back through a debounced
 * autosave, so nothing is ever held only in QML memory.
 *
 * Pinned notes sort above the rest and carry their flag in a sidecar JSON
 * (scratch-pins.json) rather than in the body, which keeps the files themselves
 * portable -- a note dropped in by hand arrives unpinned with no metadata to
 * strip. `scan()` is the single source of the list: `find` reports name, mtime
 * and size in one pass, pins are merged in, and the result is sorted pinned
 * first then newest, so the surface never has to re-sort.
 *
 * Writing goes through `printf > tmp && mv` rather than a FileView: the save
 * path changes with every selection, and re-pointing a FileView races its own
 * pending load. A shell replace is atomic by rename and has no such window.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/better"
    readonly property string notesDir: stateDir + "/notes"
    readonly property string pinsFile: stateDir + "/scratch-pins.json"

    /** Bodies are edited as raw text, not rendered. */
    readonly property string ext: ".md"

    /**
     * The scanner only matches `*.md`, so the atomic-write staging file is named
     * to stay outside that glob. If it ever matched, an interrupted save would
     * leave the temp file listed as a note.
     */
    readonly property string tmpName: ".bettersave"

    /**
     * Sorted, pinned-first. Entries are `{ slug, title, path, pinned, mtime,
     * sizeLabel, heading, preview }`.
     */
    property var notes: []
    readonly property bool any: notes.length > 0

    property string currentSlug: ""
    readonly property var current: {
        for (var i = 0; i < root.notes.length; i++)
            if (notes[i].slug === root.currentSlug)
                return notes[i];
        return null;
    }

    /** Editor buffer. Owned by the surface while it is open, flushed on autosave. */
    property string draft: ""
    property bool dirty: false

    /**
     * Bumped by every user keystroke. A body read only adopts its result if this
     * is unchanged since the read started.
     */
    property int editEpoch: 0

    function type(text: string) {
        root.draft = text;
        root.dirty = true;
        root.editEpoch++;
    }

    property bool surfaceOpen: false

    property var pins: ({})

    signal bodyLoaded(string slug, string body)

    FileView {
        id: pinStore
        path: root.pinsFile
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Component.onCompleted: {
        root.loadPins();
        root.scan();
    }

    /** Re-read the note list. One find pass; pinned-first then newest. */
    function scan() {
        scanProc.running = true;
    }

    Process {
        id: scanProc
        command: ["sh", "-c",
            "d=\"$1\"; [ -d \"$d\" ] || exit 0; for f in \"$d\"/*.md; do [ -f \"$f\" ] || continue; first=\"$(head -n 1 -- \"$f\" | tr '\\t\\r\\n' '   ')\"; rest=\"$(tail -n +2 -- \"$f\" | head -c 240 | tr '\\t\\r\\n' '   ')\"; printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$(stat -c %Y -- \"$f\")\" \"$(stat -c %s -- \"$f\")\" \"$first\" \"$rest\" \"${f##*/}\"; done",
            "_", root.notesDir]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.split("\n");
                var out = [];
                var now = Date.now() / 1000;
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i])
                        continue;
                    var cols = lines[i].split("\t");
                    if (cols.length < 5)
                        continue;
                    var mtime = parseFloat(cols[0]);
                    var size = parseInt(cols[1]);
                    var first = root.squeeze(cols[2]);
                    var rest = root.squeeze(cols[3]);
                    var name = cols.slice(4).join("\t");
                    if (!name.endsWith(root.ext))
                        continue;
                    var slug = name.substring(0, name.length - 3);
                    if (!slug)
                        continue;
                    var age = Math.max(0, now - mtime);
                    var heading = root.headingOf(first, rest);
                    out.push({
                        slug: slug,
                        title: slug,
                        path: root.notesDir + "/" + name,
                        pinned: root.pins[slug] === true,
                        mtime: mtime,
                        heading: heading,
                        preview: heading ? rest : (first ? (rest ? first + " " + rest : first) : rest),
                        sizeLabel: size < 1024 ? size + " B" : (size / 1024).toFixed(size < 10240 ? 1 : 0) + " KiB",
                        age: age < 90 ? "now" : (age < 5400 ? Math.round(age / 60) + "m"
                              : (age < 172800 ? Math.round(age / 3600) + "h" : Math.round(age / 86400) + "d"))
                    });
                }
                out.sort(function (a, b) {
                    if (a.pinned !== b.pinned)
                        return a.pinned ? -1 : 1;
                    return b.mtime - a.mtime;
                });
                root.notes = out;

                if (root.currentSlug && !root.hasSlug(root.currentSlug))
                    root.select(out.length ? out[0].slug : "");
            }
        }
    }

    function hasSlug(slug: string): bool {
        for (var i = 0; i < root.notes.length; i++)
            if (root.notes[i].slug === slug)
                return true;
        return false;
    }

    function squeeze(text: string): string {
        return (text || "").replace(/ +/g, " ").trim();
    }

    function headingOf(first: string, rest: string): string {
        var h = (first || "").replace(/^#+\s*/, "").trim();
        if (h && h !== first)
            return h;
        if (h && rest && h.length <= 64)
            return h;
        return "";
    }

    function isEmpty(slug: string): bool {
        if (!slug)
            return true;
        if (slug === root.currentSlug)
            return root.draft.trim() === "";
        for (var i = 0; i < root.notes.length; i++)
            if (root.notes[i].slug === slug)
                return root.notes[i].sizeLabel === "0 B";
        return false;
    }

    function sanitize(title: string): string {
        var s = (title || "").replace(/[\/\\\x00-\x1f\x7f]/g, " ").replace(/\s+/g, " ").trim();
        while (s.startsWith("."))
            s = s.substring(1).trim();
        if (s.length > 96)
            s = s.substring(0, 96).trim();
        return s;
    }

    function create(title: string): string {
        var slug = root.sanitize(title);
        if (!slug)
            return "";
        if (root.hasSlug(slug)) {
            root.select(slug);
            return slug;
        }
        root.notes = root.notes.concat([{
            slug: slug,
            title: slug,
            path: root.notesDir + "/" + slug + root.ext,
            pinned: root.pins[slug] === true,
            mtime: Date.now() / 1000,
            heading: "",
            preview: "",
            sizeLabel: "0 B",
            age: "now"
        }]);
        root.currentSlug = slug;
        root.draft = "";
        root.dirty = false;
        root.readToken++;
        root.bodyLoaded(slug, "");
        mkProc.pending = slug;
        mkProc.command = ["sh", "-c",
            "mkdir -p \"$1\" && : > \"$1/$2.md\"",
            "_", root.notesDir, slug];
        mkProc.running = true;
        return slug;
    }

    Process {
        id: mkProc
        property string pending: ""
        onExited: function (exitCode) {}
    }

    function select(slug: string) {
        root.currentSlug = slug;
        root.draft = "";
        root.dirty = false;
        if (!slug)
            return;
        root.readToken++;
        readProc.token = root.readToken;
        readProc.epoch = root.editEpoch;
        readProc.command = ["sh", "-c", "cat -- \"$1\" 2>/dev/null || true", "_", root.pathFor(slug)];
        readProc.running = true;
    }

    property int readToken: 0

    Process {
        id: readProc
        property int token: 0
        property int epoch: 0
        stdout: StdioCollector {
            onStreamFinished: {
                if (readProc.token !== root.readToken || readProc.epoch !== root.editEpoch)
                    return;
                root.draft = this.text;
                root.dirty = false;
                root.bodyLoaded(root.currentSlug, this.text);
            }
        }
    }

    function pathFor(slug: string): string {
        return slug ? root.notesDir + "/" + slug + root.ext : "/dev/null";
    }

    function save() {
        if (!root.currentSlug || !root.dirty)
            return;
        if (writeProc.running) {
            saveQueued = true;
            return;
        }
        writeProc.written = root.draft;
        writeProc.command = ["sh", "-c",
            "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$1/.bettersave\" && mv -f \"$1/.bettersave\" \"$1/$3.md\"",
            "_", root.notesDir, root.draft, root.currentSlug];
        writeProc.running = true;
    }

    property bool saveQueued: false

    Process {
        id: writeProc
        property string written: ""
        onExited: function (exitCode) {
            if (exitCode !== 0)
                return;
            if (root.draft === writeProc.written)
                root.dirty = false;
            root.scan();
            if (root.saveQueued) {
                root.saveQueued = false;
                root.save();
            }
        }
    }

    function remove(slug: string) {
        if (!slug)
            return;
        if (root.currentSlug === slug) {
            root.currentSlug = "";
            root.draft = "";
            root.dirty = false;
        }
        rmProc.command = ["sh", "-c", "rm -f -- \"$1\"", "_", root.pathFor(slug)];
        rmProc.running = true;
        root.dropPin(slug);
    }

    Process {
        id: rmProc
        onExited: root.scan()
    }

    function rename(fromSlug: string, toTitle: string): bool {
        var slug = root.sanitize(toTitle);
        if (!slug || slug === fromSlug)
            return false;
        if (root.hasSlug(slug))
            return false;
        mvProc.pending = slug;
        mvProc.pendingFrom = fromSlug;
        mvProc.command = ["sh", "-c", "mv -f -- \"$1/$2.md\" \"$1/$3.md\"",
            "_", root.notesDir, fromSlug, slug];
        mvProc.running = true;
        return true;
    }

    Process {
        id: mvProc
        property string pending: ""
        property string pendingFrom: ""
        onExited: function (exitCode) {
            if (exitCode !== 0)
                return;
            var to = mvProc.pending;
            var from = mvProc.pendingFrom;
            if (root.currentSlug === from) {
                root.currentSlug = "";
                root.select(to);
            }
            if (root.pins[from] === true) {
                root.dropPin(from);
                root.setPin(to, true);
            }
            root.scan();
        }
    }

    function clearBody() {
        if (!root.currentSlug)
            return;
        root.draft = "";
        root.dirty = true;
        root.bodyLoaded(root.currentSlug, "");
        root.save();
    }

    function loadPins() {
        var raw = pinStore.text();
        try {
            var v = raw && raw.length > 0 ? JSON.parse(raw) : {};
            root.pins = (v && typeof v === "object" && !Array.isArray(v)) ? v : {};
        } catch (e) {
            root.pins = {};
        }
    }

    function savePins() {
        pinStore.setText(JSON.stringify(root.pins));
    }

    function setPin(slug: string, on: bool) {
        if (!slug)
            return;
        var next = {};
        for (var k in root.pins)
            if (root.pins[k] === true)
                next[k] = true;
        if (on)
            next[slug] = true;
        else
            delete next[slug];
        root.pins = next;
        root.savePins();
        root.scan();
    }

    function togglePin(slug: string) {
        root.setPin(slug, root.pins[slug] !== true);
    }

    function dropPin(slug: string) {
        if (root.pins[slug] === true)
            root.setPin(slug, false);
    }
}
