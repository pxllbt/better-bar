#!/usr/bin/env bash
# Asserts that game mode blocks every Better Bar surface control, and that
# turning it off restores them.
#
# Why this exists: game mode strips the desktop's eye-candy for gaming, but the
# bar's own keybindIPC door stayed wide open. Every one of the ~20 keybindings
# that open a surface (clipboard, launcher, wallpaper, mixer, calendar, power,
# sysmon, menus, settings pages) routes through `toggleSurface`, so while gaming
# a stray SUPER+SPACE or SUPER+CTRL+A would still morph the pill into a surface
# over the game -- the one thing game mode exists to prevent.
#
# The gate belongs at `toggleSurface` and not at each IPC handler: one check
# covers the IPC handlers, the pill's own requestSurface/requestPluginSurface
# (both funnel through it), and any future surface added to the register.
# Bespoke entry points that bypass `toggleSurface` (`peek`) are gated at their
# own handler.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SHELL_QML="$ROOT/shell.qml"
PILL_QML="$ROOT/Pill.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
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

[ -f "$SHELL_QML" ] || { echo "no shell.qml at $SHELL_QML" >&2; exit 1; }
[ -f "$PILL_QML" ] || { echo "no Pill.qml at $PILL_QML" >&2; exit 1; }

# 1. The single gate every surface opening passes through.
toggle_block=$(awk '/function toggleSurface/{grab=1} grab{print} grab && /^    }$/{exit}' "$SHELL_QML")
has "toggleSurface returns early while game mode is on" \
    "$(printf '%s\n' "$toggle_block" | grep -cE 'if \(Flags\.gameMode\)' )" \
    "if (Flags.gameMode) in toggleSurface"

# The gate must sit at the TOP of the function, before any surface is opened,
# or a late return would still have assigned openMon/openSurface.
first_line=$(printf '%s\n' "$toggle_block" | grep -nE 'openMon|openSurface|Flags\.gameMode|function toggleSurface' | head -1)
gate_line=$(printf '%s\n' "$toggle_block" | grep -nE 'Flags\.gameMode' | head -1 | cut -d: -f1)
open_line=$(printf '%s\n' "$toggle_block" | grep -nE 'root\.open(Mon|Surface) =' | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$open_line" ] && [ "$gate_line" -lt "$open_line" ]; then
    printf 'PASS %s\n' "the gate runs before any surface is opened"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  gate at line %s, first open at line %s\n' \
        "the gate runs before any surface is opened" "$gate_line" "$open_line"
fi

# 2. Entering game mode must dismiss whatever is already open.
has "turning game mode on closes any open surface" \
    "$(grep -c 'function onGameModeChanged' "$SHELL_QML")" \
    "onGameModeChanged"
close_block=$(awk '/function onGameModeChanged/{grab=1} grab{print} grab && /^        }$/{exit}' "$SHELL_QML")
has "the close on entering game mode is gated on the flag" \
    "$(printf '%s\n' "$close_block" | grep -cE 'if \(Flags\.gameMode\)')" \
    "if (Flags.gameMode)"

# 3. Entry points that bypass toggleSurface are gated themselves.
has "peek is blocked while game mode is on" \
    "$(grep -c 'function peek(mon: string): void { if (!Flags.gameMode)' "$SHELL_QML")" \
    "if (!Flags.gameMode) in peek"

# 4. The toggle itself must never be gated, or game mode could not be left.
has "the gameMode toggle stays reachable so it can be turned back off" \
    "$(grep -c 'function gameMode(mon: string): void { Flags.gameMode = !Flags.gameMode; }' "$SHELL_QML")" \
    "unguarded gameMode toggle"

# 5. The mode ladder: game must outrank every surface, so no face can win.
mode_block=$(awk '/readonly property string mode:/{grab=1} grab{print} grab && /^$/{exit}' "$PILL_QML")
if printf '%s' "$mode_block" | grep -qE 'dragActive \? "dragOver"' \
    && printf '%s' "$mode_block" | grep -qE 'Flags\.gameMode \? "game"' \
    && printf '%s' "$mode_block" | grep -qE 'pluginSurfaceOpen \? "plugin"'; then
    # Game must be tested before any surface-owning branch, and only dragOver
    # may precede it (a drag in flight is still a drag).
    drag_line=$(printf '%s\n' "$mode_block" | grep -nE 'dragActive' | head -1 | cut -d: -f1)
    game_line=$(printf '%s\n' "$mode_block" | grep -nE 'Flags\.gameMode' | head -1 | cut -d: -f1)
    plugin_line=$(printf '%s\n' "$mode_block" | grep -nE 'pluginSurfaceOpen' | head -1 | cut -d: -f1)
    surface_line=$(printf '%s\n' "$mode_block" | grep -nE 'surfaceOpen' | head -1 | cut -d: -f1)
    if [ "$drag_line" -lt "$game_line" ] && [ "$game_line" -lt "$plugin_line" ] \
        && [ "$game_line" -lt "$surface_line" ]; then
        printf 'PASS %s\n' "the mode ladder puts game ahead of every surface"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  drag=%s game=%s plugin=%s surface=%s\n' \
            "the mode ladder puts game ahead of every surface" \
            "$drag_line" "$game_line" "$plugin_line" "$surface_line"
    fi
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  could not find all three modes in the ladder\n' \
        "the mode ladder puts game ahead of every surface"
fi

# 6. The strip face must not render in game mode: it is clickable and wide.
strip_line=$(grep -E '^\s*visible: pill\.specialView === "" ' "$PILL_QML" | head -1)
has "the strip face is hidden while game mode is on" \
    "$(printf '%s\n' "$strip_line" | grep -c '!Flags.gameMode')" \
    "!Flags.gameMode on the strip face"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
