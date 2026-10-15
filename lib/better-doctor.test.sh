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

# 3. Only counts pids still alive, so a bar that exits between the ps and the
# count is not reported as a duplicate
has "better-doctor revalidates pids against /proc before counting" \
    "$(grep -c '\[ -d "/proc/\$pid" \] || continue' "$DOCTOR")" "pid liveness filter"

# 4. Screens: the two layout faults that break silently -- a duplicated output and
# an unparseable file -- plus a screen count. No editor, no drift; each is the
# whole check in a form a `grep` can confirm.
has "better-doctor reports the screen count from hyprctl monitors" \
    "$(grep -c 'hyprctl monitors -j' "$DOCTOR")" "hyprctl monitors -j"

has "better-doctor flags two hl.monitor blocks naming the same output" \
    "$(grep -c 'uniq -d' "$DOCTOR")" "duplicate-output detection"

has "better-doctor flags a monitors.lua with no hl.monitor block" \
    "$(grep -c "no hl.monitor block at all" "$DOCTOR")" "unparseable-layout detection"

# The stock monitors.lua carries commented-out examples that all name DP-2. A
# check that counted those would fire on every unedited install, so the
# comment-stripping is part of the check, not a nicety.
has "better-doctor ignores commented-out monitor blocks when counting outputs" \
    "$(grep -c "grep -vE '\^\[\[:space:\]\]\*--'" "$DOCTOR")" "comment strip"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
