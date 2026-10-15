#!/usr/bin/env bash
# Asserts the media bud bead follows the active theme.
#
# Why this exists: the bead's gradient used `Theme.flameInk` and
# `Theme.flameEmber`. Those are flame-canvas tokens with warm fallbacks, and
# they do not consult the omarchy accent in a static palette. The two middle
# stops used `verm`/`vermLit`, which do. The result was a bud whose centre was
# blue and whose ends were orange/red on the same pill: not synced.
#
# The bud is small, but it sits directly on the pill's edge, so a wrong one is
# exactly the sort of "why is only this colour off" detail this bar cannot
# carry. The fix uses theme-aware tokens for every stop.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PILL="$ROOT/Pill.qml"

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

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# The bead canvas only. A global grep would match the broken-plugin icons above
# it, which legitimately use the verm family.
bead=$(sed -n '/id: budBead/,/^        }$/p' "$PILL")
[ -n "$bead" ] || { echo "could not locate the media bud bead" >&2; exit 1; }

hasnt "the bead no longer uses the warm flame endpoints" \
    "$(printf '%s\n' "$bead" | grep -cE 'Theme\.(flameInk|flameEmber)')" "0"

has "the bead paints its inner stop from the theme accent" \
    "$(printf '%s\n' "$bead" | grep -c 'Theme.todayWarm')" "1"

has "the bead paints its dark stops from the theme verm family" \
    "$(printf '%s\n' "$bead" | grep -c 'Theme.vermDim')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
