#!/usr/bin/env bash
# Asserts the settings card stays compact.
#
# Why this exists: the shipped row padding was 12 and the surface margins 29
# combined, which made a fourteen-row page tall enough to scroll when it fit
# comfortably on screen. These are the numbers that keep the bar the compact
# thing it is advertised as, and every one of them is silently easy to undo —
# nothing breaks, the card just gets tall again.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ROW="$ROOT/components/SettingsRow.qml"
SURFACE="$ROOT/components/SettingsSurface.qml"
PLUGINS="$ROOT/surfaces/PluginsSurface.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}
le() {
    if [ "$2" -le "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected <= %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$ROW" ] || { echo "no SettingsRow.qml at $ROW" >&2; exit 1; }
[ -f "$SURFACE" ] || { echo "no SettingsSurface.qml at $SURFACE" >&2; exit 1; }

PAD=$(grep -oE 'controlSlot.childrenRect.height\) \+ [0-9]+ \* srow.s' "$ROW" | grep -oE '[0-9]+' | head -1)
ok "row padding is tightened" "$PAD" "9"
le "row padding is not bloated again" "${PAD:-99}" "9"

MTOP=$(grep -oE 'mTop: [0-9]+' "$SURFACE" | grep -oE '[0-9]+' | head -1)
MBOT=$(grep -oE 'mBottom: [0-9]+' "$SURFACE" | grep -oE '[0-9]+' | head -1)
le "surface top margin is tight" "${MTOP:-99}" "12"
le "surface bottom margin is tight" "${MBOT:-99}" "11"

# Long lists must not claim the whole card.
CAP=$(grep -oE 'listCap: [0-9]+ \* root.s' "$PLUGINS" | grep -oE '[0-9]+' | head -1)
le "plugin list cap is bounded" "${CAP:-999}" "240"

# The header spacer every surface opens with.
LEAD=$(grep -rc 'width: 1; height: 10 \* root.s' "$ROOT/surfaces" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
ok "no surface opens with the old loose 10px spacer" "$LEAD" "0"

# --- the white-chip bug -----------------------------------------------------
# The plugin filter used to hand-roll its chips and fill the selected one with
# `Theme.surfaceHighlight`, a token Theme.qml does not declare. QML resolves an
# undeclared property to undefined, so the fill came out as the default white and
# "All" shipped as a bright white pill in a dark bar. The fix reuses SettingsSeg,
# whose selected state is a translucent flame tint.
# Every token read anywhere in the UI must be declared by Theme.qml (as a
# property or a function). A prose comment naming a token is not a read of it —
# the white-chip fix documents the broken token by name — so comment lines are
# excluded from the sweep.
UNDECLARED=$(grep -rhvE '^\s*(\*|//)' \
        "$ROOT"/surfaces/*.qml "$ROOT"/components/*.qml "$ROOT/Pill.qml" 2>/dev/null \
    | grep -hoP '(?<![A-Za-z])Theme\.[a-zA-Z]+' \
    | sed 's/^Theme\.//' | sort -u \
    | while read -r t; do
        # "qml" is the filename in prose ("Theme.qml resolves it…"), not a read.
        [ "$t" = "qml" ] && continue
        grep -qE "property (color|string|real|int|bool|var) $t\b" "$ROOT/Singletons/Theme.qml" \
            || grep -qE "function $t\b" "$ROOT/Singletons/Theme.qml" \
            || echo "$t"
      done)
ok "no surface reads an undeclared Theme token" "${UNDECLARED}" ""

ok "the plugin filters reuse the shared segmented control" \
    "$(grep -A20 -e '---- filters ---' "$PLUGINS" | grep -c 'SettingsSeg {')" "1"

PLUGINS="$ROOT/surfaces/PluginsSurface.qml"
ok "the plugin filters no longer hand-roll a chip fill" \
    "$(grep -c 'color: root.filterMode === key ? Theme.surfaceHighlight' "$PLUGINS")" "0"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
