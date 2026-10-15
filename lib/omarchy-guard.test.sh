#!/usr/bin/env bash
# Asserts the Omarchy survival guard is real and self-running.
#
# Why this exists: an Omarchy update can move the shared shell forward under
# Better Bar. Better Bar’s own update guard already protects local work from a
# Better Bar update; this is the other side — when Omarchy itself changes, the
# bar should notice, rescan, re-assert its custom menu rows, and report what it
# did instead of silently looking broken after an upgrade.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT/scripts/omarchy-guard.sh"
SINGLETON="$ROOT/Singletons/OmarchyGuard.qml"
FLAGS="$ROOT/Singletons/Flags.qml"
SURFACE="$ROOT/surfaces/InterfaceSurface.qml"
QMLDIR="$ROOT/Singletons/qmldir"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SCRIPT" ] || { echo "no scripts/omarchy-guard.sh at $SCRIPT" >&2; exit 1; }

ok "the guard script exists" "yes" "$([ -f "$SCRIPT" ] && echo yes || echo no)"
ok "the guard script is executable" "yes" "$([ -x "$SCRIPT" ] && echo yes || echo no)"

ok "the guard tracks the installed omarchy version" \
    "$(grep -c 'omarchy-version' "$SCRIPT")" "2"

ok "the guard persists the last seen version" \
    "$(grep -c 'omarchy-guard.json' "$SCRIPT")" "1"

ok "the guard rescans the host when the version moved" \
    "$(grep -c 'rescanPlugins' "$SCRIPT")" "2"

ok "the guard re-asserts the hidden keybind menu row" \
    "$(grep -c 'setup.keybindings' "$SCRIPT")" "2"

ok "the guard has a machine-readable status mode" \
    "$(grep -c -- '--json' "$SCRIPT")" "3"

ok "the survival flag is persisted" \
    "$(grep -c 'property alias omarchySurvival' "$FLAGS")" "1"
ok "survival defaults to on" \
    "$(grep -c 'property bool omarchySurvival: true' "$FLAGS")" "1"

ok "the guard singleton is registered" \
    "$(grep -c '^singleton OmarchyGuard OmarchyGuard.qml$' "$QMLDIR")" "1"

ok "the guard singleton reads the guard script" \
    "$(grep -c 'omarchy-guard.sh' "$SINGLETON")" "1"

ok "the interface settings expose the survival row" \
    "$(grep -c 'id: omarchySurvivalRow' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
