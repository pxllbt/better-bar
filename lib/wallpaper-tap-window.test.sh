#!/usr/bin/env bash
# Asserts that releasing a wallpaper tile is always a selection, unless the
# hold reached the confirm threshold.
#
# Why this exists: the tile's tap was gated on `hold < tapThreshold`, and
# `tapThreshold` is 0.25 against a 900ms fill -- so a click only registered as
# a tap if the release came within the first 225ms of the press. `release()`
# returned early for anything after that:
#
#   if (fired || hold >= 1) return;        // held to confirm = trash
#   if (tapThreshold > 0 && hold < tapThreshold) tapped();
#   drain.restart();                       // 225ms..900ms -> nothing AT ALL
#
# So a normal, deliberate click released at 250ms, 400ms or 700ms did nothing:
# no selection, no error, no feedback. It read as the picker ignoring the user,
# and because it depended on how fast the mouse came up it was intermittent --
# which is the "sometimes it works, sometimes you have to spam it" report. The
# spam is not the fix, it is a coin toss that eventually lands inside the first
# 225ms.
#
# The confirm (the destructive hold) is a different gesture and unaffected: it
# fires at `hold >= 1`, the full 900ms. What was wrong is that the dead zone
# between a tap and a confirm silently ate every release in it.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACE="$ROOT/surfaces/Wallpaper.qml"
HEAT="$ROOT/components/HeatHold.qml"

failed=0
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}
hasnt() {
    if [ "$2" -eq 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' "$1" "$3"
    fi
}

[ -f "$SURFACE" ] || { echo "no Wallpaper.qml at $SURFACE" >&2; exit 1; }
[ -f "$HEAT" ] || { echo "no HeatHold.qml at $HEAT" >&2; exit 1; }

# 1. The tile must not gate its selection on the tap threshold.
# The selection lives in the MouseArea that shares the tile with `id: trashHeat`,
# so take from that marker through the end of the MouseArea, not just the
# HeatHold -- HeatHold closes before the MouseArea opens.
tile=$(awk '
    /id: trashHeat/ { grab = 1 }
    grab { print }
    grab && /^                \}$/ { exit }
' "$SURFACE")

[ -n "$tile" ] || { echo "FAIL could not locate the tile gesture block" >&2; exit 1; }
printf 'PASS the tile gesture block was located\n'

# The selection must not come from HeatHold's `tapped`, which is the gated path.
hasnt "the tile does not select through the tap-threshold-gated signal" \
    "$(printf '%s' "$tile" | grep -c 'onTapped: root.activate()')" \
    "onTapped: root.activate()"

# 2. Instead the release itself decides, and the only thing that disqualifies a
#    release from being a selection is an actual confirm -- which is the trash
#    gesture, unchanged.
release_block=$(awk '
    /^ *onReleased: \{/ { grab = 1 }
    grab { print }
    grab && /^ *\}$/ { exit }
' "$SURFACE")

if [ -z "$release_block" ]; then
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' "onReleased has a body" "onReleased: { ... }"
else
    printf 'PASS %s\n' "onReleased has a body"

    if printf '%s' "$release_block" | grep -q 'root.activate()'; then
        printf 'PASS %s\n' "a release that did not confirm applies the wallpaper"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' \
            "a release that did not confirm applies the wallpaper" "root.activate() in onReleased"
    fi

    if printf '%s' "$release_block" | grep -q 'trashHeat.fired'; then
        printf 'PASS %s\n' "the release checks whether the hold actually confirmed"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' \
            "the release checks whether the hold actually confirmed" "trashHeat.fired"
    fi
fi

# 3. The dead zone must be gone from the component too, so no other site can
#    inherit it. `release()` must still drain, but must not return early
#    between the tap and the confirm.
release_body=$(awk '/^    function release\(\)/{grab=1} grab{print} grab && /^    \}/{exit}' "$HEAT")

if printf '%s' "$release_body" | grep -qE 'if \(fired \|\| hold >= 1\)'; then
    printf 'PASS %s\n' "release() still lets a confirmed hold stand as trash"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "release() still lets a confirmed hold stand as trash" \
        "the confirm guard"
fi

# A plain early return in that middle band is the bug.
if printf '%s' "$release_body" | grep -qE 'tapThreshold > 0 && hold < tapThreshold'; then
    printf 'PASS %s\n' "release() no longer gates the tap on the threshold band"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected NOT to find: %s\n' \
        "release() no longer gates the tap on the threshold band" \
        "a threshold-gated tap"
fi

# 4. The threshold is still where the user's eye tells them they are committing
#    to a delete, so the feedback stays meaningful -- just much later than 225ms.
has "the threshold still exists for the visual commit feedback" \
    "$(grep -cE 'property real tapThreshold' "$HEAT")" \
    "tapThreshold"

has "the tile still shows commit progress while holding" \
    "$(grep -c 'commitProgress' "$SURFACE")" \
    "commitProgress"

# 5. And a hold that does confirm still trashes.
has "the hold-to-confirm still deletes" \
    "$(printf '%s' "$tile" | grep -c 'Walls.trash(')" \
    "Walls.trash()"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
