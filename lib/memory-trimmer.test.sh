#!/usr/bin/env bash
# Asserts that Surfaces.qml and Pill.qml implement autonomous memory trimming,
# surface auto-unloading, and garbage compaction.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACES="$ROOT/Singletons/Surfaces.qml"
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
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$SURFACES" ] || { echo "no Surfaces.qml at $SURFACES" >&2; exit 1; }
[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# 1. Surfaces.qml must have an autonomous periodic trimmer for idle surfaces
has "Surfaces.qml contains an autonomous trimmer timer" \
    "$(grep -cE 'autoTrimTimer|autoUnloadTimer|id: autoTrim' "$SURFACES")" "autoTrimTimer"

# 2. Surfaces.qml auto-trimmer invokes unloadClosed
has "auto-trimmer invokes unloadClosed" \
    "$(sed -n '/autoTrim/,/}/p' "$SURFACES" | grep -c 'unloadClosed()')" "unloadClosed"

# 3. Pill.qml must have memory compaction / reapJs on eviction
has "Pill.qml triggers garbage reclamation" \
    "$(grep -c 'function reapJs()' "$PILL")" "reapJs"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
