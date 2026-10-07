#!/usr/bin/env bash
# Asserts the strip reordering feature is actually wired: a StripLayout
# singleton persisting to strip-layout.json, the pill's status row driven by
# StripLayout.resolved instead of a hardcoded sequence, and the StripCell
# delegate with its drag-to-move, separator, and reset affordances.
#
# Shell test rather than QML on purpose, the same call as surfaces-wired and
# icon-alignment: the failure mode is a missing declaration, which QML reports
# as an exception in whatever happened to touch it next. Reading the wiring as
# text shows the gap directly, without needing a pointer on screen.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
PILL="$ROOT/Pill.qml"
STRIP_LAYOUT="$ROOT/Singletons/StripLayout.qml"
STRIP_CELL="$ROOT/components/StripCell.qml"
QMLDIR="$ROOT/Singletons/qmldir"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}
# Presence check: a declaration is either wired or not; counting exact
# occurrences is brittle because doc comments and code both mention the same
# name at least once.
ok_present() {
    if [ "$2" -ge "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: >= %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# 1. The singleton exists and is registered the way the other singleton
#    storage is (DockPins is the template for both).
has_singleton=$(grep -c 'singleton StripLayout StripLayout.qml' "$QMLDIR" 2>/dev/null)
ok "StripLayout registered in Singletons/qmldir" "$has_singleton" "1"

[ -f "$STRIP_LAYOUT" ] || { echo "no Singletons/StripLayout.qml" >&2; exit 1; }

# 2. The layout persists to strip-layout.json in the pill state dir, the same
#    FileView pattern DockPins uses for dock-pins.json.
has_path=$(grep -c 'strip-layout.json' "$STRIP_LAYOUT")
ok_present "StripLayout persists to strip-layout.json" "$has_path" "1"

# 3. Resolution: the strip's order of record lives here.
has_resolved=$(grep -c 'property var resolved' "$STRIP_LAYOUT")
ok "StripLayout exposes the resolved model" "$has_resolved" "1"

has_move=$(grep -c 'function move(' "$STRIP_LAYOUT")
ok "StripLayout can reorder entries" "$has_move" "1"

has_reset=$(grep -c 'function reset(' "$STRIP_LAYOUT")
ok "StripLayout can reset to defaults" "$has_reset" "1"

# 4. The pill's strip is driven by StripLayout.resolved, not a fixed sequence.
has_drive=$(grep -c 'model: StripLayout.resolved' "$PILL")
ok "Pill strip driven by StripLayout.resolved" "$has_drive" "1"

[ -f "$STRIP_CELL" ] || { echo "no components/StripCell.qml" >&2; exit 1; }

# 5. The delegate handles the three entry kinds: separator, plugin, native.
has_sep=$(grep -c 'kind === "sep"' "$STRIP_CELL")
ok_present "StripCell renders separators" "$has_sep" "1"
has_plugin=$(grep -c 'pluginId' "$STRIP_CELL")
ok_present "StripCell hosts PluginButton" "$has_plugin" "1"

# 6. It can be dragged (middle button, so left-click surfaces still answer)
#    and a middle-click editor inserts gaps / resets the strip.
has_drag=$(grep -c 'acceptedButtons: Qt.MiddleButton' "$STRIP_CELL")
ok_present "StripCell drags with the middle button" "$has_drag" "1"
has_menu=$(grep -c 'Insert gap' "$STRIP_CELL")
ok_present "StripCell can insert a gap" "$has_menu" "1"
has_rm_sep=$(grep -c 'Remove gap' "$STRIP_CELL")
ok "StripCell can remove a gap" "$has_rm_sep" "1"
has_rm_reset=$(grep -c 'Reset strip' "$STRIP_CELL")
ok "StripCell can reset the strip" "$has_rm_reset" "1"

# 7. The separator paints the same hairline the strip's built-in separators
#    already use, so a user gap looks native.
has_hair=$(grep -c 'Theme.hair' "$STRIP_CELL")
ok_present "Separator paints Theme.hair" "$has_hair" "1"

echo
if [ "$failed" -gt 0 ]; then
    echo "$failed check(s) failed"
    exit 1
fi
echo "all strip-layout checks passed"
exit 0