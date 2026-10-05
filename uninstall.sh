#!/usr/bin/env bash
# Remove Better Bar, whichever way it was installed.
#
# Two installs are supported and this cleans up both:
#
#   plugin      omarchy plugin add https://github.com/pxllbt/better-bar.git
#               The bar runs inside omarchy-shell. `omarchy plugin remove` is
#               the supported door and is used here when it is available.
#
#   standalone  curl ... | bash  (remote-install.sh)
#               The bar is a separate quickshell instance under
#               ~/.local/share/quickshell/better-bar, and the stock bar was
#               hidden so the two would not overlap.
#
# Usage:
#   uninstall.sh            remove program files, plugin, and state
#   uninstall.sh --dry-run  print every path that would be removed, touch nothing
#   uninstall.sh --keep-state
#                           remove program files and the plugin, keep the saved
#                           theme, accent, wallpaper and dock choices
#
# Run it with --dry-run first if you like: it prints the exact list.
set -eu

DRY_RUN=0
KEEP_STATE=0

# Print the header comment as usage. It runs from line 2 to the last comment
# line before the first blank one; matching on the terminator rather than a
# line number keeps it correct when the header grows.
usage() {
    awk 'NR < 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --keep-state) KEEP_STATE=1 ;;
        -h | --help) usage; exit 0 ;;
        *)
            echo "uninstall.sh: unknown option '$arg' (try --help)" >&2
            exit 1
            ;;
    esac
done

# Resolved from XDG_* the same way the shell resolves its own state, so a user
# who has moved any of these gets them cleaned from the moved location rather
# than from a $HOME default that does not exist.
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
PLUGINS="$CONF/omarchy/plugins"

# Every path this script can delete, built up front so --dry-run and the real
# run walk the same list. A path is only ever added when it exists, so the
# dry-run output is exactly what the real run would touch.
TARGETS=()
add() {
    # The `&&` form would be the last command in the function, so a path that
    # does not exist would return non-zero and `set -e` would kill the script.
    if [ -e "$1" ]; then
        TARGETS+=("$1")
    fi
}

add "$SHARE/quickshell/better-bar"
add "$CONF/quickshell/better-bar"
add "$PLUGINS/pix.bar"
add "$STATE/better"
add "$CACHE/better"
add "$CACHE/better-wp-thumbs"
add "$CACHE/cliphist-thumbs"
add "$CACHE/pill"

# Wallpaper state lives in siblings of the state dir, one file per setting, and
# the set keeps growing — a .lock file for the bag was missed when the list was
# maintained by hand. Match the prefix instead of enumerating, so a new file is
# covered the moment it is added. Unquoted glob with a nullglob guard: an
# unmatched pattern must stay a no-op, never a literal rm of "better-wallpaper*".
for f in "$STATE"/better-wallpaper*; do
    [ -e "$f" ] && TARGETS+=("$f")
done

# A checkout left by an interrupted `omarchy plugin add` stages into a hidden
# temp dir beside the plugin dir; those accumulate otherwise.
for f in "$PLUGINS"/.add.tmp.*; do
    [ -e "$f" ] && TARGETS+=("$f")
done

PLUGIN_INSTALLED=0
if command -v omarchy >/dev/null 2>&1 \
    && omarchy plugin list --json 2>/dev/null | grep -q '"pix\.bar"'; then
    PLUGIN_INSTALLED=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run. Nothing will be removed."
    echo
    if [ "$PLUGIN_INSTALLED" -eq 1 ]; then
        echo "Would run: omarchy plugin remove pix.bar --yes"
    fi
    echo "Would restore the stock bar: omarchy toggle bar on"
    echo "Would stop a standalone instance: pkill -f '[q]uickshell .*better-bar' (and the qs and scripts patterns)"
    echo
    echo "Would remove:"
    if [ "${#TARGETS[@]}" -eq 0 ]; then
        echo "  (nothing found — Better Bar does not appear to be installed)"
    else
        printf '  %s\n' "${TARGETS[@]}"
    fi
    if [ "$KEEP_STATE" -eq 1 ]; then
        echo
        echo "Note: --keep-state was passed, so state and cache paths would be kept."
    fi
    exit 0
fi

# The state and cache dirs hold the user's saved choices (theme, accent,
# wallpaper, dock pins) alongside disposable caches. They are worth a prompt:
# an uninstall that silently resets someone's theme is a bad trade for a
# convenience script. `--keep-state` skips the question for scripted use.
if [ "$KEEP_STATE" -eq 0 ]; then
    for f in "$STATE/better" "$CACHE/better"; do
        if [ -e "$f" ]; then
            if [ -t 0 ] && [ -t 1 ]; then
                printf '\n%s holds your saved theme, accent, wallpaper and dock choices.\n' "$f"
                printf 'Remove it too, or keep your settings? [y/N] '
                read -r reply
                case "$reply" in
                    [yY] | [yY][eE][sS]) ;;
                    *)
                        KEEP_STATE=1
                        printf 'Keeping your saved settings.\n'
                        break
                        ;;
                esac
            else
                # Not a terminal: piped through bash, as the README shows. Do not
                # delete a settings directory the user cannot be asked about.
                KEEP_STATE=1
                printf 'Not a terminal: keeping your saved settings in %s\n' "$f"
                printf 'Pass --keep-state to silence this, or remove it by hand.\n'
                break
            fi
        fi
    done
fi

echo "Removing Better Bar..."

# Plugin install. The bar runs inside omarchy-shell, so `omarchy plugin remove`
# is the supported door: it drops the checkout and points shell.json back at the
# stock bar in one step. Tried before the manual path so a plugin checkout is
# never stranded in the plugins directory.
if [ "$PLUGIN_INSTALLED" -eq 1 ]; then
    omarchy plugin remove pix.bar --yes >/dev/null 2>&1 \
        || echo "Could not remove the pix.bar plugin — run: omarchy plugin remove pix.bar"
fi

# Standalone install: the shell was launched as `quickshell --config <install
# root>` (or `qs -c`), so the install root is the match; the brackets keep pkill
# from matching this script's own command line. Anything executed from the
# install root (the clipboard watcher, lock helpers) is caught by the last
# pattern. No-op when the bar only ever ran inside omarchy-shell.
pkill -f "[q]uickshell .*better-bar" 2>/dev/null || true
pkill -f "[q]s .*better-bar" 2>/dev/null || true
pkill -f "[b]etter-bar/scripts" 2>/dev/null || true

# The stock bar was hidden on install; put it back. Best effort: if the stock
# shell is not running, the flag is still on disk and applies at the next login.
# `omarchy plugin remove` already restores the bar when it ran, so this only
# matters for the standalone path.
if command -v omarchy >/dev/null 2>&1; then
    omarchy toggle bar on >/dev/null 2>&1 \
        || echo "Could not restore the stock bar — run: omarchy toggle bar on"
else
    echo "Restore the stock bar with: omarchy toggle bar on"
fi

removed=0
kept=0
for target in "${TARGETS[@]}"; do
    case "$target" in
        "$STATE"/better | "$STATE"/better-wallpaper* | "$CACHE"/*)
            if [ "$KEEP_STATE" -eq 1 ]; then
                kept=$((kept + 1))
                continue
            fi
            ;;
    esac
    rm -rf "$target"
    removed=$((removed + 1))
done

echo "Better Bar removed (${removed} path(s) deleted)."
if [ "$kept" -gt 0 ]; then
    echo "Kept ${kept} state/cache path(s). Remove them by hand when you no longer need your saved settings."
fi

# This script never edits your Hyprland config. The auto-launch line and the
# SUPER keybinds were added by you, so remove them yourself.
if [ -d "$SHARE/quickshell/better-bar" ] || [ -d "$PLUGINS/pix.bar" ]; then
    echo "Remove the exec-once auto-launch line and the SUPER keybinds from your Hyprland config."
fi