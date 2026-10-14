#!/usr/bin/env bash
# Asserts that the launcher's Trigger > Speed Test section no longer offers the
# network speed test, and that it does so the supported way.
#
# Why this exists: the network speed test is the one row in that section nobody
# on this desktop has ever wanted. It runs an external bandwidth test through a
# browser or a CLI that uploads data to someone else's server, which is the
# slowest possible answer to "is my internet working", and it is the row that
# made the whole section feel broken -- because the disk test next to it is the
# one that gives a local, useful number.
#
# /usr/share/omarchy cannot be edited: an update overwrites it and
# `omarchy-menu update` rewrites the row outright. So the row is hidden the
# supported way, through `when` -- a shell condition that hides the row when it
# fails. A failing condition is rot-proof because it needs no external state.
#
# Every field is restated, and that is load-bearing. lib/menu.js normalizeItem()
# fills in a default for EVERY key, and mergeMenuSources() then copies all of
# those keys over the stock entry. So a sparse `{"when":"false"}` does not
# merely add a guard -- it overwrites the label with the bare id and blanks the
# action, leaving kind "menu" with no children. That still hides the row, but it
# corrupts it, and un-hiding it later resurrects a broken entry.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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
    printf 'SKIP menu-speedtest-removed: no omarchy-menu.jsonc at %s\n' "$MENU"
    exit 0
fi

# 1. The row is hidden.
has "the network speed test is hidden with a failing when guard" \
    "$(grep -c '"trigger.tests.network-speedtest".*"when":[[:space:]]*"false"' "$MENU")" \
    'trigger.tests.network-speedtest with when=false'

# 2. It is hidden by RESTATING the stock row, not by a sparse override. The
# sparse form still hides the row but corrupts it.
entry=$(grep '"trigger.tests.network-speedtest"' "$MENU" | head -1)
for field in icon label action; do
    has "the override restates the stock $field" \
        "$(printf '%s' "$entry" | grep -c "\"$field\":")" "$field"
done
has "the override keeps the stock action intact" \
    "$(printf '%s' "$entry" | grep -c 'omarchy.speedtest')" \
    "the stock omarchy.speedtest action"

# 3. The disk test is NOT touched -- the point is to drop one row, not a section.
if grep -q '"trigger.tests.disk-speedtest".*"when"[[:space:]]*:[[:space:]]*"false"' "$MENU"; then
    failed=$((failed + 1))
    printf 'FAIL the disk speed test is left alone (expected)\n'
else
    printf 'PASS the disk speed test is left alone\n'
fi

# 4. The parent submenu stays, so Trigger and its other children are still there.
ok "the Trigger section is still reachable" \
    "$(grep -c '"trigger"[[:space:]]*:[[:space:]]*{' "$STOCK")" "1"
ok "the Speed Test submenu heading is still present" \
    "$(grep -c '"trigger.tests"[[:space:]]*:' "$STOCK")" "1"

if [ -f "$ROOT/lib/menu.js" ]; then
    # normalizeItem must keep the declared fields, so the restated row survives
    # the merge with its label and action.
    has "menu.js merges without clobbering declared fields" \
        "$(grep -c 'mergeMenuSources' "$ROOT/lib/menu.js")" \
        "mergeMenuSources"
fi

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
