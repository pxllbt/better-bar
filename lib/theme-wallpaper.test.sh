#!/usr/bin/env bash
# Tests that a theme switch changes the wallpaper, and that a wallpaper you pick
# is still protected from one arriving on its own.
#
# The bug: switching from lawson-night to cyberpunk left the wallpaper untouched.
# Not because omarchy failed to pick one -- it chose cyberpunk/backgrounds/circuit.png
# and wrote the symlink. Better Bar then refused it, because the guard treats any
# recorded pick as outranking any theme wallpaper, and repointed the link back.
# The guard was right for the case it was built for -- a theme wallpaper arriving
# unasked, which made the wallpaper look like it kept snapping back -- and wrong
# for the case it was also catching: a theme switch you asked for.
#
# The rule that separates them is which theme the pick was made under:
#
#   made on the theme still current -> keep it (the snapping-back case)
#   made on any other theme        -> the switch wins
#   no theme recorded              -> the switch wins (an install predating the
#                                     record would otherwise be stuck forever)
#
# Every case runs the real script against a fake HOME and XDG_STATE_HOME.

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WALLSH="$ROOT/scripts/wallpaper.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

# Wallpaper.sh's own state files, resolved at use time: setup() rebinds
# XDG_STATE_HOME, so expanding them once at the top would aim every case at the
# wrong sandbox.
state_file() { printf '%s\n' "$XDG_STATE_HOME/better-wallpaper"; }
pick_marker() { printf '%s\n' "$XDG_STATE_HOME/better-wallpaper-picks"; }
picked_theme() { printf '%s\n' "$XDG_STATE_HOME/better-wallpaper-pick-theme"; }

USER_BG=""
THEME_BG=""
OTHER_THEME_BG=""

setup() {
    rm -rf "$TMP/home" "$TMP/state"
    export HOME="$TMP/home"
    export XDG_STATE_HOME="$TMP/state"

    mkdir -p "$HOME/.local/state/omarchy/current/theme/backgrounds"
    mkdir -p "$HOME/.config/omarchy/themes/other-theme/backgrounds"
    mkdir -p "$HOME/Downloads/Wallpaper"
    # The script reads and writes here, so the directory has to exist before any
    # run rather than being created as a side effect of one.
    mkdir -p "$XDG_STATE_HOME"

    USER_BG="$HOME/Downloads/Wallpaper/mine.png"
    THEME_BG="$HOME/.local/state/omarchy/current/theme/backgrounds/theme.png"
    OTHER_THEME_BG="$HOME/.config/omarchy/themes/other-theme/backgrounds/other.png"

    printf 'picked\n' >"$USER_BG"
    printf 'theme\n' >"$THEME_BG"
    printf 'other\n' >"$OTHER_THEME_BG"
}

set_theme() { printf '%s\n' "$1" >"$HOME/.local/state/omarchy/current/theme.name"; }

# Model "the wallpaper on screen is the user's own pick". $STATE is wallpaper.sh's
# record of what is current, and should_apply reads it; writing it directly keeps
# this test on the guard's decision path rather than the paint path, which is
# where awww and a missing codec would otherwise take the run.
user_is_showing() {
    printf '%s\n' "$USER_BG" >"$(state_file)"
    bash "$WALLSH" mark-pick "$USER_BG" >/dev/null 2>&1
}

can_apply() { bash "$WALLSH" should-apply "$1" "${2:-}" >/dev/null 2>&1 && echo yes || echo no; }

# --- still on the theme the pick was made under --------------------------
setup
set_theme "lawson-night"
user_is_showing
ok "a pick made on this theme is protected from a theme wallpaper arriving on its own" \
    "$(can_apply "$THEME_BG")" "no"

# --- the switch the user asked for --------------------------------------
setup
set_theme "lawson-night"
user_is_showing
# The theme changes; omarchy already repointed current/background at the new
# theme's wallpaper, and the bar follows it.
set_theme "other-theme"
ok "a pick made on another theme does not block this theme's wallpaper" \
    "$(can_apply "$THEME_BG")" "yes"

# End to end: the wallpaper on screen really changes.
setup
set_theme "lawson-night"
user_is_showing
set_theme "other-theme"
bash "$WALLSH" set "$OTHER_THEME_BG" >/dev/null 2>&1
ok "switching theme changes the wallpaper" \
    "$(readlink "$HOME/.local/state/omarchy/current/background" 2>/dev/null |
        xargs -r basename 2>/dev/null || echo none)" "other.png"

# The old pick must not keep governing after the theme's wallpaper took over, or
# the next arrival would try to restore it -- the wallpaper snapping back. What
# is on screen is now the theme's own wallpaper, so ownership has moved with it.
setup
set_theme "lawson-night"
user_is_showing
set_theme "other-theme"
bash "$WALLSH" set "$OTHER_THEME_BG" >/dev/null 2>&1
ok "once the theme's wallpaper is on screen, the old pick no longer governs" \
    "$(can_apply "$THEME_BG")" "yes"

# --- what gets recorded ------------------------------------------------
setup
set_theme "lawson-night"
user_is_showing
ok "a pick records the theme it was made under" \
    "$(cat "$(picked_theme)" 2>/dev/null || echo none)" "lawson-night"

# --- the upgrade path --------------------------------------------------
# A pick recorded before this rule existed says nothing about its theme.
# Treating that as "this theme" would freeze every existing install on its
# current wallpaper forever, which is the complaint this is fixing.
setup
set_theme "lawson-night"
printf '%s\n' "$USER_BG" >"$(state_file)"
bash "$WALLSH" mark-pick "$USER_BG" >/dev/null 2>&1
rm -f "$(picked_theme)"
ok "a pick with no recorded theme yields to the theme's wallpaper" \
    "$(can_apply "$THEME_BG")" "yes"

# ...but only when there was a pick. A wallpaper on screen that nobody picked is
# not a pick, and keeps the original protection.
setup
set_theme "lawson-night"
printf '%s\n' "$USER_BG" >"$(state_file)"
ok "a wallpaper nobody ever picked still keeps the original protection" \
    "$(can_apply "$THEME_BG")" "no"

# --- an explicit force still wins, always ------------------------------
setup
set_theme "lawson-night"
user_is_showing
ok "--force still overrides the guard" \
    "$(can_apply "$THEME_BG" --force)" "yes"

# --- nothing recorded at all ------------------------------------------
setup
set_theme "lawson-night"
ok "a wallpaper with no pick in play is always applied" \
    "$(can_apply "$THEME_BG")" "yes"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'