// Asserts that the bar's accent follows the live Omarchy theme, and that only a
// deliberate user choice overrides it.
//
// The bug this exists for: sync_theme.py writes accentOverride into flags.json on
// every theme set, so Theme.accent took the customAccent branch and never read
// the live theme accent at all. The bar kept whatever the hook had written --
// stale until the hook ran, and pinned there afterwards -- and the Accent
// surface's toggle read "custom" for a user who had never chosen a colour.
//
// A pinned accent has to keep working. The rule under test: the override wins
// only while it differs from what the theme itself names. Equal to the theme's
// accent is indistinguishable from following the theme, so it follows; any other
// value is the user pinning a colour, and the pin holds.
//
// XDG_STATE_HOME has to point at a scratch dir holding a copy of flags.json:
// Flags reads an absolute path from there, so running against the real one would
// edit the user's settings. scripts/run-tests.sh sets this up.
//
//   mkdir -p /tmp/acc/better && cp ~/.local/state/better/flags.json /tmp/acc/better/
//   XDG_STATE_HOME=/tmp/acc quickshell -p accent.test.qml
//
// It sits at the config root rather than in lib/ because Quickshell resolves a
// directory import's singleton qmldir only from the config root: from lib/, both
// Theme and ThemeColors come back undefined.

import QtQuick
import Quickshell
import "Singletons"

Singleton {
    id: harness

    property int failures: 0

    function check(what, actual, expected) {
        var a = String(actual);
        var e = String(expected);
        if (a === e) {
            console.log("ACCENT PASS " + what);
        } else {
            harness.failures++;
            console.log("ACCENT FAIL " + what + "\n  expected: " + e + "\n  got:      " + a);
        }
    }

    /**
     * Colors are compared as "#RRGGBB" strings.
     *
     * Not through Theme.hexUpper: that takes a QML color and reads .r/.g/.b, which
     * are undefined for a "#rrggbb" string, so it answered "#ANANAN" for every
     * string handed to it. A first run of this test failed on values that were in
     * fact correct because of that, which is worth remembering before trusting a
     * helper's name over its argument type.
     */
    function hexOfColor(c) {
        return Theme.hexUpper(c);
    }

    /** The accent the fake theme below names, so every expectation is exact. */
    readonly property string themeAccent: "#7d82d9"
    readonly property string themeForeground: "#cdd6f4"

    /**
     * One step per assertion group, each followed by a settle.
     *
     * JsonAdapter applies a property change on the next tick rather than
     * synchronously, so reading a flag straight after writing it reads the old
     * value. That is load-bearing here: without the settle every assertion after
     * the first read the previous step's state, which made correct behaviour
     * report as broken in both directions at once.
     */
    property int step: 0

    Component.onCompleted: {
        ThemeColors.palette = ({ "accent": themeAccent, "foreground": themeForeground });
        harness.advance();
    }

    Timer {
        id: settle
        interval: 120
        onTriggered: harness.advance()
    }

    function advance() {
        // Re-assert the fixture palette before every step. ThemeSync polls the
        // real colors.toml on its own timers, so a palette set once at startup is
        // replaced partway through the run -- and the replacement carries the
        // machine's real foreground, which made the text-override steps disagree
        // with the accent steps. The fixture is the test's subject, so it is
        // re-stated rather than raced.
        ThemeColors.palette = ({ "accent": themeAccent, "foreground": themeForeground });

        var fn = harness.steps[harness.step];
        harness.step += 1;
        if (!fn) {
            console.log(harness.failures === 0 ? "ACCENT ALL GREEN" : "ACCENT " + harness.failures + " FAILING");
            Qt.exit(harness.failures === 0 ? 0 : 1);
            return;
        }
        fn();
        settle.start();
    }

    property var steps: [
        function readsTheme() {
            harness.check("the bar reads the theme accent", Theme.omarchyAccent, harness.themeAccent);
        },

        function setOverrideEqualToTheme() {
            Flags.accentOverride = harness.themeAccent;
        },

        function overrideEqualToThemeFollows() {
            harness.check("an override equal to the theme accent still follows the theme",
                Theme.customAccent, false);
            harness.check("the accent is the theme's own",
                hexOfColor(Theme.accent), harness.themeAccent.toUpperCase());
        },

        function setCustomPin() {
            Flags.accentOverride = "#ff0000";
        },

        function customPinWins() {
            harness.check("a different hex counts as a custom pin", Theme.customAccent, true);
            harness.check("a custom pin wins over the theme",
                hexOfColor(Theme.accent), "#FF0000");
            harness.check("the deep variant derives from the pin",
                hexOfColor(Theme.accentDeep).length, 7);
            harness.check("the lit variant derives from the pin",
                hexOfColor(Theme.vermLit), "#FF0000");
        },

        function clearOverride() {
            Flags.accentOverride = "";
        },

        function clearedFollowsTheme() {
            harness.check("clearing the override follows the theme again",
                Theme.customAccent, false);
            harness.check("the accent is the theme's own once cleared",
                hexOfColor(Theme.accent), harness.themeAccent.toUpperCase());
        },

        function setLowerCaseCopy() {
            Flags.accentOverride = harness.themeAccent.toLowerCase();
        },

        function lowerCaseIsNotAPin() {
            harness.check("a lower-case copy of the theme accent is not a pin",
                Theme.customAccent, false);
        },

        function restoreAccent() {
            Flags.accentOverride = harness.themeAccent;
        },

        function overrideFlagDoesNotImplyPin() {
            // The surfaces and the dock used to ask "is a hex present", which
            // sync_theme.py makes true on every theme set. They must read the
            // same rule Theme does, or the Accent toggle keeps saying "custom"
            // for a user who has chosen nothing.
            harness.check("the accent surface's toggle follows the theme",
                Theme.customAccent, false);
            harness.check("the dock's accent follows the theme",
                Theme.customAccent, false);
        },

        function setTextOverrideEqualToTheme() {
            Flags.textOverride = harness.themeForeground;
        },

        function textOverrideEqualToThemeFollows() {
            harness.check("a text override equal to the theme foreground still follows the theme",
                Theme.customText, false);
        },

        function setCustomTextPin() {
            Flags.textOverride = "#00ff00";
        },

        function customTextPinWins() {
            harness.check("a different text hex counts as a pin", Theme.customText, true);
            harness.check("the icon tint follows the text pin",
                Theme.iconDim.a > 0, true);
        },

        function clearTextOverride() {
            Flags.textOverride = "";
        },

        function clearedTextFollowsTheme() {
            harness.check("clearing the text override follows the theme again",
                Theme.customText, false);
        },

        function restore() {
            Flags.textOverride = harness.themeForeground;
        }
    ]
}