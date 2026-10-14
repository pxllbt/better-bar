#!/usr/bin/env bash
# Asserts that Theme.dim -- the dimmed-text token -- follows the active theme.
#
# Why this exists: `dim` was the only secondary text token in Theme.qml that did
# not consult the omarchy palette at all. Its siblings all read a colour from
# colors.toml first:
#
#   cream    -> foreground
#   bright   -> bright_foreground
#   subtle   -> light_foreground
#   faint    -> muted
#   dim      -> nothing. Hardcoded "#8c8c8c", warm "#6b635c" on light.
#
# Every shipped omarchy theme names `dark_foreground` -- the "dimmer than normal
# text" key -- so the value was available and simply went unread. The calendar's
# weekday headers are the visible consequence: they paint with
# `wd.weekend ? Theme.faint : Theme.dim`, so the non-weekend days came out a
# neutral grey next to today's theme accent and the theme's own foreground.
#
# It read as "this colour is not synced" rather than as a missing token, because
# the tile and the accent around it were themed correctly. The two tokens are
# side by side in the same surface, so the mismatch was more obvious than a
# single wrong colour would have been.
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
hasnt() {
    if [ "$2" -eq 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' "$1" "$3"
    fi
}

[ -f "$THEME" ] || { echo "no Theme.qml at $THEME" >&2; exit 1; }

# 1. The theme's dim-foreground key must be bridged in, as its siblings are.
has "Theme bridges the theme's dark_foreground" \
    "$(grep -c 'omarchyDarkFg' "$THEME")" \
    "omarchyDarkFg"

# 2. And dim must prefer it, the same way faint prefers muted.
dim_line=$(grep -E 'readonly property color dim:' "$THEME")
if [ -z "$dim_line" ]; then
    failed=$((failed + 1))
    printf 'FAIL the dim token exists\n'
else
    printf 'PASS %s\n' "the dim token exists"

    if printf '%s' "$dim_line" | grep -q 'omarchyDarkFg'; then
        printf 'PASS %s\n' "dim follows the theme's dark_foreground"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' \
            "dim follows the theme's dark_foreground" "omarchyDarkFg in the dim token"
    fi

    # The fallback must stay, so a theme that omits the key still dims.
    if printf '%s' "$dim_line" | grep -q '#8c8c8c'; then
        printf 'PASS %s\n' "dim keeps its fallback for a theme without the key"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' \
            "dim keeps its fallback for a theme without the key" "the hardcoded fallback"
    fi
fi

# 3. The manual and dynamic modes must still win in their own order: those are
#    modes where the user asked for something other than the theme.
if printf '%s' "$dim_line" | grep -qE 'manual \? .*dynamic \?'; then
    printf 'PASS %s\n' "dim keeps manual and dynamic ahead of the theme"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "dim keeps manual and dynamic ahead of the theme" "manual ? ... dynamic ?"
fi

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
