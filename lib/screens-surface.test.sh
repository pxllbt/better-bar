#!/usr/bin/env bash
# Asserts the shape of surfaces/ScreensSurface.qml.
#
# Why this exists: a surface can look right, load, and still do the wrong thing.
# Three things are invisible in a UI test and obvious in a text one -- a hard-
# coded hex colour that will not follow the theme, a pixel size that will not
# follow the pill's scale, and an edit that writes Screens.live straight back
# (so the draft and reality silently diverge and the canvas never reflows). The
# rest pins the contract the pill and the writer depend on: the title, the Sysmon
# margins, that only the singleton talks to hyprctl, that the last enabled screen
# cannot be turned off, and that polling stops when the surface closes.
#
# The file is surfaced as ScreensSurface rather than Screens because the
# `Screens` singleton already owns that type name, the same reason the Sysmon
# singleton's surface is SysmonSurface.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
F="$ROOT/surfaces/ScreensSurface.qml"
QMLDIR="$ROOT/surfaces/qmldir"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}
# True when the count argument is at least 1.
any() { if [ "$2" -ge 1 ]; then echo yes; else echo no; fi; }

[ -f "$F" ] || { echo "no ScreensSurface.qml at $F" >&2; exit 1; }

# -- title ---------------------------------------------------------------
ok "the surface declares its own SCREENS title" \
    "$(grep -c 'text: "SCREENS"' "$F")" "1"
ok "the surface passes no glyph (the kanji marks are gone)" \
    "$(grep -ci 'glyph' "$F")" "0"

# -- the Sysmon margins --------------------------------------------------
ok "canvas top margin is 14" "$(grep -cE 'mTop:[[:space:]]*14$' "$F")" "1"
ok "canvas left margin is 16" "$(grep -cE 'mLeft:[[:space:]]*16$' "$F")" "1"
ok "canvas right margin is 16" "$(grep -cE 'mRight:[[:space:]]*16$' "$F")" "1"
ok "canvas bottom margin is 16" "$(grep -cE 'mBottom:[[:space:]]*16$' "$F")" "1"

# -- colours and sizes ---------------------------------------------------
ok "no literal hex colour appears" \
    "$(grep -cE '#[0-9a-fA-F]{3,8}\b' "$F")" "0"
ok "every colour reference resolves through a Theme token" \
    "$(grep -nE '^[[:space:]]*color:' "$F" | grep -vc 'Theme\.')" "0"
ok "every text size is scaled from root.s" \
    "$(grep -nE 'font\.pixelSize:' "$F" | grep -cvE 'font\.pixelSize:[[:space:]]*[0-9]+([[:space:]]*\*[[:space:]]*root\.s)?$')" "0"
ok "letter spacing is scaled from root.s" \
    "$(grep -nE 'font\.letterSpacing:' "$F" | grep -cvE 'font\.letterSpacing:[[:space:]]*[0-9.]+[[:space:]]*\*[[:space:]]*root\.s$')" "0"

# -- what drives the canvas ---------------------------------------------
ok "the canvas is driven by Screens.draft" \
    "$(any canvas "$(grep -c 'Screens\.draft' "$F")")" "yes"
ok "the canvas reads Screens.focusIndex" \
    "$(any focus "$(grep -c 'Screens\.focusIndex' "$F")")" "yes"
ok "no edit writes Screens.live directly" \
    "$(grep -cE 'Screens\.live[[:space:]]*=[^=]' "$F")" "0"
ok "the surface reads its focus screen through the singleton" \
    "$(any focusScreen "$(grep -c 'Screens\.focusScreen' "$F")")" "yes"

# -- keys: the only way to move a screen --------------------------------
ok "the canvas handles the arrow keys" \
    "$(any keys "$(grep -cE 'Keys[[:space:]]*\{|Keys\.' "$F")")" "yes"
ok "the surface never calls hyprctl itself" \
    "$(grep -c 'hyprctl' "$F")" "0"
ok "every key moves or edits through a Screens function" \
    "$(any edits "$(grep -c 'Screens\.\(updateDraft\|nudge\|setFocus\)' "$F")")" "yes"

# -- the last-screen rule ------------------------------------------------
ok "the surface counts the enabled screens" \
    "$(grep -cE 'readonly property int enabledCount' "$F")" "1"
ok "the last enabled screen cannot be turned off" \
    "$(any guard "$(grep -cE 'enabledCount[^;]*<=' "$F")")" "yes"

# -- polling stops on close ---------------------------------------------
ok "Screens.open is bound to the surface's active state" \
    "$(grep -cE 'onActiveChanged:[[:space:]]*Screens\.open[[:space:]]*=[[:space:]]*active' "$F")" "1"

# -- registration --------------------------------------------------------
ok "the surface is registered as a component" \
    "$(grep -cE '^ScreensSurface[[:space:]]+ScreensSurface\.qml$' "$QMLDIR")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
