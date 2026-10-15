#!/usr/bin/env bash
# Asserts Better Bar owns the keybind manager UI natively.
#
# The bug this exists for: the keybindings feature was reachable only as a
# bridge into the upstream plugin's own window. That made "installed" and "wired
# into Better Bar" the same thing, and the bar had no control over keybinding
# state, search or row layout.
#
# This asserts the better-bar-side contract instead: a real settings surface, a
# real loader route, and a backend call that happens on demand rather than on a
# timer in the long-lived shell.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
QMLDIR="$ROOT/surfaces/qmldir"
PILL="$ROOT/Pill.qml"
INTERFACE="$ROOT/surfaces/DisplaySurface.qml"
SURFACE="$ROOT/surfaces/KeybindsSurface.qml"
SINGLETON="$ROOT/Singletons/Keybinds.qml"
SEARCH="$ROOT/lib/settings-search.js"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SURFACE" ] || { echo "no surfaces/KeybindsSurface.qml at $SURFACE" >&2; exit 1; }
[ -f "$SINGLETON" ] || { echo "no Singletons/Keybinds.qml at $SINGLETON" >&2; exit 1; }

ok "the keybinds surface is registered" \
    "$(grep -c '^KeybindsSurface KeybindsSurface.qml$' "$QMLDIR")" "1"

ok "the keybind singleton is registered" \
    "$(grep -c '^singleton Keybinds Keybinds.qml$' "$ROOT/Singletons/qmldir")" "1"

ok "the keyboard settings open the native keybinds surface" \
    "$(grep -c '{ item: keyboardTile, kind: "nav", surface: "keybinds" }' "$ROOT/surfaces/Appearance.qml")" "1"

ok "the keybind manager is not left inside the interface page" \
    "$(grep -c 'keybindsRow' "$INTERFACE")" "0"

ok "the interface row no longer bridges to the plugin" \
    "$(grep -c 'Plugins.openOrEnable(\"meviusisback.keybinds\")' "$INTERFACE")" "0"

ok "the keybinds surface has a pill loader" \
    "$(grep -cE 'id:[[:space:]]*ldKeybinds\b' "$PILL")" "1"

ok "the keybinds surface has a loader-map entry" \
    "$(grep -cE '^[[:space:]]*keybinds:[[:space:]]*\(\)[[:space:]]*=>[[:space:]]*ldKeybinds\b' "$PILL")" "1"

ok "the keybinds surface has a surfaces-map entry" \
    "$(grep -cE '^[[:space:]]*keybinds:[[:space:]]*\{' "$PILL")" "1"

ok "the keybinds surface has an open property" \
    "$(grep -cE 'keybindsOpen:[[:space:]]*surface === \"keybinds\"' "$PILL")" "1"

# The surface's list must filter in the pure JS module, not by shelling out for
# every keystroke.
ok "the surface filters rows through the tested JS module" \
    "$(grep -c 'import "../lib/keybinds.js" as KeybindsModel' "$SURFACE")" "1"

# The list is read only while the surface is open. A repeat timer here would
# rebuild 180+ rows inside the shell forever.
ok "the backend read is gated on the surface being open" \
    "$(grep -c 'running: root.surfaceOpen' "$SINGLETON")" "1"
ok "the keybind backend is not polled by a repeating timer" \
    "$(grep -cE 'repeat:[[:space:]]*true' "$SINGLETON")" "0"

# Hyprland can carry 180+ active bindings. A plain Column inside a Flickable
# would instantiate every row; a list view with reuse does not.
ok "the keybind rows are virtualised in a list view" \
    "$(grep -c 'ListView {' "$SURFACE")" "1"
ok "the keybind list reuses row delegates" \
    "$(grep -c 'reuseItems: true' "$SURFACE")" "1"

# Search now lands on the native surface, not the plugin bridge.
ok "settings search opens the native keybinds surface" \
    "$(grep -c '\"keybinds\"' "$SEARCH")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
