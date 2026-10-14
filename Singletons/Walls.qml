pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Wallpaper bridge: keeps a warm in-memory snapshot of the wallpaper folder so
 * the wallpaper strip opens instantly without shelling out on demand. A
 * refresh first runs the thumbnail script (generating missing 512px previews
 * and pruning ones whose source is gone), then re-lists the directory
 * newest-first and finally re-reads the state file wallpaper.sh maintains, so
 * `current` always names the wallpaper on screen. Thumbnails land before the
 * list so strip delegates never bind to a not-yet-existing file; a refresh
 * arriving while the pipeline runs sets `pending` and replays once the state
 * lands. Applying routes through wallpaper.sh so the picker shares the exact
 * transition, palette and state path with the random keybind.
 *
 * The folder resolves through one chain, first hit wins: an explicit
 * `wallpaperDir` in flags.json, then the dir wallpaper.sh resolved and wrote
 * to the better-wallpaper-dir state file on its last run, then
 * ~/Pictures/Wallpapers for a first boot before wallpaper.sh init has run.
 *
 * The pipeline is triggered by the wallpaper strip's refresh button, an
 * explicit folder change, or the strip's own warm-up on open: an empty
 * snapshot refreshes fully, otherwise a single `[ -s ]` probe on the newest
 * entry's thumb decides whether any previews are missing and only then
 * rebuilds. A warm snapshot (list + thumbs intact) costs one ~10ms stat on
 * open instead of a full rebuild on every visit.
 *
 * Thumbs live in per-folder subdirectories of the `better/wp-thumbs` cache,
 * each keyed by the md5 of its wallpaper folder's path. Files sharing a basename
 * across folders therefore never clobber each other, and switching folders
 * can't surface a stale thumb from the previous one; each folder's cache is
 * pruned and regenerated independently.
 *
 * Entries are plain objects: { path, name, mtime, thumb } where path is the
 * absolute source file, mtime its modification time in epoch seconds and
 * thumb the absolute path of the cached preview png.
 */
Singleton {
    id: root

    property var entries: []
    readonly property int count: entries.length
    property string current: ""
    property bool pending: false

    /**
     * True while a refresh pipeline is in flight (thumbs → listing → state).
     * The wallpaper strip's refresh control spins while it is set, then snaps
     * back once the state read lands and `refreshDone` fires.
     */
    property bool refreshing: false

    /**
     * Fired once a full refresh pipeline has landed: thumbnails regenerated and
     * pruned, the listing re-read and `current` re-read from the state file.
     * Subscribers (the wallpaper strip) use it to re-centre on the wallpaper on
     * screen, which may have changed while they were closed.
     */
    signal refreshDone()

    property string resolvedDir: ""
    /**
     * The directories the strip reads, in order.
     *
     * Two, because they answer different questions and both matter:
     *
     *   * the user's own collection, which is permanent, and
     *   * the active theme's backgrounds, which follows every theme switch.
     *
     * The strip used to read exactly one directory, and the natural single
     * choice is the theme's -- that is where the wallpapers you just switched to
     * live. But it is TRANSIENT: omarchy installs a theme with
     * `rm -rf current/theme; mv next/theme current/theme`, so a theme switch
     * destroys every path in it. Making that the wallpaper library is what made
     * wallpapers feel broken rather than automatic -- dead paths held for a
     * minute after each switch, symlinks recorded into a tree about to vanish,
     * a black background.
     *
     * Reading both is what makes this need no maintenance. Install a new custom
     * theme and its wallpapers appear on their own; they leave when the theme
     * does, and your own collection never moves. Each entry carries the
     * directory it came from so the strip can tell them apart.
     *
     * `wallpaperDir` set explicitly still wins outright: someone who has
     * deliberately pointed the bar at one folder is not second-guessed by a
     * default.
     */
    readonly property var wpDirs: Flags.wallpaperDir.length > 0
        ? [Flags.wallpaperDir]
        : (function () {
            var out = [];
            var own = root.resolvedDir.length > 0 ? root.resolvedDir
                : Quickshell.env("HOME") + "/Pictures/Wallpapers";
            // The user's own collection first, so a wallpaper they put there
            // wins the newest-first sort against a theme's same-named file.
            if (own.length > 0)
                out.push(own);
            var themeDir = root.themeBackgroundsDir;
            if (themeDir.length > 0 && out.indexOf(themeDir) < 0)
                out.push(themeDir);
            return out;
          })()

    /** The active theme's background folder, or "" when there is none. */
    readonly property string themeBackgroundsDir: {
        var name = String(ThemeSync.activeThemeName || "").trim();
        if (!name.length)
            return "";
        return (Quickshell.env("XDG_STATE_HOME")
            || (Quickshell.env("HOME") + "/.local/state"))
            + "/omarchy/current/theme/backgrounds";
    }

    /** Kept for the resolver hop and for surfaces that read one path. */
    readonly property string wpDir: wpDirs.length > 0 ? wpDirs[0] : ""
    readonly property string thumbDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/better/wp-thumbs/"
    readonly property string thumbScript: Config.hyprPath("scripts", "wallpaper-thumbs.sh")
    readonly property string setScript: Config.hyprPath("scripts", "wallpaper.sh")
    readonly property string stateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better-wallpaper"
    readonly property string dirStateFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better-wallpaper-dir"

    FileView {
        id: dirFile
        path: root.dirStateFile
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.resolvedDir = dirFile.text().trim()
        onFileChanged: reload()
        onLoadFailed: root.resolvedDir = ""
    }

    /**
     * Omarchy's active background, polled so a wallpaper change made from
     * outside Better Bar is followed. Any path is accepted — the current
     * theme's backgrounds folder or anywhere else.
     */
    property string _lastOmarchyBackground: ""
    // Guards the first read: it only records a baseline. Applying then would
    // replay a transition over an already-correct desktop on every shell start.
    property bool _omarchyWatchStarted: false

    /**
     * The desktop background now arrives from `ThemeSync`, which owns the single
     * watch on `theme.name` and the single process that reads colors.toml *and*
     * resolves this symlink. Two consequences, both wanted:
     *
     *   * the palette and the wallpaper behind the pill change in the same tick
     *     rather than a moment apart, which is what stops a theme switch reading
     *     as a flicker
     *   * one watch and one spawn per tick instead of two of each
     *
     * The poll lives in `ThemeSync` for the same reason it always did: the
     * background link is repointed with `ln -nsf`, which replaces the link
     * itself, so nothing on that path can be watched and an outside wallpaper
     * change has no event to listen for. `omarchy theme bg set` is the case that
     * makes the poll the mechanism rather than a backstop.
     */
    Connections {
        target: ThemeSync
        function onRevisionChanged() { root.onDesktopBackground(); }
    }

    /**
     * Adopt the background ThemeSync resolved.
     *
     * The first observation only records a baseline. Applying then would replay a
     * transition over an already-correct desktop every time the shell starts.
     */
    function onDesktopBackground() {
        var target = String(ThemeSync.backgroundPath || "");
        if (!root._omarchyWatchStarted) {
            root._lastOmarchyBackground = target;
            root._omarchyWatchStarted = true;
            return;
        }
        if (target === root._lastOmarchyBackground)
            return;
        root._lastOmarchyBackground = target;
        if (target.length > 0)
            root.follow(target);

        // And re-scan the FOLDER, not only the wallpaper.
        //
        // A theme switch replaces current/theme wholesale -- omarchy does
        // `rm -rf current/theme; mv next/theme current/theme` -- so the paths the
        // strip is holding all name files that no longer exist. The strip used to
        // adopt the new background and leave those stale paths in place, because
        // the only other re-scan was the 60s fingerprint poll. For up to a minute
        // the strip kept offering the previous theme's wallpapers, and a click on
        // one ran `wallpaper.sh set <deleted path>`, which exits 1 at
        // `[ -f "$pic" ] || exit 1` -- silently. So a click did nothing, on a
        // picker that looked perfectly healthy, right after every theme switch.
        //
        // That is the "changing the theme then picking a wallpaper sometimes
        // doesn't work", and it was intermittent only because whether it worked
        // depended on whether the fingerprint timer had ticked since the switch.
        //
        // The poll has to stay regardless: an outside change with no event of its
        // own (`omarchy theme bg set`) never bumps this revision, so it is still
        // the mechanism for that case.
        root.refresh();
    }


    /** Fingerprint of the wallpaper folder; see `watchTimer`. */
    property string _dirStamp: ""

    /**
     * The folder to fingerprint: the configured one when set, otherwise whatever
     * the resolver settled on. Falls back to the standard pictures directory so
     * the first ticks before a resolve still have somewhere to look.
     */
    readonly property string watchDir: (root.resolvedDir.length > 0 ? root.resolvedDir
        : (Flags.wallpaperDir.length > 0 ? Flags.wallpaperDir
        : Quickshell.env("HOME") + "/Pictures/Wallpapers"))

    readonly property string stampScript: "d=\"$1\"; [ -d \"$d\" ] || exit 0; "
        + "find \"$d\" -maxdepth 1 -type f -printf '%T@ %s\\n' 2>/dev/null | sort | md5sum"

    function refresh() {
        if (resolveProc.running || thumbProc.running || listProc.running || stateProc.running) {
            pending = true;
            return;
        }
        refreshing = true;
        /**
         * Re-resolve the folder first when autodetect is in play: it only runs
         * inside wallpaper.sh, so a shell restart used to leave the strip on
         * the stale state file. An explicit folder skips that hop entirely and
         * swaps straight away.
         */
        if (Flags.wallpaperDir.length > 0) {
            thumbProc.running = true;
            return;
        }
        resolveProc.command = ["bash", root.setScript, "resolve"];
        resolveProc.running = true;
    }

    /**
     * Strip-opening warm-up. On a fresh shell the snapshot is empty and the
     * refresh button was the only way to fill it, so the first open showed
     * nothing until a manual refresh. Opening the strip now runs the pipeline
     * on its own just when it is actually needed: an empty snapshot refreshes
     * fully, otherwise one cheap `[ -s ]` probe on the newest entry's thumb
     * decides whether any previews are missing (e.g. the cache was cleared)
     * and only then rebuilds. A warm snapshot costs a single ~10ms stat.
     *
     * `warmRequested` latches the request so a rapid double activation (surface
     * rewiring during the open morph) cannot stack a second pipeline on the
     * first; it only clears once the listing actually lands or the probe finds
     * the previews intact.
     */
    property bool warmRequested: false

    function warm() {
        if (warmRequested)
            return;
        if (resolveProc.running || thumbProc.running || listProc.running || stateProc.running)
            return;
        if (entries.length === 0) {
            warmRequested = true;
            refresh();
            return;
        }
        if (probeProc.running)
            return;
        warmRequested = true;
        probeProc.command = ["sh", "-c", "[ -s \"$1\" ]", "_", entries[0].thumb];
        probeProc.running = true;
    }

    Process {
        id: probeProc
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.refresh();
            } else {
                root.warmRequested = false;
            }
        }
    }

    Process {
        id: resolveProc
        onExited: thumbProc.running = true
    }

    /**
     * wallpaper.sh blocks through the whole transition (awww wave, matugen,
     * reload), easily 1-2s; a pick landing in that window used to be silently
     * swallowed. Now the newest request is queued and replayed once the
     * running transition exits, so rapid iteration converges on the last pick.
     */
    property string queuedApply: ""
    property string queuedOutput: ""
    /** An outside wallpaper change waiting for `followProc`, newest wins. */
    property string queuedFollow: ""
    /**
     * True when a pick was refused because the wallpaper is no longer there.
     * The strip reads it to say why, rather than letting the click look like
     * the picker ignored the user. Cleared by callLater so a refusal stays
     * visible long enough to read.
     */
    property bool applyFailed: false

    /**
     * Apply a wallpaper the user chose, so `--force`: a pick in the strip is a
     * deliberate choice, and the script's guard exists only to catch a theme
     * wallpaper arriving on its own. Without the flag, picking one of the
     * current theme's own backgrounds here would be refused by the very rule
     * meant to protect an unrelated wallpaper.
     */
    function apply(path, output) {
        var out = output === undefined ? "" : output;

        // A path that no longer exists is refused here, not left to the script.
        //
        // The strip can be holding a stale path for a moment between a theme
        // swap landing and the re-scan rebuilding the list, and a pick on one
        // used to reach wallpaper.sh, which exits 1 at `[ -f "$pic" ] || exit 1`
        // -- silently. Nothing moved, nothing was said, and the click looked
        // like the picker ignoring the user.
        //
        // Refusing here instead re-scans the folder, which repairs the list, and
        // says so -- so the click that lands on a stale entry costs one tap and
        // leaves the strip showing wallpapers that can actually be applied.
        if (!root || !path || path.length === 0) {
            root.applyFailed = true;
            Qt.callLater(function () { root.applyFailed = false; });
            root.refresh();
            return;
        }

        if (applyProc.running) {
            queuedApply = path;
            queuedOutput = out;
            return;
        }
        applyProc.command = out.length > 0
            ? ["bash", root.setScript, "set", path, out, "--force"]
            : ["bash", root.setScript, "set", path, "--force"];
        applyProc.running = true;
    }

    /**
     * Apply a wallpaper that arrived from outside the strip, without --force.
     *
     * This is the path a theme switch arrives on: omarchy-theme-set repoints
     * current/background at the incoming theme's own wallpaper and this adopts
     * whatever it resolves to. That adoption is what silently replaced a
     * wallpaper the user had picked, so it is the one path that has to ask
     * the script first. `apply` above cannot: it is also the path a pick takes,
     * and there the answer is always yes.
     */
    function follow(path) {
        if (followProc.running) {
            queuedFollow = path;
            return;
        }
        followProc.command = ["bash", root.setScript, "set", path];
        followProc.running = true;
    }

    function trash(path) {
        trashProc.command = ["gio", "trash", path];
        trashProc.running = true;
        var kept = [];
        for (var i = 0; i < entries.length; i++)
            if (entries[i].path !== path)
                kept.push(entries[i]);
        entries = kept;
    }

    Process {
        id: trashProc
        onExited: function(exitCode) {
            if (exitCode !== 0)
                root.refresh();
        }
    }

    Process {
        id: thumbProc
        command: ["sh", root.thumbScript]
        onExited: listProc.running = true
    }

    Process {
        id: listProc
        // Every directory in the list, in one pass. The `-printf` output is
        // prefixed with the directory it came from, so the entries can be tagged
        // and the sort is still newest-first across all of them.
        command: ["sh", "-c",
            "for d in \"$@\"; do "
            + "  [ -d \"$d\" ] || continue; "
            + "  find \"$d\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' \\) -printf '%T@\\t%p\\n'; "
            + "done | sort -rn "
            + "| awk -F'\\t' -v c=\"$2\" '{ n = split($2, p, \"/\"); printf \"%s\\t%s\\t%s/%s.png\\t%s\\n\", $1, $2, c, p[n], p[n-1] }'",
            "_", root.wpDirs.join(" "), root.thumbDir]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.split("\n");
                var out = [];
                for (var i = 0; i < lines.length; i++) {
                    var t1 = lines[i].indexOf("\t");
                    if (t1 < 1)
                        continue;
                    var t2 = lines[i].indexOf("\t", t1 + 1);
                    if (t2 < 0)
                        continue;
                    var t3 = lines[i].indexOf("\t", t2 + 1);
                    if (t3 < 0)
                        continue;
                    var path = lines[i].substring(t1 + 1, t2);
                    var name = path.substring(path.lastIndexOf("/") + 1);
                    // The containing directory, so a wallpaper that arrived with
                    // a theme can be recognised later -- including after the
                    // theme's own copy is gone.
                    out.push({
                        path: path,
                        name: name,
                        mtime: parseFloat(lines[i].substring(0, t1)),
                        thumb: lines[i].substring(t2 + 1, t3),
                        origin: lines[i].substring(t3 + 1)
                    });
                }
                root.entries = out;
                stateProc.running = true;
            }
        }
    }

    /**
     * The strip's current marker reads `current`, but the state file
     * wallpaper.sh maintains only knows picks applied through the script
     * itself. A wallpaper set by the daemon directly (an `awww restore` at
     * login, an external `awww img`, another tool) never lands there, leaving
     * `current` empty. When the state file comes up empty we ask the daemon —
     * the source of truth for what is on screen — and adopt the first still it
     * reports, so the strip marker agrees with reality even for external picks.
     * The probe is bounded and retires early: it stops as soon as a wallpaper
     * is known or the daemon stays unreachable, so it never idles behind the
     * shell.
     */
    property int liveTries: 0
    readonly property int liveTriesMax: 8

    function adoptLive() {
        if (liveProc.running)
            return;
        if (root.current.length > 0 || root.liveTries >= root.liveTriesMax)
            return;
        liveProc.command = ["awww", "query", "-j"];
        liveProc.running = true;
    }

    Timer {
        id: liveRetry
        interval: 1500
        repeat: false
        onTriggered: root.adoptLive()
    }

    /**
     * Auto-refresh: notice wallpapers appearing, vanishing or being edited.
     *
     * The list was only ever rebuilt by the strip's refresh button, so dropping a
     * new wallpaper into the folder left it absent until that button was pressed.
     *
     * A fingerprint rather than a FileView: this watches a *directory*, and what
     * matters is the set of files with their mtimes and sizes, so the stamp is
     * `find -printf '%T@ %s'` piped through `sort | md5sum`. Any add, delete,
     * retitle or re-encode changes it; merely opening the folder does not, so the
     * expensive snapshot pipeline does not re-run on every tick.
     *
     * `refresh()` already coalesces overlapping runs behind `pending`, so a burst
     * of changes (a whole folder copied in) collapses into one rebuild that starts
     * once the in-flight one finishes.
     */
    Timer {
        id: watchTimer
        interval: 60000
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: {
            if (stampProc.running)
                return;
            stampProc.running = true;
        }
    }

    Process {
        id: stampProc
        command: ["sh", "-c", root.stampScript, "_", root.watchDir]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var stamp = String(text || "").trim();
                if (stamp.length > 0 && stamp !== root._dirStamp) {
                    root._dirStamp = stamp;
                    root.refresh();
                }
            }
        }
    }

    Process {
        id: liveProc
        stdout: StdioCollector {
            onStreamFinished: {
                var picked = "";
                try {
                    var obj = JSON.parse(this.text);
                    var outs = (obj && Array.isArray(obj[""])) ? obj[""] : [];
                    for (var i = 0; i < outs.length; i++) {
                        var out = outs[i];
                        var disp = (out && typeof out === "object") ? out.displaying : null;
                        if (disp && typeof disp.image === "string" && disp.image.length > 0) {
                            picked = disp.image;
                            break;
                        }
                    }
                } catch (err) {
                    picked = "";
                }
                if (picked.length > 0) {
                    root.liveTries = root.liveTriesMax;
                    if (root.current.length === 0)
                        root.current = picked;
                } else if (root.current.length === 0 && root.liveTries < root.liveTriesMax) {
                    root.liveTries += 1;
                    liveRetry.start();
                }
            }
        }
    }

    Component.onCompleted: {
        root.onDesktopBackground();
        root.adoptLive();
    }

    Process {
        id: stateProc
        command: ["sh", "-c", "cat \"$1\" 2>/dev/null || true", "_", root.stateFile]
        stdout: StdioCollector {
            onStreamFinished: {
                var live = this.text.trim();
                if (live.length > 0)
                    root.current = live;
                else
                    root.adoptLive();
                root.warmRequested = false;
                if (root.pending) {
                    root.pending = false;
                    Qt.callLater(root.refresh);
                } else {
                    root.refreshing = false;
                    root.refreshDone();
                }
            }
        }
    }

    Process {
        id: applyProc
        onExited: function (exitCode) {
            // The script exits 1 at `[ -f "$pic" ] || exit 1` when the wallpaper
            // is gone -- a theme swap replacing the tree underneath a still-open
            // strip, or a file deleted outside the bar. That path used to be
            // indistinguishable from a success, so the strip recorded a pick
            // that never landed. Re-scan so the list stops offering it, and say
            // so rather than letting the click look ignored.
            if (exitCode !== 0) {
                root.refresh();
                root.applyFailed = true;
                Qt.callLater(function () { root.applyFailed = false; });
            }
            if (root.queuedApply.length) {
                var next = root.queuedApply;
                var nextOut = root.queuedOutput;
                root.queuedApply = "";
                root.queuedOutput = "";
                // --force here too: a queued request is a pick that landed
                // while an earlier one was still painting.
                applyProc.command = nextOut.length > 0
                    ? ["bash", root.setScript, "set", next, nextOut, "--force"]
                    : ["bash", root.setScript, "set", next, "--force"];
                applyProc.running = true;
                return;
            }
            // A pick is on record and painted; a wallpaper that arrived
            // from outside has been applied (or refused, in which case
            // the script already put the symlink back). Either way the
            // recorded state is worth re-reading now.
            stateProc.running = true;
        }
    }

    /**
     * The outside-change applier. Separate from `applyProc` because the two
     * carry opposite intent about the script's guard, and sharing one process
     * meant whichever ran last decided for both. A theme switch landing mid
     * pick would be forced through, and a pick landing mid theme switch would
     * be refused -- both of which read as a wallpaper that changes when you did
     * not ask it to.
     */
    Process {
        id: followProc
        command: ["bash", root.setScript, "set", ""]
        onExited: {
            if (root.queuedFollow.length) {
                var next = root.queuedFollow;
                root.queuedFollow = "";
                followProc.command = ["bash", root.setScript, "set", next];
                followProc.running = true;
                return;
            }
            stateProc.running = true;
        }
    }

    /**
     * Fit-mode change: wallpaper.sh "fit <mode>" (no transition, no palette
     * run) re-images the current stills through aww with the new --resize and
     * respawns videos with matching mpv scaling. Fast enough that rapid clicks
     * are rare, but the same one-slot latch as apply() keeps the last pick from
     * being dropped while an earlier one still runs.
     */
    property string queuedFit: ""

    function applyFit(mode) {
        if (fitProc.running) {
            queuedFit = mode;
            return;
        }
        fitProc.command = ["bash", root.setScript, "fit", mode];
        fitProc.running = true;
    }

    Process {
        id: fitProc
        onExited: {
            if (root.queuedFit.length) {
                var next = root.queuedFit;
                root.queuedFit = "";
                fitProc.command = ["bash", root.setScript, "fit", next];
                fitProc.running = true;
            }
        }
    }
}
