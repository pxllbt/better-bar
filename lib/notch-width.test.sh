#!/usr/bin/env bash
# A notch is a shape, not a measurement.
#
# The notch's width is its content's width -- the clock slot, the date, the
# time and the workspace badge, and nothing else. That only works while the
# measurement equals the drawing, and it failed in both directions:
#
# 1. The Row measured its children by IMPLICIT width. The clock slot, the
#    workspace badge and the two status chips are placed by an explicit
#    width, which leaves their implicit width at zero -- so the row reported
#    less than it drew, the notch came out narrower than its own content,
#    and the content was clipped at the right edge.
#
# 2. The width was exactly the measurement, with nothing holding it up. On a
#    workspace switch the clock text is re-measured for a frame; the row
#    reported almost nothing, and the notch collapsed to a five-pixel sliver
#    in the middle of the screen -- the blue dash in an empty tab that was
#    reported as "the bar looks weird when switching workspaces".
#
# So the rule, in two halves:
#
#   Every explicitly-sized item in the resting row must report its width.
#   The notch's width must have a floor that a momentary zero cannot cross.
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

# The declaration and the next twenty lines: enough to see whether the item
# states its implicit width, without matching a neighbour's.
declares() {
    local id="$1"
    awk -v id="id: $id" '
        $0 ~ id { found = 1; n = 0 }
        found && n++ < 20 && /implicitWidth:/ { print "yes"; exit }
    ' "$PILL"
}

# 1. Every explicitly-sized item in the resting row reports its width.
ok "the clock slot reports its width to the row" \
    "$(declares restClock)" "yes"
ok "the workspace badge reports its width to the row" \
    "$(declares restWsBadge)" "yes"
ok "the update chip reports its width to the row" \
    "$(declares restUpdate)" "yes"
ok "the agent chip reports its width to the row" \
    "$(declares restAgentChip)" "yes"

# 2. The notch's width has a floor.
#
# `Math.max(...)` is the whole contract: a content width of zero yields the
# floor, not a five-pixel tab. 140 is generous on purpose -- the notch's
# steady state is around two hundred, so the floor only ever catches the
# frame in which the content is being re-measured.
ok "the notch's width has a floor under it" \
    "$(grep -cE 'readonly property real notchW:.*Math\.max\(' "$PILL")" "1"

# 3. The floor is not zero.
#
# A floor of zero is the same bug with a different spelling.
awk '
    /readonly property real notchW:/ { found = 1 }
    found && /Math\.max\(/ {
        line = $0
        # the first argument after Math.max( is the measurement; the second
        # is the floor
        if (match(line, /Math\.max\([^,]+,\s*([0-9]+(\.[0-9]+)?)\s*\*/)) {
            floor = substr(line, RSTART, RLENGTH)
            sub(/.*,\s*/, "", floor)
            sub(/\s*\*.*/, "", floor)
            if (floor + 0 > 0) { print "positive"; exit }
        }
        if (match(line, /Math\.max\([^,]+,\s*([1-9][0-9]*)\s*\)/)) { print "positive"; exit }
    }
' "$PILL" > /tmp/notch-floor.$$ 2>/dev/null
ok "the notch's floor is a positive width" \
    "$(cat /tmp/notch-floor.$$ 2>/dev/null)" "positive"
rm -f /tmp/notch-floor.$$

if [ "$failed" -gt 0 ]; then
    printf '\n%d failing\n' "$failed"
    exit 1
fi
echo
echo "all green"
