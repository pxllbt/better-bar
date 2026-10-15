#!/usr/bin/env bash
# Asserts that the Transparency setting actually changes the fill.
#
# The bug this exists for: LiquidGlass's opaque theme-background path was
# selected by `themeBackgroundFill && Theme.omarchyBackground !== ""` alone.
# The pill sets `themeBackgroundFill: true` and every Omarchy theme defines a
# background, so the pill's fill took the opaque branch and ignored `glassy`
# entirely. The only difference the toggle made anywhere was the top sheen
# disappearing, so "Transparency mode" -- labelled "Translucent pill · desktop
# shows through" -- was a switch that turned nothing on and nothing off.
#
# The tell is that a flag CAN be written, CAN be read, and still do nothing,
# because the reader bypasses it. A "is it referenced?" check passes here. The
# only way to catch this is to pin the relationship itself, so that is what this
# does: the opaque path must be gated on the flag being off.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GLASS="$ROOT/components/LiquidGlass.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$GLASS" ] || { echo "no LiquidGlass.qml at $GLASS" >&2; exit 1; }

# The whole definition may wrap across lines, so flatten before matching.
def=$(tr '\n' ' ' < "$GLASS" | grep -oE 'readonly property bool useThemeBg:[^;]*;' | head -1)

ok "useThemeBg is declared" \
    "$([ -n "$def" ] && echo yes || echo no)" "yes"

# Gated on the setting being OFF, so that turning it ON takes the translucent
# path instead of the opaque one.
ok "the opaque theme-background path is gated on the glass flag being off" \
    "$(printf '%s' "$def" | grep -c '!glass\.glassy')" "1"

ok "the opaque path still requires a theme background" \
    "$(printf '%s' "$def" | grep -c 'themeBackgroundFill')" "1"

ok "the opaque path still requires the theme to define a background" \
    "$(printf '%s' "$def" | grep -c 'omarchyBackground')" "1"

# The surfaces that opted into the opaque fill must keep it -- this is the
# default look when transparency is off, not a behaviour to delete.
ok "the pill body still asks for the theme background fill" \
    "$(grep -c 'themeBackgroundFill: true' "$ROOT/Pill.qml")" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
