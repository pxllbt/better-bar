#!/usr/bin/env bash
# Asserts the ambient aura behind the pill is wired to the audio spectrum and is
# dormant when nothing is playing.
#
# Why this exists: the aura is the bar's showpiece — a glow that visibly listens
# to whatever is on the speakers. Its contract is threefold: it is gated on
# cava activity so a silent machine pays nothing, its loudness is applied by
# opacity (compositor-owned) rather than by re-filling the gradient every cava
# frame, and it tints from the live accent so a theme swap carries the glow.
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

BLOCK=$(sed -n '/AMBIENT AURA/,/^    LiquidGlass {/p' "$PILL")
[ -n "$BLOCK" ] || { echo "could not locate the ambient aura" >&2; exit 1; }

ok "the aura is gated on cava activity" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'Cava.active')" "1"

ok "the aura is gated on the visualizer flag" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'Flags.musicViz')" "1"

ok "silence drives the aura to zero opacity" \
    "$(printf '%s\n' "$BLOCK" | grep -c ': 0$')" "1"

ok "loudness is applied through opacity, not a repaint" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'aura.auraLevel : 0')" "1"

ok "the aura derives its level from the cava frames" \
    "$(printf '%s\n' "$BLOCK" | grep -c '(Cava.levels\[i\] || 0) > peak')" "1"

ok "quiet frames still hold a calm floor glow" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'Math.max(0.10')" "1"

ok "the glow tints from the live accent token" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'readonly property color glowColor: Theme.vermLit')" "1"

ok "a theme change repaints the gradient" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'onVermLitChanged')" "1"

ok "the gradient repaints on a width morph" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'onWidthChanged: requestPaint()')" "1"

ok "the gradient repaints on a height morph" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'onHeightChanged: requestPaint()')" "1"

ok "the aura never eats the pill's clicks" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'enabled: false')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
