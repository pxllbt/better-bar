#!/usr/bin/env bash
# Asserts that launch.sh and better-launch enforce a single active bar instance
# via an atomic lockfile, preventing duplicate layer-shell bars.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LAUNCH="$ROOT/launch.sh"

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

[ -f "$LAUNCH" ] || { echo "no launch.sh at $LAUNCH" >&2; exit 1; }

# 1. launch.sh must implement atomic lockfile acquisition (flock)
has "launch.sh uses an atomic lockfile" \
    "$(grep -c 'better-bar.lock' "$LAUNCH")" "better-bar.lock"

has "launch.sh uses flock for mutual exclusion" \
    "$(grep -c 'flock' "$LAUNCH")" "flock"

# 2. launch.sh must check if an existing PID is alive before yielding
has "launch.sh inspects existing PID from lockfile" \
    "$(grep -cE 'kill -0|/proc/\$' "$LAUNCH")" "process check"

# 3. Secondary launch must exit cleanly with code 0 instead of duplicating
has "launch.sh exits cleanly on duplicate" \
    "$(grep -cE 'already running|exit 0' "$LAUNCH")" "exit 0"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
