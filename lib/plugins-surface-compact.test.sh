#!/usr/bin/env bash
# Asserts the Plugins surface is a compact inventory, not a stack of global
# controls above the list.
#
# Why this exists: opening Plugins used to show seven management rows before the
# first plugin — updates, auto-check, auto-update, auto-adopt, self-heal, repair,
# restart, install, install — then the inventory. The rare controls are now one
# collapse row and an install collapse row, so the page opens as the inventory.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACE="$ROOT/surfaces/PluginsSurface.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SURFACE" ] || { echo "no PluginsSurface.qml at $SURFACE" >&2; exit 1; }

ok "automation collapses behind one row" \
    "$(grep -c 'id: automationRow' "$SURFACE")" "1"
ok "install collapses behind one row" \
    "$(grep -c 'id: installRow' "$SURFACE")" "1"
ok "automation collapse state is local" \
    "$(grep -c 'property bool advancedOpen: false' "$SURFACE")" "1"
ok "install collapse state is local" \
    "$(grep -c 'property bool installOpen: false' "$SURFACE")" "1"

ok "advanced rows register only when open" \
    "$(grep -c 'if (root.advancedOpen)' "$SURFACE")" "1"
ok "install row registers only when open" \
    "$(grep -c 'if (root.installOpen)' "$SURFACE")" "1"

ok "the automation summary is one line" \
    "$(grep -c 'readonly property string automationSummary' "$SURFACE")" "1"
ok "status is hidden when there is nothing to say" \
    "$(grep -c 'visible: root.showStatus' "$SURFACE")" "1"

ok "the search field opens focused" \
    "$(grep -c 'pluginSearch.forceActiveFocus()' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
