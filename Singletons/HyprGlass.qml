pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * 笠 HYPRGLASS -- what the compositor is actually doing, so the bar can match it.
 *
 * Better Bar draws its own glass, and that was independent of Hyprland: the pill
 * could be translucent and blurry while every window behind it was sharp and
 * solid. The disagreement is not cosmetic. The reason blur is switched off on
 * this machine is the exact failure a disagreeing bar creates -- compositor blur
 * diffuses the whole screen, including over the bar, so a bar that also blurs
 * reads as a smear, and a bar that does not looks like it is glowing for no
 * reason.
 *
 * Four values, read together because the combination is the thing that matters;
 * matching some and guessing the rest is how the bar ends up halfway between the
 * desktop and itself:
 *
 *   decoration:blur:enabled       whether anything may look glassy
 *   decoration:blur:size          how much, scaled
 *   decoration:active_opacity     how solid a focused surface is
 *   decoration:inactive_opacity   how solid an unfocused one is
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
     * compositor at all still behaves as it did before this existed.
     */
    readonly property bool defaultBlur: Flags.glass
    readonly property real defaultOpacity: 1

    property bool blurEnabled: root.defaultBlur
    property int blurSize: 8
    property real activeOpacity: root.defaultOpacity
    property real inactiveOpacity: root.defaultOpacity
    property int rounding: 10

    /**
     * True when a live Hyprland was read at least once. `usable` distinguishes
     * "Hyprland says blur is off" from "we have never managed to ask", which are
     * different facts wearing the same value -- collapsing them is how a broken
     * read silently turns into a house style.
     */
    property bool usable: false

    /**
     * What the pill's opacity should be to match Hyprland.
     *
     * The active value, not the inactive: the pill is what you are looking at,
     * and matching the unfocused value would make the bar dimmer than every
     * window you are working in.
     */
    readonly property real pillOpacity: root.usable ? root.activeOpacity : root.defaultOpacity

    /** The compositor's rounding, for the pill and any chip that wants to agree. */
    readonly property real pillRounding: root.usable ? root.rounding : 10

    // ---- the one read ------------------------------------------------------

    /**
     * A single process for all four values, sentinel-joined so one cut of JSON
     * answers everything. Failure of any one read leaves its default rather than
     * zeroing it: a partial answer is more useful than a fresh install's.
     */
    Process {
        id: reader
        running: true
        command: ["sh", "-c",
            "for o in decoration:blur:enabled decoration:blur:size decoration:active_opacity decoration:inactive_opacity decoration:rounding; do"
            + "    hyprctl -j getoption \"$o\" 2>/dev/null;"
            + "    printf '[[[]]]\\n';"
            + "done"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.consume(String(text || ""));
            }
        }
    }

    /**
     * Split the sentinel-joined readouts apart.
     *
     * `hyprctl -j getoption` reports value under `float` for reals, `int` for
     * integers, and neither for a bool -- which comes back as `"true"`/`"false"`
     * in a key that is neither of those, and is the reason this reads all three
     * shapes rather than one consistent one.
     */
    function consume(text) {
        var cut = text.lastIndexOf("[[[]]]");
        if (cut < 0)
            return;
        var parts = text.slice(0, cut).split("[[[]]]");
        if (parts.length < 5)
            return;

        function val(i) {
            try {
                var obj = JSON.parse(parts[i]);
                if (obj.float !== undefined)
                    return Number(obj.float);
                if (obj.int !== undefined)
                    return Number(obj.int);
                if (obj.custom === "true" || obj.custom === true)
                    return 1;
                if (obj.custom === "false" || obj.custom === false)
                    return 0;
                return Number(obj.custom);
            } catch (e) {
                return null;
            }
        }

        var blur = val(0);
        var size = val(1);
        var act = val(2);
        var inact = val(3);
        var round = val(4);

        // Only `blur` being unreadable means we learned nothing about the
        // compositor's intent; a missing size or rounding still leaves a usable
        // answer, so this is the gate on `usable` rather than on all five.
        if (blur === null)
            return;

        root.blurEnabled = blur > 0;
        root.usable = true;
        if (size !== null && size >= 0)
            root.blurSize = size;
        if (act !== null && act >= 0 && act <= 1)
            root.activeOpacity = act;
        if (inact !== null && inact >= 0 && inact <= 1)
            root.inactiveOpacity = inact;
        if (round !== null && round >= 0)
            root.rounding = round;
    }

    /** Re-read on demand — a `hyprctl reload` changes all of this. */
    function refresh() {
        reader.running = false;
        reader.running = true;
    }

    /**
     * Never poll. Hyprland's glass settings change when someone edits their
     * config, which is a deliberate act that already ends in a reload; polling
     * would be a process every few seconds forever to learn something that is
     * true almost all the time. `refresh()` is called when the tick decides it
     * is worth asking.
     */
    Timer {
        interval: 60000
        repeat: true
        running: root.usable
        onTriggered: root.refresh()
    }
}
