#!/usr/bin/env bash
# Asserts that better-doctor.sh inspects processes, layers, daemons, and symlinks,
# and supports --fix and --json flags.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DOCTOR="$ROOT/scripts/better-doctor.sh"

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

[ -f "$DOCTOR" ] || { echo "no better-doctor.sh at $DOCTOR" >&2; exit 1; }

# 1. better-doctor.sh must be executable
ok "better-doctor.sh is executable" \
    "$([ -x "$DOCTOR" ] && echo "yes" || echo "no")" "yes"

# 2. Inspects bar processes and supervisor
has "better-doctor checks bar processes" \
    "$(grep -cE 'better-watch|quickshell' "$DOCTOR")" "process check"

# 3. Inspects layer-shell namespaces
has "better-doctor checks hyprctl layers" \
    "$(grep -c 'hyprctl layers' "$DOCTOR")" "hyprctl layers"

# 4. Inspects awww-daemon and symlinks
has "better-doctor checks awww-daemon" \
    "$(grep -c 'awww' "$DOCTOR")" "awww"

has "better-doctor checks background symlink" \
    "$(grep -c 'current/background' "$DOCTOR")" "current/background"

# 5. Supports --fix and --json
has "better-doctor supports --fix flag" \
    "$(grep -c -- '--fix' "$DOCTOR")" "--fix"

has "better-doctor supports --json flag" \
    "$(grep -c -- '--json' "$DOCTOR")" "--json"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
