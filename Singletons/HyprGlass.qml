pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * 笠 HYPRGLASS -- what the compositor is doing, so the bar can stop disagreeing.
 *
 * Better Bar drew its own glass, independent of Hyprland: the pill could be
 * translucent and blurry while every window behind it was sharp and solid. The
 * disagreement is not cosmetic. Blur is switched off on this machine precisely
 * to stop the whole screen diffusing over the bar, so a bar that blurs on its
 * own is the artifact that setting exists to avoid.
 *
 * Two values, read together because the combination is what matters -- matching
 * one and guessing the other leaves the bar halfway between the desktop and
 * itself, which is worse than either choice:
 *
 *   decoration:blur:enabled       whether anything may look glassy
 *   decoration:active_opacity     how solid a focused surface is
 *
 * Blur size and rounding are read too and deliberately discarded: the bar's
 * granularity is a rounded pill, not a blurred one, and a value nothing behaves
 * differently on is a value that quietly rots.
 *
 * Read-only by construction. `getoption` cannot change anything, and there is no
 * writer here on purpose -- the bar follows Hyprland, never the reverse, because
 * a status bar pushing at the compositor is a surprise at best.
 *
 * Fail-soft: a missing hyprctl, or a compositor that is not Hyprland, leaves the
 * defaults in place. `usable` is false exactly then, so a caller can fall back to
 * its own look rather than to a guessed one.
 */
Singleton {
    id: root

    /**
     * The bar's own defaults, used when Hyprland cannot be read. These inherit
     * from Flags rather than being literals, so an install that never reads the
     * compositor at all behaves exactly as it did before this existed.
     */
    readonly property bool defaultBlur: Flags.glass
    readonly property real defaultOpacity: 1

    /** Whether anything on screen may smear. */
    property bool blurEnabled: root.defaultBlur

    /** How solid a focused surface is. This is the bar's opacity when following. */
    property real activeOpacity: root.defaultOpacity

    /**
     * True when a live Hyprland was read at least once. `usable` separates
     * "Hyprland says blur is off" from "we have never managed to ask", which are
     * different facts wearing the same value -- collapsing them is how a broken
     * read silently becomes a house style.
     */
    property bool usable: false

    /** What the pill's opacity should be to match Hyprland. */
    readonly property real pillOpacity: root.usable ? root.activeOpacity : root.defaultOpacity

    /**
     * One read for both values, sentinel-joined so a single cut of JSON answers
     * everything the bar needs. Failure of either read leaves its default rather
     * than zeroing it: a partial answer is more useful than a fresh install's.
     */
    Process {
        id: reader
        running: true
        command: ["sh", "-c",
            "for o in decoration:blur:enabled decoration:active_opacity; do"
            + "    hyprctl -j getoption \"$o\" 2>/dev/null;"
            + "    printf '[[[]]]\\n';"
            + "done"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.consume(String(text || ""))
        }
    }

    /**
     * Split the sentinel-joined readouts apart.
     *
     * `hyprctl -j getoption` reports the value under `float` for a real, `int`
     * for an integer, and neither for a bool -- a bool comes back as a string in
     * a key that is neither of those, which is why this reads all three shapes
     * rather than assuming one.
     */
    function consume(text) {
        var cut = text.lastIndexOf("[[[]]]");
        if (cut < 0)
            return;
        var parts = text.slice(0, cut).split("[[[]]]");
        if (parts.length < 2)
            return;

        function val(i) {
            try {
                var obj = JSON.parse(parts[i]);
                if (obj.float !== undefined)
                    return Number(obj.float);
                if (obj.int !== undefined)
                    return Number(obj.int);
                return Number(obj.custom);
            } catch (e) {
                return null;
            }
        }

        var blur = val(0);
        var act = val(1);

        // An unread blur value means we learned nothing about the compositor's
        // intent, so this is the gate on `usable` rather than on either value:
        // treating an unreadable answer as "blur is off" would be a confident
        // guess, which is the thing this whole file exists to avoid.
        if (blur === null)
            return;

        root.blurEnabled = blur > 0;
        root.usable = true;
        if (act !== null && act >= 0 && act <= 1)
            root.activeOpacity = act;
    }

    /** Re-read on demand — a `hyprctl reload` changes all of this. */
    function refresh() {
        reader.running = false;
        reader.running = true;
    }

    /**
     * Re-read rarely, and only once it has worked at least once.
     *
     * Hyprland's glass settings change when someone edits their config, which is
     * a deliberate act that already ends in a reload. Polling every second would
     * spend a process on learning something that is true almost all the time.
     */
    Timer {
        interval: 60000
        repeat: true
        running: root.usable
        onTriggered: root.refresh()
    }
}
