#!/usr/bin/env bash
# Asserts the recording pre-roll countdown actually counts.
#
# Why it exists: the countdown chip froze. Pressing record showed 3… 2… 1… then
# stopped, and the pill sat on "STARTING" until you clicked somewhere — at which
# point it snapped to the real recording state. Not cosmetic: a countdown you
# cannot watch is worse than no countdown, because you cannot tell whether it is
# still running, has finished, or has died.
#
# Root cause, established with a probe rather than by reading: the tick driver
#   running: root.recording || root.paused
# omits countdownPending. The displayed number is a binding over Date.now(),
# which is not a reactive dependency, and root._tick — incremented by that timer
# — is the only thing that re-evaluates it. So during the pre-roll nothing
# re-evaluates, and the number reads once and freezes.
#
# Both halves are tested: the timer's condition (cheap, runs everywhere) and the
# visible behaviour (only when a Wayland session is available, the same
# environmental skip omshell-load.test.sh uses).
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECAST="$ROOT/Singletons/Recast.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$RECAST" ] || { echo "no Singletons/Recast.qml at $RECAST" >&2; exit 1; }

# --- the driver covers every state that has a number on screen ------------
# A tick driver is only evidence of a working countdown if it runs during the
# countdown. The recording/paused conditions were already there; this is the one
# that was missing, and its absence is the entire bug.
ok "the tick driver runs during the pre-roll" \
    "$(grep -c 'root.recording || root.paused || root.countdownPending' "$RECAST")" "1"
ok "the tick driver still runs during a live capture" \
    "$(grep -B1 -A1 'onTriggered: {' "$RECAST" | grep -c 'recording || root.paused || root.countdownPending')" "1"

# The countdown's own poll cadence must stay ahead of, or at least level with,
# the tick: a slower poll than the display makes the re-anchor arrive after the
# number it is meant to correct.
ok "the poll is quick while the countdown is running" \
    "$(grep -c 'root.countdownPending ? 1000 : (root.recording ? 5000 : 2000)' "$RECAST")" "1"

# The number must be allowed to reach the state that means "not counting".
# Clamping the projection at 1 is what keeps 0 off screen *during* the pre-roll,
# so it must stay; the countdown's end is signalled by countdownPending
# clearing, not by the number hitting zero.
ok "the projection still clamps so 0 never shows mid-countdown" \
    "$(grep -c 'Math.max(1, root.serviceCountdownRemaining - diff)' "$RECAST")" "1"

# --- the visible behaviour, where a Wayland session is available -----------
if [ -z "${WAYLAND_DISPLAY:-}" ] || ! command -v qs >/dev/null 2>&1; then
    printf 'SKIP live countdown probe (needs a Wayland session and qs)\n'
else
    STATE=$(mktemp -d)
    PROBE="$ROOT/.recast-countdown-tmp.qml"
    trap 'rm -rf "$STATE" "$PROBE"' EXIT
    mkdir -p "$STATE/px-gsr"

    # A static file that claims a 3-second pre-roll and is never rewritten. This
    # is the important case: it removes the service from the equation, so what is
    # under test is purely whether the display moves on its own. Before the fix
    # this read 3 once and then held it for the whole window.
    printf '{"recordingState":"idle","recordingElapsed":0,"countdownPending":true,"countdownRemaining":3}\n' \
        > "$STATE/px-gsr/state.json"

    cat >"$PROBE" <<'QML'
import QtQuick
import Quickshell
import "Singletons"
Item {
    id: root
    property int ticks: 0
    property string seen: ""
    Timer {
        interval: 250
        repeat: true
        running: true
        onTriggered: {
            root.ticks++;
            root.seen += (root.seen.length ? "," : "") + Recast.countdownRemaining;
            if (root.ticks > 16) { console.log("PROBE " + root.seen); Qt.quit(); }
        }
    }
}
QML

    OUT=$(XDG_RUNTIME_DIR="$STATE" timeout 25 env QT_QPA_PLATFORM=offscreen \
        qs -p "$PROBE" -n 2>&1 | grep -oE 'PROBE .*' | head -1)
    rm -f "$PROBE"

    SEEN="${OUT#PROBE }"
    # Drop the leading zero(es): the singleton has not read the file yet for the
    # first couple of samples, and an unloaded state reads 0 rather than 3.
    NONZERO=$(printf '%s' "$SEEN" | sed 's/,/\n/g' | grep -v '^0$' | sed '/^$/d')
    MIN=$(printf '%s' "$NONZERO" | sort -n | head -1)
    MAX=$(printf '%s' "$NONZERO" | sort -n | tail -1)

    # The real assertion. With the bug the values are 0,3,3,3,… — loaded and then
    # motionless, so the low and high marks are the same number. With the fix
    # they run 3,2,1,1, and the low mark is below the high one. Asserting that
    # the number falls is the thing that separates the two; "more than one value
    # appeared" is trivially true of 0,3,3,3 and would have let the bug through.
    ok "a countdown with no further writes still counts down" \
        "$([ "$MIN" -lt "$MAX" ] && echo falling || echo frozen)" "falling"
    # And it must begin from the number the service wrote rather than from
    # whatever the projection happens to reach first.
    ok "the countdown starts from the number the service wrote" \
        "$(printf '%s' "$NONZERO" | head -1)" "3"
    # Three distinct values were sampled, or the display is only step-changing on
    # a rare re-read rather than ticking once a second.
    ok "the display holds mid-countdown values, not just the first and last" \
        "$(printf '%s' "$NONZERO" | sort -un | wc -l | tr -d ' ')" "3"
fi

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'