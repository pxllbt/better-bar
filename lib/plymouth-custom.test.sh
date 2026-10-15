#!/usr/bin/env bash
# Asserts the Plymouth unlock surface is a full customiser, not only a mirror of
# the desktop theme.
#
# Why this exists: the surface used `omarchy-plymouth-set-by-theme`, which is a
# preset picker — clicking a theme repaints the unlock screen from that theme's
# unlock.png. That made the boot screen always track the desktop theme and left
# no way to make it the user's own. Omarchy's custom path is
# `omarchy-plymouth-set <bg> <text> <logo>`; this surface must expose exactly
# that, plus the stock/theme shortcuts.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLAGS="$ROOT/Singletons/Flags.qml"
SURFACE="$ROOT/surfaces/PlymouthSurface.qml"

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
[ -f "$SURFACE" ] || { echo "no PlymouthSurface.qml at $SURFACE" >&2; exit 1; }

ok "custom plymouth background is persisted" \
    "$(grep -c 'property alias plymouthBg' "$FLAGS")" "1"

ok "custom plymouth text is persisted" \
    "$(grep -c 'property alias plymouthText' "$FLAGS")" "1"

ok "custom plymouth logo path is persisted" \
    "$(grep -c 'property alias plymouthLogo' "$FLAGS")" "1"

ok "custom background defaults to a hex" \
    "$(grep -c 'property string plymouthBg: "#1a1b26"' "$FLAGS")" "1"

ok "custom text defaults to a hex" \
    "$(grep -c 'property string plymouthText: "#ebdbb2"' "$FLAGS")" "1"

ok "custom logo defaults to the stock logo path" \
    "$(grep -c 'readonly property string stockLogo' "$SURFACE")" "1"

ok "surface uses the Plymouth model singleton" \
    "$(grep -c 'Plymouth.stockLogo' "$SURFACE")" "1"

ok "Plymouth model singleton is registered" \
    "$(grep -c 'singleton Plymouth Plymouth.qml' "$ROOT/Singletons/qmldir")" "1"

ok "surface validates hex input" \
    "$(grep -c 'function isHex' "$SURFACE")" "1"

ok "background row is typable" \
    "$(grep -c 'onAccepted: root.setBg(text)' "$SURFACE")" "1"

ok "text row is typable" \
    "$(grep -c 'onAccepted: root.setTextColor(text)' "$SURFACE")" "1"

ok "logo row opens the desktop file chooser" \
    "$(grep -c 'omarchy-file-select' "$SURFACE")" "1"

ok "apply uses the custom Plymouth command" \
    "$(grep -c 'omarchy-plymouth-set ' "$SURFACE")" "1"

ok "apply passes the three custom arguments" \
    "$(grep -c 'root.shellArg(root.activeLogo)' "$SURFACE")" "1"

ok "active logo falls back to stock when empty" \
    "$(grep -c 'readonly property string activeLogo' "$SURFACE")" "1"

ok "theme presets remain available" \
    "$(grep -c 'omarchy-plymouth-set-by-theme' "$SURFACE")" "2"

ok "stock reset remains available" \
    "$(grep -c 'omarchy-plymouth-reset' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
