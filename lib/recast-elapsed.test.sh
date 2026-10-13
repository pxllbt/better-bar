#!/usr/bin/env bash
# Asserts the recast chip's elapsed count cannot rewind.
#
# The bug this exists for: `recordingElapsed` was published in state.json with
# no indication of when it had been measured, so this file had to guess. It
# guessed "now" -- every re-anchor stamped `Date.now()` against whatever count
# the read happened to return. The service rewrites the file once a second while
# this singleton polls every 5s, so a read that landed one second behind the
# live count re-anchored that stale value as if it were current and the chip
# snapped backwards a second, then carried on counting from the rewound base:
# the reported "freezes for a second, then it keeps counting" stutter.
#
# The guard that was supposed to prevent this compared the incoming count
# against the last *read* count (`readElapsed < root.serviceElapsed`) rather
# than against what is actually on screen, so it never saw the rewind -- the
# display had already moved past the stale value via the local clock.
#
# The fix anchors on the service's own stamp (`recordingElapsedAtMs`, published
# by pix.recast beside the count) and ratchets through `_lastShownElapsed`, so a
# late or out-of-order snapshot can no longer move the chip backwards.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
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

[ -f "$RECAST" ] || { echo "no Recast.qml at $RECAST" >&2; exit 1; }

elapsed_block="$(sed -n '/readonly property int elapsed/,/^    }/p' "$RECAST")"
[ -n "$elapsed_block" ] || { echo "could not locate the elapsed binding" >&2; exit 1; }

# The anchor must come from the file's stamp, not from this process's clock.
has "the service's measurement stamp is read" \
    "$(grep -c 'data\.recordingElapsedAtMs' "$RECAST")" "data.recordingElapsedAtMs"

# A file from an older plugin has no stamp; it must degrade to "now" rather than
# to 0, which would extrapolate from the epoch and render an absurd count.
ok "a missing stamp falls back to now" \
    "$(grep -c 'data\.recordingElapsedAtMs > 0' "$RECAST")" "1"

# The display is ratcheted: `elapsed` returns the running maximum rather than the
# raw projection, so no late snapshot can rewind it.
ok "the display ratchets through a floor" \
    "$(printf '%s' "$elapsed_block" | grep -c '_elapsedFloor')" "3"

# The floor must NOT be a plain property. A binding that reads and writes the
# same property is a binding loop -- QML logs "Binding loop detected for
# property \"elapsed\"" and re-evaluates on every pass, which is what the first
# version of this ratchet did. Holding it in an object keeps the binding from
# depending on what it maintains.
ok "the floor is not a plain property (that would be a binding loop)" \
    "$(grep -c 'property var _elapsedFloor: ({ v: 0 })' "$RECAST")" "1"

no "no plain last-shown property is reintroduced" \
    "$(grep -c 'property int _lastShownElapsed' "$RECAST")"

# The ratchet must be cleared wherever the session ends, or the next take would
# inherit the previous one's count.
ok "the ratchet is cleared on every session reset" \
    "$(grep -c 'root\._elapsedFloor\.v = 0' "$RECAST")" "3"

# The old broken comparison must be gone: anchoring a stale read against the
# last read is what let the rewind through in the first place.
no "the last-read comparison is gone" \
    "$(grep -c 'readElapsed < root\.serviceElapsed' "$RECAST")"

# Paused sessions show a count too, and used to fall through to a bare
# `serviceElapsed`, which froze the chip for the whole pause.
ok "a paused session keeps the projected count" \
    "$(printf '%s' "$elapsed_block" | grep -c 'root\.recording || root\.paused')" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'