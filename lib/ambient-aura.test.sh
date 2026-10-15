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
    "$(printf '%s\n' "$BLOCK" | grep -c 'readonly property bool shimmer: !Flags.reduceMotion && Cava.active')" "1"

ok "the aura is gated on the visualizer flag" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'Flags.musicViz')" "1"

ok "silence drives the aura to zero opacity" \
    "$(printf '%s\n' "$BLOCK" | grep -c ': 0$')" "1"

ok "the aura shimmers per band, not as one mass" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'var v = Cava.levels\[i\] || 0;')" "1"

ok "each band pool is placed across the pill" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'w \* (i + 0.5) / n')" "1"

ok "quiet frames still hold a calm floor glow" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'Math.max(0.10')" "1"

ok "reduced motion falls back to a static bloom" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'readonly property bool shimmer: !Flags.reduceMotion')" "1"

ok "the intensity flag scales every painted alpha" \
    "$(printf '%s\n' "$BLOCK" | grep -c 'var k = aura.intensity;')" "1"

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

# --- the settings toggle ---------------------------------------------------

ok "the aura flag is persisted" \
    "$(grep -c 'property alias auraIntensity' "$ROOT/Singletons/Flags.qml")" "1"

ok "the aura defaults to a glow, not a lamp" \
    "$(grep -c 'property real auraIntensity: 0.75' "$ROOT/Singletons/Flags.qml")" "1"

ok "Display exposes an ambient aura row" \
    "$(grep -c 'id: auraRow' "$ROOT/surfaces/DisplaySurface.qml")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
