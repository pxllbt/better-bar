#!/usr/bin/env bash
# Asserts the media bud is still reachable when nothing is playing.
#
# Why this exists: the media bud was gated on `Players.has`, so as soon as the
# last player exited it vanished entirely. That is correct for the *player
# detail* in the pill, but wrong for the media *entry point*: the bar lost the
# click target for the media surface, and the only way to see it again was to
# start audio. A media entry that disappears with its content is not an entry.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLAGS="$ROOT/Singletons/Flags.qml"
PILL="$ROOT/Pill.qml"
SURFACE="$ROOT/surfaces/DisplaySurface.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$FLAGS" ] || { echo "no Flags.qml at $FLAGS" >&2; exit 1; }
[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

ok "the always-media flag is persisted" \
    "$(grep -c 'property alias mediaAlways' "$FLAGS")" "1"

ok "always-media defaults to on so the control comes back" \
    "$(grep -c 'property bool mediaAlways: true' "$FLAGS")" "1"

ok "the media bud survives with no active player" \
    "$(grep -c 'readonly property bool shown: (pill.mode === "rest" || pill.mode === "hover")' "$PILL")" "1"

ok "playing media forces the bud on even when always-media is off" \
    "$(grep -c '(Flags.mediaAlways || Players.playing)' "$PILL")" "1"

ok "the media bud still opens the media surface" \
    "$(grep -c 'onClicked: pill.requestSurface("media")' "$PILL")" "1"

ok "the interface settings expose the always-media toggle" \
    "$(grep -c 'id: mediaAlwaysRow' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
