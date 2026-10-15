#!/usr/bin/env bash
# Asserts Better Bar trusts the recorder's own pre-roll countdown.
#
# The old approach derived the countdown locally from the first number and a
# local clock. It froze then looped, and even after latching it could still show
# 1 -> 2 -> 1 because a stale or late pending snapshot re-armed the display.
#
# The recorder publishes every remaining second, so this shell no longer
# invents a countdown: it mirrors `countdownRemaining`, watches the state file
# while the pre-roll is live, and falls back to a 500ms poll when inotify misses
# a write. The countdown is short, so the watcher cost is bounded; the long,
# expensive state-change feed stays off as before.
set -uo pipefail

ROOT=${1:-}
if [ -z "$ROOT" ]; then
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi
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
no() {
    if [ "$2" = "0" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  found %s occurrence(s), expected none\n' "$1" "$2"
    fi
}
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$RECAST" ] || { echo "no Singletons/Recast.qml at $RECAST" >&2; exit 1; }

# --- no local re-anchor can exist --------------------------------------------
# These names are all that remain of the old local-clock path. If any comes
# back, the display can derive a countdown again and the 1 -> 2 bug returns.
for dead in countdownBase _countdownShown countdownCompleted countdownStartAtMs rawCountdownRemaining; do
    no "no local countdown state: $dead" \
        "$(grep -c "$dead" "$RECAST")"
done

# The value on screen is a pure read of the service's published number.
has "the countdown display mirrors the recorder" \
    "$(grep -c 'return root.serviceCountdownRemaining;' "$RECAST")" \
    "return root.serviceCountdownRemaining"

# And it is updated exactly as read, not only when it is higher/lower, so the
# service is the sole authority for its own countdown.
has "the pending read writes the service number through" \
    "$(grep -c 'root.serviceCountdownRemaining = readCountdown;' "$RECAST")" "1"

# --- the feed that makes it live ---------------------------------------------
# The bounded watch: on only for the countdown, off for the long recording.
ok "the state file is watched while the countdown is live" \
    "$(grep -c 'watchChanges: root.countdownPending' "$RECAST")" "1"

# Fallback for inotify misses. Must be tighter than the countdown, not looser.
ok "the poll is tighter during the countdown" \
    "$(grep -c 'interval: root.countdownPending ? 500' "$RECAST")" "1"

# The tick driver must not own the countdown either. It drives the elapsed
# ratchet only.
ok "the tick driver is elapsed-only" \
    "$(grep -c 'running: root.recording || root.paused' "$RECAST")" "1"
no "the tick driver no longer depends on countdownPending" \
    "$(grep -c 'running: root.recording || root.paused || root.countdownPending' "$RECAST")"

# A pending flag after the recorder has already started is stale display state.
ok "a pending flag after recording starts is ignored" \
    "$(grep -c 'st !== "recording" && st !== "paused"' "$RECAST")" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
