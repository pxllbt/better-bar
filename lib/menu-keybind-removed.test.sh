#!/usr/bin/env bash
# Asserts the launcher's old Setup > Keybindings row is gone the supported way.
#
# Why it exists: the stock row hands the user a text editor opening
# ~/.config/hypr/bindings.lua, but the keybinding manager plugin now owns that
# workflow. Leaving the row in place offers two mutually invisible editors for
# the same file: one raw Lua, one graphical, with no reason to pick the raw one.
#
# /usr/share/omarchy cannot be edited and `omarchy-menu update` rewrites the row,
# so it is hidden the supported way, with `when: false`, and with every field
# restated -- a sparse override hides the row but leaves a corrupt menu item.
set -uo pipefail

ROOT=${1:-}
if [ -z "$ROOT" ]; then
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi
MENU="${HOME}/.config/omarchy/extensions/omarchy-menu.jsonc"
STOCK="/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"

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

if [ ! -f "$MENU" ]; then
    printf 'SKIP menu-keybind-removed: no omarchy-menu.jsonc at %s\n' "$MENU"
    exit 0
fi

# 1. The row is hidden, and hidden by a guard rather than deleted.
has "setup keybindings is hidden with a failing when guard" \
    "$(grep -c '"setup.keybindings".*"when":[[:space:]]*"false"' "$MENU")" \
    "setup.keybindings with when=false"

# 2. The override restates the row rather than blanking it into a submenu.
entry=$(grep '"setup.keybindings"' "$MENU" | head -1)
for field in icon label action; do
    has "the override restates the stock $field" \
        "$(printf '%s' "$entry" | grep -c "\"$field\":")" "$field"
done
has "the override keeps the stock action intact" \
    "$(printf '%s' "$entry" | grep -c 'bindings.lua')" \
    "the stock bindings.lua action"

# 3. Setup itself is untouched: only that one row is removed.
ok "the Setup section is still reachable" \
    "$(grep -c '"setup"[[:space:]]*:[[:space:]]*{' "$STOCK")" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
