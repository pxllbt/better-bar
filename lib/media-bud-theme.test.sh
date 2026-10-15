#!/usr/bin/env bash
# Asserts the media bud follows the active theme.
#
# Why this exists: the bud bead used to paint its own warm flame endpoints
# (`Theme.flameInk`/`Theme.flameEmber`) instead of theme-aware tokens, so its
# centre went blue while its ends stayed orange on a static palette. The bead is
# gone now — the bud is a liquid-glass edge around the same `MediaDisc` the
# media surface uses — so the check has moved to that link: the bud must embed
# the shared disc and must not paint with flame tokens at all.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PILL="$ROOT/Pill.qml"

failed=0
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}
hasnt() {
    if [ "$2" -eq 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' "$1" "$3"
    fi
}

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# The bud glass pane only. A global grep would match the broken-plugin icons
# above it, which legitimately use the verm family.
bud=$(sed -n '/id: bud$/,/id: budArea/p' "$PILL")
[ -n "$bud" ] || { echo "could not locate the media bud" >&2; exit 1; }

hasnt "the bud no longer paints warm flame endpoints" \
    "$(printf '%s\n' "$bud" | grep -cE 'Theme\.(flameInk|flameEmber)')" "0"

has "the bud embeds the shared media disc" \
    "$(printf '%s\n' "$bud" | grep -c 'MediaDisc {')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
