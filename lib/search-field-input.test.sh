#!/usr/bin/env bash
# Asserts that Better Bar's text-entry path performs no clipboard reads.
#
# The finding this exists for: QQuickTextInput keeps its `canPaste` state current
# on every clipboard-change signal.
#
#     d->canPaste = !d->m_readOnly && mimeData->hasText();     // qquicktextinput.cpp
#
# That mimeData() call is the read: it resolves the selection another client
# offers, and on Wayland there is no byte cap and no deadline on it, so a slow or
# huge selection can stall the one process every surface of the bar shares.
# `maximumLength` bounds what a field STORES, never that transfer.
#
# Two facts from the Qt source decide the whole fix:
#
#   * `!d->m_readOnly` short-circuits, so a readOnly field never calls
#     mimeData() at all -- the read is gone, not merely capped.
#   * every editing path is gated the same way: `if (!m_readOnly) { backspace();
#     del(); deleteStartOfWord(); }` and `if (unknown && !m_readOnly) {
#     insert(event->text()); }`.
#
# So every editable field in the bar is now `readOnly: true` -- killing the
# clipboard read and the native editing at once -- with the editing put back
# from the keyboard side by Singletons/TextEntry.qml. Left/Right/Home/End,
# Return, `accepted()`/`editingFinished()` and Escape are NOT readOnly-gated in
# Qt, so they keep working through each item's own handlers and no site needed
# changing for them.
#
# A QML-only guard cannot express this -- Qt's clipboard interaction is C++-side
# and invisible to the type system. So this reads the files as text and checks
# the declarations that would reintroduce the read. Same reasoning as
# lib/surfaces-wired.test.sh: the failure is a missing declaration, and QML would
# only report it as an exception in whatever happened to touch it next.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$ROOT/Singletons/TextEntry.qml" ] || { echo "no TextEntry.qml" >&2; exit 1; }
[ -f "$ROOT/components/SearchField.qml" ] || { echo "no SearchField.qml" >&2; exit 1; }

# --- the shared editing engine ----------------------------------------------
ok "TextEntry is registered as a singleton" \
    "$(grep -c '^singleton[[:space:]]\+TextEntry[[:space:]]\+TextEntry\.qml$' "$ROOT/Singletons/qmldir")" "1"

# The engine's contract. A count rather than a list, because what matters is that
# it exists and restores exactly the editing readOnly removed.
ok "TextEntry implements the editing readOnly removed" \
    "$(grep -cE '^    function (handle|insert|backward|forward|deleteWordBackward)' "$ROOT/Singletons/TextEntry.qml")" "5"

# Return/Enter and Escape are deliberately NOT handled: Qt still runs the
# `accepted()` path for them with readOnly, so handling them here would fire
# every activation twice. If someone adds them, that double-fire comes back.
ok "TextEntry does not touch Return or Escape" \
    "$(sed -n '/^    function handle(/,/^    \}$/p' "$ROOT/Singletons/TextEntry.qml" \
        | grep -cE 'Key_Return|Key_Enter|Key_Escape')" "0"

# --- the bar's search field carries no editable input at all ----------------
SEARCHFIELD="$ROOT/components/SearchField.qml"
# The one declaration that matters: `TextInput {` or `TextField {`. Prose in the
# documentation comment is fine; a brace is a declaration.
ok "SearchField declares no editable text input" \
    "$(grep -cE '(TextInput|TextField)[[:space:]]*\{' "$SEARCHFIELD")" "0"
ok "SearchField documents the clipboard-read reason" \
    "$(grep -cE 'QClipboard|mimeData' "$SEARCHFIELD")" "2"

# --- structural pass over every editable field in the surfaces --------------
# One walk emits "file\tid\treadOnly\tselectFalse\tselectTrue\twired\tcaret" so
# the shell side only compares counts. The analysis has to be structural: a
# `selectByMouse` on a display-only TextEdit (WifiSurface's revealed password) is
# a different thing from one on a field the user types into, and counting them
# per file conflates the two.
while IFS=$'\t' read -r f id ro sf st wired caret; do
    [ -z "$f" ] && continue
    printf '  %s %s\n' "$f" "${id:-?}"
    idom="${id:-unnamed}"
    ok "$idom in $(basename "$f") is readOnly" "$ro" "yes"
    ok "$idom in $(basename "$f") is not mouse-selectable" "$st" "no"
    ok "$idom in $(basename "$f") routes keys through the engine" "$wired" "yes"
    ok "$idom in $(basename "$f") re-arms its caret" "$caret" "yes"
done < <(python3 - "$ROOT" <<'PY'
import re, sys, os, glob

root = sys.argv[1]
for path in sorted(glob.glob(os.path.join(root, 'surfaces', '*.qml'))):
    src = open(path).read()
    for m in re.finditer(r'(TextField|TextInput)[ \t]*\{', src):
        i = src.index('{', m.start()); depth = 0; j = i
        while j < len(src):
            if src[j] == '{': depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0: break
            j += 1
        body = src[i:j+1]
        idm = re.search(r'\bid:[ \t]*([A-Za-z_]\w*)', body)
        fid = idm.group(1) if idm else ''
        ro  = 'yes' if re.search(r'(?m)^[ \t]*readOnly:[ \t]*true', body) else 'no'
        st  = 'yes' if re.search(r'(?m)^[ \t]*selectByMouse:[ \t]*true', body) else 'no'
        wr  = 'yes' if 'TextEntry.handle(' in body else 'no'
        cv  = 'yes' if 'cursorVisible = activeFocus' in body else 'no'
        print('\t'.join([path, fid, ro, 'yes', st, wr, cv]))
PY
)

# --- a native input field cannot outlive the surface ------------------------
# The clipboard surface's field is gated on the surface's own active state, and
# the pill reclaims its loader the moment it closes. Both halves are needed: the
# gate stops a closed field holding focus, and the immediate reclaim stops the
# object tree existing at all while closed.
CLIP="$ROOT/surfaces/Clipboard.qml"
if [ -f "$CLIP" ]; then
    ok "the clipboard field is gated on the surface's active state" \
        "$(grep -c 'search\.active[[:space:]]*=' "$CLIP")" "1"
fi
PILL="$ROOT/Pill.qml"
if [ -f "$PILL" ]; then
    ok "the pill reclaims the clipboard loader on close" \
        "$(grep -c 'dropClosed("clipboard")' "$PILL")" "1"
    ok "the clipboard surface's idle tier is zero" \
        "$(grep -c 'clipboard:[[:space:]]*0' "$PILL")" "1"
fi

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
