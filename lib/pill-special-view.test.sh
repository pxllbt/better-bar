#!/usr/bin/env bash
# A special workspace must not blank the pill.
#
# The Minimized stash and the scratchpad put the pill into a "special view" --
# a plain word (Minimized, Scratchpad) shown in place of the clock so it is
# obvious you are looking at a stash rather than your real desktop.
#
# The bug this file exists for: EVERY child of the resting row hid itself when
# `specialView !== ""` -- the clock slot, the date AND time, the workspace
# badge -- while the face that draws the special word was gated on
# `pill.stripBar`. So in the classic pill nothing took their place: the bar
# went completely blank. Not a missing clock. An empty capsule, with nothing
# on screen to say why, and the width collapsed to its minimum because a
# hidden Row reports no implicit width at all.
#
# The rule, stated once so it can be checked:
#
#   The special word replaces the CLOCK. It does not replace the bar.
#
# So the date, the time and the badge must survive a special view, and the
# special word must be drawable in the classic pill as well as the strip bar.
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

# 1. The classic date/time must not vanish with the clock.
#
#    It is the largest block in the row, and it is not the clock.
date_block=$(sed -n '/id: restDateTime/,/^\s*}/p' "$PILL" | head -6)
ok "the classic date/time is not gated on the special view" \
    "$(printf '%s' "$date_block" | grep -c 'specialView === ""')" "0"

# 2. The workspace badge must survive a special view too -- it says which
#    workspace you are on, which is exactly what a special view changes.
ws_block=$(sed -n '/id: restWsBadge/,/^\s*}/p' "$PILL" | head -6)
ok "the workspace badge is not gated on the special view" \
    "$(printf '%s' "$ws_block" | grep -c 'specialView === ""')" "0"

# 3. The special word has to be drawable in the classic pill. If its face is
#    strip-only, the clock slot is an empty hole wherever the strip bar is not.
special_block=$(sed -n '/id: stripSpecialFace/,/^\s*}/p' "$PILL" | head -8)
ok "the special word can be drawn outside the strip bar" \
    "$(printf '%s' "$special_block" | grep -c 'pill.stripBar')" "0"

# 4. The clock slot is the one thing the special word DOES replace, so it is
#    the one thing allowed to hide.
clock_block=$(sed -n '/id: restClock/,/^\s*}/p' "$PILL" | head -14)
ok "the clock slot still yields to the special view" \
    "$(printf '%s' "$clock_block" | grep -c 'specialView === ""')" "1"

# 5. And the belt-and-braces version of the same rule: in the classic pill,
#    at least one of the resting row's children must be visible no matter
#    what the special view says. If every one of them is gated on
#    `specialView === ""`, the pill is one special workspace away from blank.
gated=0
for id in restDateTime restWsBadge restWeekTime; do
    block=$(sed -n "/id: $id/,/^\s*}/p" "$PILL" | head -6)
    printf '%s' "$block" | grep -q 'specialView === ""' && gated=$((gated + 1))
done
ok "no more than one resting-row block is gated on the special view" \
    "$([ "$gated" -le 1 ] && echo yes || echo no)" "yes"

if [ "$failed" -eq 0 ]; then
    printf '\nall green\n'
    exit 0
fi
printf '\n%s failing\n' "$failed"
exit 1
