#!/usr/bin/env bash
# Asserts the notification toast stacks its text instead of piling it up.
#
# The bug this exists for: the snooze pill row carried
# `anchors.bottom/left/right: parent`. That row is a direct child of the toast's
# Column, and a child that anchors to its own positioner is a conflict -- Qt can
# no longer resolve where ANY of the Column's children go. Every one of them
# collapsed onto y=0, so the app-name eyebrow, the summary and the body all drew
# on the same line and the toast read as two garbled words superimposed.
#
# Nothing caught it: the file loaded, the toast appeared, the notification was
# dismissed on click, and the damage is invisible to any test that does not
# measure geometry. So this pins the structural cause instead.
#
# The rule: inside a Column/Row, a direct child (8-space indent under the
# positioner) must not anchor. Deeper indents belong to grandchildren, which are
# positioned by their own parent and may anchor freely.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOAST="$ROOT/surfaces/Toast.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$TOAST" ] || { echo "no Toast.qml at $TOAST" >&2; exit 1; }

# A direct child's own properties sit one level in from the child declaration,
# so a child of the Column anchoring to `parent` shows up as an `anchors.` line
# at exactly 12 spaces. The Column's own anchors are at 8, and a grandchild's
# are at 16 or deeper -- each of those belongs to a parent that positions it, so
# anchoring is correct there.
bad=$(awk '/^    Column[[:space:]]*\{/ { incol=1; next }
            incol && /^    \}/ { incol=0 }
            incol && /^            anchors\..*parent\./ { printf "line %d: %s\n", NR, $0 }' "$TOAST")
ok "no direct child of the toast's Column anchors to its parent" \
    "$(printf '%s' "$bad" | sed '/^$/d' | wc -l | tr -d ' ')" "0"

# The specific offender, named so a regression is obvious in the failure.
ok "the snooze row flows in the Column rather than anchoring" \
    "$(grep -c 'anchors.bottom: parent.bottom' "$TOAST")" "0"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
