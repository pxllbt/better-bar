#!/usr/bin/env bash
# Asserts a search field can actually be typed into.
#
# Why it exists: the plugins search could not. Clicking it did nothing and
# keystrokes went nowhere, which reads as "typing is broken" rather than as
# "this one field was never wired".
#
# Root cause, in two halves that are only a bug together:
#
#   1. SearchField is deliberately not a TextInput -- it is a plain Item that
#      captures Keys.onPressed and keeps its own buffer, to keep the whole bar's
#      input path free of QClipboard reads. That is right and stays.
#   2. A plain Item with `focus: true` only *wants* focus. Nothing *gives* it
#      focus: the component has no MouseArea, and clicking a plain Item does not
#      acquire it. So focus has to arrive from outside, by forceActiveFocus().
#
# Every other consumer does that (Calendar, Clipboard, DockSurface, FontPicker,
# Ui/MultiSelect, Ui/SearchableDropdown). PluginsSurface is the one that does not,
# so it is the field that cannot be typed into.
#
# Both halves are fixed at their source rather than at the surface: the component
# gains a click-to-focus, because a text field that ignores a click is broken for
# every consumer, and the surface gains an on-open focus, because a search field
# that opens unfocused is a field you have to click first.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FIELD="$ROOT/components/SearchField.qml"
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

[ -f "$FIELD" ] || { echo "no components/SearchField.qml at $FIELD" >&2; exit 1; }

# --- the component: clicking it focuses it ------------------------------
# The general rule, and the half that fixes every consumer at once.
ok "the field can be focused by clicking it" \
    "$(grep -c 'MouseArea' "$FIELD")" "1"
ok "clicking the field gives it active focus" \
    "$(grep -A6 'MouseArea {' "$FIELD" | grep -c 'inputProxy.forceActiveFocus()')" "1"
ok "the click region covers the input, not just the caret box" \
    "$(grep -A6 'MouseArea {' "$FIELD" | grep -c 'anchors.fill: parent')" "1"

# The buffer and the caret are what the field is for; a click must not disturb
# either, or clicking to reposition the caret would eat a character.
ok "clicking does not edit the buffer" \
    "$(grep -A10 'MouseArea {' "$FIELD" | grep -c 'insertString\|deleteBackward')" "0"

# --- the surface: it opens ready to type --------------------------------
[ -f "$PLUGINS" ] || { echo "no surfaces/PluginsSurface.qml at $PLUGINS" >&2; exit 1; }
ok "the plugins search is focused when the surface opens" \
    "$(grep -c 'pluginSearch.forceActiveFocus' "$PLUGINS")" "1"
ok "the focus is deferred a beat, so the item exists first" \
    "$(grep -B2 'pluginSearch.forceActiveFocus' "$PLUGINS" | grep -c 'Qt.callLater')" "1"

# --- the field still refuses focus when it should -----------------------
# A closed or hidden surface must never hold focus or eat keys. `active` is the
# gate the component already documents; a click-to-focus must not bypass it, so
# both the input and the new click handler have to carry it.
ok "the input and the click handler are both gated on active" \
    "$(grep -c 'enabled: root.active && root.enabled && root.visible' "$FIELD")" "2"
ok "the click handler is gated on the same flag" \
    "$(grep -A8 'MouseArea {' "$FIELD" | grep -c 'root.active')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'