pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../Commons"

/**
 * One watcher for "the desktop's look changed", driving the palette and the
 * wallpaper together.
 *
 * These were two independent mechanisms that happened to agree most of the time.
 * `ThemeColors` watched `theme.name` and polled `colors.toml` every 4s on its own
 * `cat`; `Walls` watched the *same* `theme.name` and probed the background
 * symlink every 4s on its own `sh`. That cost two watches on one file, two
 * spawns per tick, and — worse — let the two land out of step: after a theme
 * switch the pill could repaint its colours a moment before or after the
 * wallpaper behind it changed, which reads as a flicker even though each half
 * was individually correct.
 *
 * So there is now one of each, here:
 *
 *   * one FileView on `theme.name`, which omarchy rewrites in place with
 *     `echo >` (omarchy-theme-set:296) and is therefore the one path in this
 *     tree that survives the `rm -rf` + `mv` that installs a new theme
 *   * one `sh` per tick that resolves the background symlink *and* reads
 *     colors.toml, so both answers come from the same moment
 *
 * `revision` increments whenever either value actually changes, which is what
 * consumers key their repaint on. Nothing polls the consumers any more: they
 * read these two properties and react.
 *
 * A wallpaper change made outside Omarchy (`omarchy theme bg set`) does not
 * touch `theme.name`, so the poll stays as the mechanism for that case rather
 * than as a backstop — same reasoning as before, just consolidated.
 */
Singleton {
    id: root

    /** Contents of the active theme's colors.toml, or "" before the first read. */
    property string paletteText: ""
    /** Resolved, existence-checked path of the desktop background, or "". */
    property string backgroundPath: ""
    /** Bumped on every change to either value above. */
    property int revision: 0

    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
        || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current"

    /**
     * The watched signal file. See the header for why this one and not
     * colors.toml: the theme directory is replaced wholesale on a switch, so a
     * watch bound to the old inode would go permanently deaf.
     */
    readonly property string themeNamePath: root.stateDir + "/theme.name"
    readonly property string backgroundLink: root.stateDir + "/background"
    readonly property string colorsPath: root.stateDir + "/theme/colors.toml"

    /** How often the poll asks. See `probe` for why this cannot go slower. */
    readonly property int pollMs: 4000

    Component.onCompleted: {
        themeName.reload();
        root.probe();
    }

    // ---- the single read ---------------------------------------------------

    /**
     * One process answers both questions.
     *
     * The two halves are delimited by a unit separator (\x1f) rather than a
     * newline because colors.toml is arbitrary text: it may contain blank lines
     * and anything else, whereas the background path never does. Splitting the
     * output on a newline and taking "the rest" as the palette is the shape that
     * quietly truncates a theme file with a trailing blank line.
     */
    function probe() {
        probeProc.running = true;
    }

    Process {
        id: probeProc
        command: ["sh", "-c", root.probeScript, "_", root.backgroundLink, root.colorsPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.apply(text)
        }
    }

    function apply(raw) {
        var out = String(raw || "");
        // Unit separator: the same byte `probeScript` writes between the
        // two halves, so one constant defines the delimiter on both sides.
        var split = out.indexOf("\u001f");
        if (split < 0)
            return;
        var palette = out.substring(0, split);
        var background = out.substring(split + 1).trim();

        var changed = false;
        if (palette.length > 0 && palette !== root.paletteText) {
            root.paletteText = palette;
            changed = true;
        }
        if (background !== root.backgroundPath) {
            root.backgroundPath = background;
            changed = true;
        }
        if (changed)
            root.revision += 1;
    }

    /**
     * The probe script. Kept out of the Process for one reason: the `$1`
     * indirection means both paths arrive as arguments, so a directory with a
     * space or a quote in it cannot turn into shell syntax.
     */
    readonly property string probeScript:
        "p=$(readlink -f \"$1\" 2>/dev/null) && [ -f \"$p\" ] || p=;"
        + " printf '%s' \"$(cat \"$2\" 2>/dev/null)\";"
        + " printf '\\037%s' \"$p\""

    onProbeScriptChanged: probe()

    /**
     * Theme switch: re-read after the `mv` lands.
     *
     * `theme.name` is written *after* the swap (omarchy-theme-set:296), so the
     * delay is not about ordering the two writes — it is that the file event and
     * the directory rename are not atomic with respect to each other, and a read
     * fired immediately can still catch the pre-swap tree on some filesystems.
     */
    Timer {
        id: settle
        interval: 400
        onTriggered: { root.probe(); Color.reloadTheme(); }
    }

    FileView {
        id: themeName
        path: root.themeNamePath
        blockLoading: true
        // Not `atomicWrites`: omarchy writes this with `echo >`, a truncate and
        // rewrite of the same inode, not a temp-file rename.
        watchChanges: true
        printErrors: false
        onFileChanged: {
            reload();
            settle.restart();
        }
    }

    Timer {
        interval: root.pollMs
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.probe()
    }
}