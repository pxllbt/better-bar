#!/usr/bin/env bash
# Asserts that GameMode.qml automatically arms Better Recast replay buffer
# upon entering game mode and disarms it upon leaving.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GAMEMODE="$ROOT/Singletons/GameMode.qml"
FLAGS="$ROOT/Singletons/Flags.qml"

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

[ -f "$GAMEMODE" ] || { echo "no GameMode.qml at $GAMEMODE" >&2; exit 1; }
[ -f "$FLAGS" ] || { echo "no Flags.qml at $FLAGS" >&2; exit 1; }

# 1. Flags.qml must define autoGameReplay
has "Flags.qml exposes autoGameReplay flag" \
    "$(grep -c 'property alias autoGameReplay' "$FLAGS")" "autoGameReplay alias"

has "Flags.qml adapter defaults autoGameReplay to true" \
    "$(grep -c 'property bool autoGameReplay: true' "$FLAGS")" "autoGameReplay default"

# 2. GameMode.qml must trigger startReplay on enter
has "GameMode.qml triggers startReplay on enter" \
    "$(grep -c 'startReplay' "$GAMEMODE")" "startReplay"

# 3. GameMode.qml must trigger stopReplay on leave
has "GameMode.qml triggers stopReplay on leave" \
    "$(grep -c 'stopReplay' "$GAMEMODE")" "stopReplay"

# 4. GameMode.qml tracks autoReplayArmed so manual stops are respected
has "GameMode.qml tracks _autoReplayArmed state" \
    "$(grep -c '_autoReplayArmed' "$GAMEMODE")" "_autoReplayArmed"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
