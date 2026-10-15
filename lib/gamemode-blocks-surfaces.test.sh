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

# 7. Auto-hide: a tap on the revealed strip must expand the pill, not open the
#    media surface. The hover path gates the media takeover behind
#    `!Flags.autoHide && !pill.stripBar`; the tap did not, so with anything
#    playing a click opened the player and the hoverLatch toggle -- the only
#    expand entry point under a reveal session -- was dead.
tap_block=$(awk '/TapHandler \{/{grab=1} grab{print} grab && /^    }$/{exit}' "$PILL_QML" | head -40)
if printf '%s' "$tap_block" | grep -q 'Flags.expandTo === "media"'; then
    if printf '%s' "$tap_block" | grep -q '!Flags.autoHide && !pill.stripBar'; then
        printf 'PASS %s\n' "the tap media takeover is guarded by the same rule as the hover path"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected the tap guard to read: !Flags.autoHide && !pill.stripBar\n' \
            "the tap media takeover is guarded by the same rule as the hover path"
    fi
    # And the hover path it must match really does carry a guard, or the two have
    # drifted apart without this noticing.
    #
    # The guard is no longer a literal string match: the hover branch used to
    # read `!Flags.autoHide && !pill.stripBar`, and that `!stripBar` half was the
    # bug — it made the one display mode that most wants the player on hover (the
    # full-width top bar) the one mode where the hover did nothing. It is now
    # `mode !== "game"`, which is the guard game mode actually needs, asserted
    # above. So this checks the media branch is still gated on something at all
    # rather than on the removed wording.
    hover_block=$(awk '/function onHoveredChanged|onHoveredChanged: \{/{grab=1} grab{print} grab && /^    \}/ {exit}' "$PILL_QML")
    has "the hover path still gates its media branch" \
        "$(printf '%s' "$hover_block" | grep -c 'pill.mode !== "game"')" \
        "mode !== game guard in onHoveredChanged"
    # This one is a "must NOT match", which `has` cannot express (it requires a
    # hit), so it is asserted as a count being zero.
    if [ "$(printf '%s' "$hover_block" | grep -c '!pill.stripBar')" -eq 0 ]; then
        printf 'PASS %s\n' "the hover media branch no longer excludes strip mode"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: no !pill.stripBar in the hover media branch\n' \
            "the hover media branch no longer excludes strip mode"
    fi
else
    printf 'PASS %s\n' "the tap has no media takeover to guard"
fi

# 8. And under auto-hide the tap must actually reach the expand toggle.
if printf '%s' "$tap_block" | grep -q 'pill.hoverLatch = !pill.hoverLatch'; then
    printf 'PASS %s\n' "the tap toggles hoverLatch, which is how auto-hide expands"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the tap toggles hoverLatch, which is how auto-hide expands" "hoverLatch = !hoverLatch"
fi

# 9. screens: the monitor-layout surface. Opening it must be blocked while game
#    mode is on, which it is by routing through toggleSurface; but its rescue
#    command must NOT be, because rescue exists for the case where the layout is
#    already wrong (a black screen) and the game-mode gate would refuse it at
#    exactly the moment it is needed. So: `screens` goes through the gate,
#    `screensrescue` deliberately bypasses it and only repairs the layout --
#    it never opens the surface.
has "the screens opener routes through the game-mode-gated toggleSurface" \
    "$(grep -cE 'function[[:space:]]+screens\(mon:[[:space:]]*string\)[^{]*\{[^}]*toggleSurface\(mon,[[:space:]]*"screens"\)' "$SHELL_QML")" \
    "screens -> toggleSurface"
rescue_fn=$(grep -E 'function[[:space:]]+screensrescue\(' "$SHELL_QML")
has "the screens rescue calls Screens.rescue()" \
    "$(printf '%s\n' "$rescue_fn" | grep -c 'Screens\.rescue()')" \
    "Screens.rescue() in screensrescue"
# Negative assertions: count must be exactly zero, so `ok` (equality), not `has`.
ok "the screens rescue is not game-mode gated" \
    "$(printf '%s\n' "$rescue_fn" | grep -cE 'Flags\.gameMode|!Flags\.gameMode')" "0"
ok "the screens rescue never opens a surface" \
    "$(printf '%s\n' "$rescue_fn" | grep -c 'toggleSurface')" "0"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
