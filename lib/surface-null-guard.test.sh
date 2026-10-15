#!/usr/bin/env bash
# Asserts the surface-size thunks can survive a first targetSize read.
#
# Why this exists: a surface switch can evaluate `targetSize` before the target
# surface's Loader has run `Qt.callLater` and produced its item. The calendar
# and weather thunks read `it.implicitWidth` directly, so that window logged
# "Cannot read property 'implicitWidth' of null". The surface did eventually
# load, but a bar cannot log a TypeError on the way onto its own settings.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PILL="$ROOT/Pill.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

calendar=$(sed -n '/calendar:.*size: () =>/p' "$PILL")
weather=$(sed -n '/weather:.*size: () =>/p' "$PILL")

ok "the calendar size thunk tolerates a null surface item" \
    "$(printf '%s\n' "$calendar" | grep -c 'if (!it)')" "1"
ok "the weather size thunk tolerates a null surface item" \
    "$(printf '%s\n' "$weather" | grep -c 'if (!it)')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
