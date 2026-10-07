#!/usr/bin/env bash
# Asserts that every icon cell in the pill's hover row is the same size, is
# vertically centred, and draws at the same stroke weight.
#
# The bug this exists for: the cells were three sizes. Most were 17*s, wifi and
# bluetooth were 15*s, and do-not-disturb 16*s. A GlyphIcon fills its cell, so a
# 15 cell drew a visibly smaller glyph beside a 17 one -- and WifiGlyph, whose
# own implicit size is 17*s, was being *shrunk* by the cell it sat in. The
# plugin cells were 17 but were not vertically centred, so they sat off the row's
# shared baseline. Appearance's cog carried two compensating offsets
# (scale 0.86 and stroke 1.6) where every other icon used stroke 1.7.
#
# The rule: one cell size for every icon, one stroke weight, and every cell
# vertically centred. Per-icon optical corrections belong in the glyph table,
# not in the cell that holds it.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
PILL="$ROOT/Pill.qml"
BUTTON="$ROOT/components/PluginButton.qml"

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

# The cell constant every icon must go through.
ok "the pill declares a single icon cell size" \
    "$(grep -cE 'readonly property real iconCell:' "$PILL")" "1"

cell_expr=$(grep -oE 'readonly property real iconCell: *([0-9.]+) \* s' "$PILL" | head -1 | grep -oE '[0-9.]+ \* s' | head -1)
ok "the icon cell is declared in scaled units" \
    "$([ -n "$cell_expr" ] && echo yes || echo no)" "yes"

# The native strip cells: one inline Component per cell in Pill.qml. They used
# to sit directly in the hover row, which now renders StripLayout.resolved
# through a Repeater; the region whose icons share one baseline is the cell
# components' section. Walk from the opening of `cellWeather` to the closing of
# `cellPower`.
first_id=$(grep -n 'id: cellWeather' "$PILL" | head -1 | cut -d: -f1)
last_id=$(grep -n 'id: cellPower' "$PILL" | head -1 | cut -d: -f1)
[ -n "$first_id" ] && [ -n "$last_id" ] || { echo "no cell components in Pill.qml" >&2; exit 1; }
start=$(awk -v idline="$first_id" '
    NR < idline && /^[[:space:]]*Component[[:space:]]*\{[[:space:]]*$/ { last = NR }
    END { print last }' "$PILL")
end=$(awk -v idline="$last_id" '
    NR < idline && /^[[:space:]]*Component[[:space:]]*\{[[:space:]]*$/ { last = NR }
    END { print last }' "$PILL")
[ -n "$start" ] && [ -n "$end" ] || { echo "no enclosing Component blocks" >&2; exit 1; }
row=$(awk -v from="$start" -v to="$end" '
    NR < from { next }
    { print
      n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
      depth += n - m
      if (n > 0) opened = 1
      if (opened && depth <= 0 && NR >= to) exit }' "$PILL")
[ -n "$row" ] || { echo "empty cell-components region" >&2; exit 1; }

# Guard: an extraction that yields nothing (or a fragment) would let every
# per-cell assertion pass vacuously, which is how a broken test reports green.
# Require the full expected set before believing any verdict below.
cells=$(printf '%s\n' "$row" | grep -oE 'id: [A-Za-z]+Icon' | awk '{print $2}' | sort -u)
[ "$(printf '%s\n' "$cells" | grep -c .)" -ge 10 ] || {
    echo "row extraction found $(( $(printf '%s\n' "$cells" | grep -c .) )) icon cells, expected the full set" >&2
    exit 1
}

mixed=""
for cell in $cells; do
    body=$(printf '%s\n' "$row" | awk -v id="id: $cell" '
        !grab && $0 ~ id { grab = 1 }
        grab { print
               if (NR > 1 && $0 ~ /^[[:space:]]*}$/) exit }')
    [ -n "$body" ] || { mixed="$mixed $cell:no-body"; continue; }
    w=$(printf '%s\n' "$body" | grep -oE '^[[:space:]]*width: .*$' | head -1 | sed 's/^[[:space:]]*//')
    h=$(printf '%s\n' "$body" | grep -oE '^[[:space:]]*height: .*$' | head -1 | sed 's/^[[:space:]]*//')
    centred=$(printf '%s\n' "$body" | grep -c 'anchors.verticalCenter: parent.verticalCenter')
    printf '%-18s %-24s %-24s centred=%s\n' "$cell" "${w:-<none>}" "${h:-<none>}" "$centred"
    # A width derived from text is not a glyph cell: the battery cell wraps the
    # percentage text, so its width is the text's implicit width and only its
    # height is a glyph dimension.
    if [ -n "$w" ] && ! printf '%s' "$w" | grep -q 'iconCell\|implicitWidth'; then
        mixed="$mixed $cell:width=$w"
    fi
    if [ -n "$h" ] && ! printf '%s' "$h" | grep -q 'iconCell'; then
        mixed="$mixed $cell:height=$h"
    fi
    if [ "$centred" -lt 1 ]; then
        mixed="$mixed $cell:not-centred"
    fi
done
ok "every icon cell is the same size and vertically centred" \
    "$(printf '%s' "$mixed" | sed 's/^ *//')" ""

# One stroke weight across the *cells*. A cell's own glyph uses 1.7, with two
# deliberate exceptions that are inset detail inside a cell rather than cells
# themselves: the battery bolt (1.6, drawn at 10-11*s inside the battery cell)
# and the weather glyph (1.8). Those are checked as allowed, not flagged.
cell_strokes=$(printf '%s\n' "$row" | grep -oE 'stroke: [0-9.]+' | awk '{print $2}' | sort -u | grep -vE '^(1\.6|1\.8)$' | tr '\n' ' ')
ok "the hover row's cells share one stroke weight" \
    "$cell_strokes" "1.7 "

# Plugin cells have to match the native ones, or a third-party icon is the odd
# one out the moment a plugin is enabled.
ok "PluginButton draws in the same cell size" \
    "$(grep -cE 'implicitWidth: *pill\.iconCell|explicitProperty.*iconCell' "$BUTTON")" "0"
ok "PluginButton's cell is 17 scaled units" \
    "$(grep -oE 'implicitWidth: ([0-9.]+) \* s' "$BUTTON" | grep -oE '[0-9.]+')" "17"
ok "PluginButton's glyph stroke matches the row" \
    "$(grep -oE 'stroke: [0-9.]+' "$BUTTON" | awk '{print $2}' | sort -u | tr '\n' ' ' | xargs)" "1.7"
# Anchored to statusRow by id rather than to `parent`. Both centre the cell on
# the row, but a Repeater delegate's `parent` is null while the anchor binding
# first evaluates, so the `parent` form logged "Cannot read property
# 'verticalCenter' of null" on every shell start. The id form is the fix, so the
# assertion pins it -- asserting only that *some* anchor exists would let the
# throwing version back in. The strip delegate is StripCell inside the Repeater
# over StripLayout.resolved.
ok "the plugin delegate is vertically centred in the row" \
    "$(grep -A16 'model: StripLayout.resolved' "$PILL" | grep -c 'anchors.verticalCenter: statusRow.verticalCenter')" "1"
ok "no delegate anchors to a parent that is null at bind time" \
    "$(grep -A16 'model: StripLayout.resolved' "$PILL" | grep -c 'anchors.verticalCenter: parent\.')" "0"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'