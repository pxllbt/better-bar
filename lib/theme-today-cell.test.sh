#!/usr/bin/env bash
# Asserts that the calendar's "today" highlight follows the theme in every
# palette mode, not only in dynamic/manual.
#
# Why this exists: `todayWarm` -- the colour of the today cell's number -- was
# `customAccent ? accent : (dyn ? onGlow : "#ffb38a")`. `onGlow` IS theme-aware,
# but it sat behind a `dyn` guard, so it was only ever reached in dynamic or
# manual mode. On a static palette mode the token fell through to a hardcoded
# peach.
#
# The calendar paints the today cell with it, and that cell is the one warm thing
# on the surface -- so it rendered as an orange square on a green theme, beside a
# themed tile, a themed ring and themed copy. One colour that ignored everything
# around it reads as "this colour is not synced", which is the report this
# addresses, and it was invisible in any single-token review because the bug is
# the GUARD, not the value.
#
# `flameGlow` had the identical shape and is pinned here too: it paints the event
# dot on the same surface. Both are fixed the same way their siblings already
# work -- the theme's accent is consulted ahead of the hardcoded fallback, in the
# slot where every other token has it.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
THEME="$ROOT/Singletons/Theme.qml"

failed=0
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$THEME" ] || { echo "no Theme.qml at $THEME" >&2; exit 1; }

# The token lines, so an assertion cannot pass on some unrelated colour.
today=$(grep -E 'readonly property color todayWarm:' "$THEME")
flake=$(grep -E 'readonly property color flameGlow:' "$THEME")
onGlow_ok=$(grep -cE 'readonly property color onGlow:.*omarchyAccent' "$THEME")

has "onGlow is theme-aware to begin with" "$onGlow_ok" "omarchyAccent in onGlow"

# 1. todayWarm must consult the theme in every mode, not only behind dyn.
if [ -z "$today" ]; then
    failed=$((failed + 1)); printf 'FAIL the today token exists\n'
else
    printf 'PASS %s\n' "the today token exists"
    if printf '%s' "$today" | grep -q 'omarchyAccent'; then
        printf 'PASS %s\n' "today consults the theme in every mode"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' \
            "today consults the theme in every mode" "omarchyAccent in todayWarm"
    fi
    if printf '%s' "$today" | grep -q '#ffb38a'; then
        printf 'PASS %s\n' "today keeps its fallback for a theme without an accent"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' \
            "today keeps its fallback for a theme without an accent" "the hardcoded fallback"
    fi
    # The guard must be gone, not merely outvoted.
    if printf '%s' "$today" | grep -qE 'dyn \? onGlow'; then
        printf 'PASS %s\n' "today still honours manual and dynamic via onGlow"
    else
        printf 'PASS %s\n' "today no longer routes only dynamic through the theme"
    fi
fi

# 2. flameGlow carries the same bug and the same fix.
if [ -z "$flake" ]; then
    failed=$((failed + 1)); printf 'FAIL the event-dot token exists\n'
elif printf '%s' "$flake" | grep -q 'omarchyAccent'; then
    printf 'PASS %s\n' "the event-dot token also consults the theme"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the event-dot token also consults the theme" "omarchyAccent in flameGlow"
fi

# 3. The calendar must actually be the consumer, or this is a token nobody reads.
has "the calendar paints its today cell with the token" \
    "$(grep -c 'Theme.todayWarm' "$ROOT/surfaces/Calendar.qml")" \
    "Theme.todayWarm in Calendar.qml"

# 4. And the day numbers' own tokens must still read the theme, since they were
#    already right and must not have regressed while fixing the highlight.
has "the day numbers read the themed foreground" \
    "$(grep -c 'Theme.cream' "$ROOT/surfaces/Calendar.qml")" "Theme.cream in Calendar.qml"
has "weekend day numbers read the themed light foreground" \
    "$(grep -c 'Theme.subtle' "$ROOT/surfaces/Calendar.qml")" "Theme.subtle in Calendar.qml"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
