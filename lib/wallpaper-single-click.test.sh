#!/usr/bin/env bash
# Asserts that a wallpaper click applies on the first press, and that the
# wallpaper transition is bounded rather than left on awww's 3s default.
#
# Why these two together: they are the two things a user hits when picking
# wallpapers, and both failed in a way that read as "this picker is broken"
# rather than as two separate defects.
#
#   * First-press apply -- onPressed used to return early unless the tile was
#     already focused, so a click on any other tile only moved the selection.
#     Combined with centerOnCurrent() re-centring the strip after every apply,
#     focus moved away under the pointer and the number of clicks needed
#     depended on timing.
#   * Transition duration -- awww defaults --transition-duration to 3 seconds
#     and the script never passed it, so every change animated for three
#     seconds. Raising --transition-step or --transition-fps does not shorten
#     it, which is why tuning those had no effect.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACE="$ROOT/surfaces/Wallpaper.qml"
SCRIPT="$ROOT/scripts/wallpaper.sh"

failed=0
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$SURFACE" ] || { echo "no Wallpaper.qml at $SURFACE" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "no wallpaper.sh at $SCRIPT" >&2; exit 1; }

# The tile press handler is the one that guards trashHeat, so anchor the
# extraction on that rather than on the first `onPressed` in the file, which
# belongs to an unrelated button.
press_block=$(awk '
    /onPressed: \{/ { buf = $0; grab = 1; next }
    grab {
        buf = buf "\n" $0
        if ($0 ~ /^ *\}$/) {
            if (buf ~ /trashHeat/) printf "%s", buf
            grab = 0; buf = ""
        }
    }
' "$SURFACE")

# 1. A click must apply, not just select.
#
# The precise invariant is that the press handler never bails out early. Testing
# for the absence of `if (!tile.focused)` would be wrong: that guard is still
# there, and legitimately so -- it is what moves focus onto the clicked tile.
# What was broken was it being followed by `return`, so an unfocused click did
# nothing at all instead of applying.
if printf '%s' "$press_block" | grep -qE '(^|[^_[:alnum:]])return'; then
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the press handler never returns early" \
        "no return in onPressed"
else
    printf 'PASS %s\n' "the press handler never returns early"
fi

has "press moves focus to the clicked tile" \
    "$(printf '%s' "$press_block" | grep -c 'root.focusIndex = tile.gridIndex')" \
    "root.focusIndex = tile.gridIndex"

has "press still applies via activate()" \
    "$(printf '%s' "$press_block" | grep -c 'root.activate()')" \
    "root.activate()"

has "press still arms the hold-to-trash gesture" \
    "$(printf '%s' "$press_block" | grep -c 'trashHeat.press()')" \
    "trashHeat.press()"

# 2. The transition must be bounded.
has "wallpaper.sh passes an explicit transition duration" \
    "$(grep -c -- '--transition-duration' "$SCRIPT")" "--transition-duration"

has "the duration is not awww's 3s default" \
    "$(grep -c 'TRANSITION_SECONDS=' "$SCRIPT")" "TRANSITION_SECONDS"

has "the default transition is under a second" \
    "$(grep -c 'wallpaperTransitionSeconds // 0.5' "$SCRIPT")" "0.5s default"

# The wave is kept -- only its length changed -- so a sweep must still be there.
has "the wave transition is kept" \
    "$(grep -c -- '--transition-type wave' "$SCRIPT")" "--transition-type wave"

# 3. The duration must actually reach awww, not just be defined.
if grep -A8 -- '--transition-type wave' "$SCRIPT" | grep -q -- '--transition-duration "\$TRANSITION_SECONDS"'; then
    printf 'PASS %s\n' "the bounded duration reaches the awww call"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the bounded duration reaches the awww call" \
        '--transition-duration "$TRANSITION_SECONDS" on the awww call'
fi

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
