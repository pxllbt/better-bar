#!/usr/bin/env bash
# Whole-tree QML integrity gate.
#
# This exists because a clean `qs -p .` proves almost nothing about this bar: the
# preview walks the rest face, so every surface behind a loader, every plug-in
# branch and every settings row stays uncompiled until something opens it. That
# is how a bar ships a `pill.checkMediaHover()` that does not exist and still
# "loads fine" — the ReferenceError only fires on the interaction, where it
# aborts the statement before the one the user cared about.
#
# Every bug this gate caught was invisible to the preview and to the runtime log
# until it was reached by hand:
#
#   components/StripCell.qml   `pill` used in 3 places, never declared in that
#                              file — the strip layout menu could not open at
#                              all, because the throw landed on the first line
#                              of openMenu() before the card was made visible.
#   Pill.qml                    `root.pillBarHeight` / `root.pillBarRadius` with
#                              no `root` — the dock never received the pill's
#                              resting geometry and had to guess its own.
#   surfaces/FontPicker.qml     anchored a field to `searchGlyph.right`, an id
#                              that no longer existed; the binding silently
#                              failed and the field laid out from nothing.
#   surfaces/Clipboard.qml      `point` in a pointer handler that never declared
#                              one — hover-to-select never fired.
#   components/Tray.qml         `manage.anchorX` against an object that was
#                              never created.
#   surfaces/Media.qml          right rail 96*s could not fit its own fixed
#                              "Not connected" label, so it rendered as
#                              "Not connecte.." on every machine.
#
# The gate compares against an exact reviewed baseline rather than an
# allow-list of filenames, so a *new* unresolved reference fails even though the
# five known ones do not.
set -u

ROOT="${1:-.}"
AUDIT="$ROOT/lib/qml-audit.py"

[ -r "$AUDIT" ] || { echo "missing $AUDIT" >&2; exit 1; }

failed=0

# --- the audit must run at all -------------------------------------------
if ! python3 -c "import ast,sys; ast.parse(open('$AUDIT').read())" 2>/dev/null; then
    echo "FAIL qml-audit.py does not parse"
    exit 1
fi
echo "PASS the auditor itself parses"

# --- exact baseline ------------------------------------------------------
# Each entry is a QML scoping rule the checker does not model, reviewed by hand:
#
#  Notifs.qml:trackedNotifications.values
#      `trackedNotifications` is a property of the enclosing Notifications
#      service object. QML resolves an object's own members unqualified; this is
#      correct code, not an undefined name.
#
#  shell.qml / MinimizedTray.qml: hl.dsp
#      Inside a single-quoted JS string (`Hyprland.dispatch('hl.dsp...')`). The
#      scanner does not treat `'` as a delimiter because a regex literal in this
#      tree contains one (`/["\']/g`), and a scanner that guesses wrong blanks
#      the rest of the file. Documented in strip_noise().
#
EXPECTED='  Singletons/Notifs.qml: trackedNotifications.values
  shell.qml: hl.dsp
  shell.qml: hl.dsp
  surfaces/MinimizedTray.qml: hl.dsp'

# Both sides go through the same normalisation. The baseline is written indented
# for readability above, and a whitespace mismatch there would read as "new
# unresolved references" — a failure about the test rather than the code.
norm() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g' | sort -u; }

ACTUAL=$(python3 "$AUDIT" "$ROOT" 2>/dev/null \
    | sed -n '/--- unresolved-id/,/^$/p' \
    | grep -E '^[[:space:]]+[A-Za-z]' \
    | norm)

# Report anything new first — that is the signal worth reading.
NEW=$(comm -13 <(printf '%s\n' "$EXPECTED" | norm) <(printf '%s\n' "$ACTUAL"))

if [ -n "$NEW" ]; then
    failed=$((failed + 1))
    echo "FAIL new unresolved references (each aborts its enclosing statement):"
    printf '%s\n' "$NEW" | sed 's/^/    /'
else
    echo "PASS no unresolved references beyond the reviewed baseline"
fi

# --- the other checks must be silent ------------------------------------
OTHER=$(python3 "$AUDIT" "$ROOT" 2>/dev/null \
    | grep -E '^--- (undeclared-Theme|undeclared-Flags|duplicate-id)')

if [ -n "$OTHER" ]; then
    failed=$((failed + 1))
    echo "FAIL undeclared theme/flag tokens or duplicate ids:"
    printf '%s\n' "$OTHER" | sed 's/^/    /'
    python3 "$AUDIT" "$ROOT" 2>/dev/null | sed -n '/--- \(undeclared\|duplicate\)/,/^$/p' \
        | grep -E '^  [A-Za-z]' | sed 's/^/    /'
else
    echo "PASS every Theme and Flags token resolves, and no id is declared twice"
fi

# --- the fixes stay fixed ------------------------------------------------
# Guards the specific repairs, so a later refactor cannot quietly reintroduce
# the same class of bug while the baseline is being adjusted.
# Code lines only. The comments around each of these fixes quote the broken
# expression by name — which is the point of them — so a plain grep would match
# the explanation and report the repair as still broken.
code() {
    grep -vE '^[[:space:]]*(\*|//|\*)' "$1" | grep -cE "$2"
}

ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

ok "StripCell injects the pill instead of assuming the id" \
    "$(grep -c 'required property var hostPill' "$ROOT/components/StripCell.qml")" "1"

ok "StripCell reaches the pill only through the injected property" \
    "$(grep -cE '(^|[^.a-zA-Z])pill\.' "$ROOT/components/StripCell.qml")" "0"

ok "the pill injects the shell root instead of assuming the id" \
    "$(grep -c 'required property var hostRoot' "$ROOT/Pill.qml")" "1"

ok "the pill mirrors its geometry through the injected root" \
    "$(grep -c 'hostRoot.pillBarHeight' "$ROOT/Pill.qml")" "2"

ok "the shell supplies the root to every pill" \
    "$(grep -c 'hostRoot: root' "$ROOT/shell.qml")" "1"

ok "the font picker's field is anchored to a declared object" \
    "$(code "$ROOT/surfaces/FontPicker.qml" 'searchGlyph')" "0"

ok "the clipboard handler uses the parameter Qt hands it" \
    "$(grep -c 'onPointChanged: (point)' "$ROOT/surfaces/Clipboard.qml")" "1"

ok "the dead throwing manage handler is gone" \
    "$(code "$ROOT/components/Tray.qml" 'manage\.anchorX')" "0"

# The rail must fit its own fixed label. 96*s left the bluetooth name 52*s of
# text against a ~64*s string, which is why "Not connected" rendered as
# "Not connecte.." everywhere. Assert the arithmetic, not the literal, so the
# intent survives a font change.
railW=$(sed -n 's/.*readonly property real railW: \([0-9.]*\) \* s.*/\1/p' "$ROOT/surfaces/Media.qml" | head -1)
bt_label=$(python3 - "$railW" <<'PY'
import sys
# icon 12 + gap 5 + chip 22 + gap 5
print(float(sys.argv[1]) - 12 - 5 - 22 - 5)
PY
)
ok "the right rail leaves the bluetooth label enough room for its fixed fallback" \
    "$(python3 -c "print('yes' if $bt_label >= 64 else 'no')")" "yes"

if [ "$failed" -eq 0 ]; then
    printf 'all green\n'
    exit 0
fi
printf '%d failing\n' "$failed"
exit 1