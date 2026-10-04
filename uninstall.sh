#!/usr/bin/env bash
set -eu

SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

echo "Removing Better Bar..."

# Stop a running instance. The shell is launched as
# `quickshell --config <install root>` (or `qs -c`), so the
# install root is the match; the bracket keeps pkill from
# matching this script's own command line. Anything executed
# from the install root (the clipboard watcher, lock helpers)
# is caught by the second pattern.
pkill -f "[q]uickshell .*better-bar" 2>/dev/null || true
pkill -f "[q]s .*better-bar" 2>/dev/null || true
pkill -f "[b]etter-bar/scripts" 2>/dev/null || true

# Program files (wherever you cloned it).
rm -rf "$SHARE/quickshell/better-bar"
rm -rf "$CONF/quickshell/better-bar"

# The stock bar was hidden on install; put it back. Best effort:
# if the stock shell is not running, the setting is still in
# shell.json and applies at the next login.
if command -v omarchy >/dev/null 2>&1; then
  omarchy toggle bar on >/dev/null 2>&1 \
    || echo "Could not restore the stock bar — run: omarchy toggle bar on"
else
  echo "Restore the stock bar with: omarchy toggle bar on"
fi

# State: flags, events, gamemode snapshot, wallpaper selection,
# and the capability provider choices.
rm -rf "$STATE/better"

# Wallpaper state lives in siblings of that dir, one file per setting, and the
# set keeps growing — a .lock file for the bag was missed when the list was
# maintained by hand. Match the prefix instead of enumerating, so a new file is
# covered the moment it is added rather than after someone notices it survived
# an uninstall. Quoted glob: no match must stay a no-op, not a literal rm of
# "$STATE/better-wallpaper*".
for f in "$STATE"/better-wallpaper*; do
  [ -e "$f" ] || continue
  rm -rf "$f"
done

# Cache: weather, rec thumbs, wallpaper + clipboard previews, dynamic
# colors — all under the single ~/.cache/better root. The scattered legacy
# dirs are removed too so an old install is cleaned out fully.
rm -rf "$CACHE/better"
rm -rf "$CACHE/better-wp-thumbs"
rm -rf "$CACHE/cliphist-thumbs"
rm -rf "$CACHE/pill"

# Note: this script never edits your Hyprland config. The auto-launch line and
# the SUPER keybinds were added by you, so remove them yourself:
echo "Better Bar removed."
echo "Remove the exec-once auto-launch line and the SUPER keybinds from your Hyprland config."
