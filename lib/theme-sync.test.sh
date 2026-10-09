#!/usr/bin/env bash
# Asserts the bar actually re-reads the theme after a theme switch.
#
# The bug this exists for: Commons/Color.qml loaded colors.toml and shell.toml
# through two FileViews with `watchChanges: false`, and nothing else ever called
# loadColors()/loadShell() again. The in-file comment claimed "runtime theme
# switches push the payload explicitly through shell IPC" -- there is no such
# IPC handler anywhere in the tree. So `omarchy theme set`, and any newly
# installed theme, left the foundational palette, every popups/bar/tooltip role
# and all shell.toml typography frozen at whatever the theme was at startup. The
# bar's own ThemeSync noticed the switch and bumped its revision (wallpaper,
# accent-derived bits moved), which is exactly what makes the failure look like
# "half synced" rather than "not synced".
#
# The reload cannot simply be hung off the theme directory: omarchy installs a
# theme with `rm -rf; mv`, so current/theme is a symlink that is replaced
# wholesale and any watch bound to the old inode goes permanently deaf. The file
# this suite requires is theme.name, which omarchy rewrites in place with
# `echo >` on the same inode -- the same reason ThemeSync watches that path and
# not colors.toml.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
COLOR="$ROOT/Commons/Color.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$COLOR" ] || { echo "no Color.qml at $COLOR" >&2; exit 1; }

ok "ThemeSync watches theme.name, the inode that survives a swap" \
    "$(grep -c 'themeNamePath: root.stateDir + "/theme.name"' "$ROOT/Singletons/ThemeSync.qml")" "1"

# ThemeSync must forward a theme switch to a full theme-file reload.
ok "the theme watcher drives Color.reloadTheme" \
    "$(grep -c 'Color.reloadTheme()' "$ROOT/Singletons/ThemeSync.qml")" "1"

# The whole point: a theme change has to reach BOTH theme files, through one
# path that re-resolves the swapped symlink.
ok "a theme change reloads both theme files" \
    "$(sed -n '/function reloadTheme/,/^  }/p' "$COLOR" | grep -cE 'colorsFile\.reload\(\)|shellFile\.reload\(\)')" "2"

# shell.toml drives typography, spacing and every popup role, so a theme that
# ships one must not be silently ignored.
ok "shell.toml is still read" \
    "$(grep -c 'currentThemePath + "/shell.toml"' "$COLOR")" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'