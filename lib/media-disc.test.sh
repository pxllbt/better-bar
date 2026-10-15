#!/usr/bin/env bash
# Asserts the media bud shows the same rotating CD as the media surface.
#
# The bug this exists for: the pill's media entry was only a static bead. It
# disappeared when no player was present, and when it did appear it did not show
# the CD the media surface does. The CD is the visible media metaphor the desktop
# already uses, and the bud is the pill's door to that surface; the two now
# share the component instead of drifting apart.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
QMLDIR="$ROOT/components/qmldir"
COMPONENT="$ROOT/components/MediaDisc.qml"
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

[ -f "$COMPONENT" ] || { echo "no components/MediaDisc.qml at $COMPONENT" >&2; exit 1; }

ok "the media disc component is registered" \
    "$(grep -c '^MediaDisc MediaDisc.qml$' "$QMLDIR")" "1"

ok "the media disc component spins" \
    "$(grep -c 'RotationAnimation' "$COMPONENT")" "1"

ok "the pill bud uses the media disc component" \
    "$(grep -c 'MediaDisc {' "$PILL")" "1"

# The plugin ghost strip already lives on its own; it must not be pasted into
# the media bud, where it would duplicate the retry UI inside a 24px ball.
ok "the media bud no longer carries the plugin ghost retry block" \
    "$(sed -n '/id: bud$/,/^    }$/p' "$PILL" | grep -c 'Plugins.brokenPlugins')" "0"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
