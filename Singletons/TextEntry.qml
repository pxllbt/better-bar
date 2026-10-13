pragma Singleton

import QtQuick
import Quickshell

/**
 * Keyboard editing for readOnly text fields.
 *
 * Why every editable field in this bar is `readOnly` and driven from here:
 *
 * QQuickTextInput keeps its `canPaste` state current on every clipboard-change
 * signal:
 *
 *     d->canPaste = !d->m_readOnly && mimeData->hasText();
 *
 * (qtdeclarative qquicktextinput.cpp, `q_canPasteChanged`). That `mimeData()`
 * call is the read: it resolves the selection another client offers, and on
 * Wayland there is no byte cap and no deadline on it, so a slow or enormous
 * selection can stall the one process every surface of the bar shares.
 * `maximumLength` bounds what a field stores, never that transfer.
 *
 * Every editing path is gated the same way — `if (!m_readOnly) { backspace();
 * del(); deleteStartOfWord(); ... }` and the insertion at the end of
 * `processKeyEvent`:
 *
 *     if (unknown && !m_readOnly) { insert(event->text()); }
 *
 * So `readOnly: true` removes the clipboard read AND the native editing, and
 * this file puts the editing back from the keyboard side. What it restores is
 * exactly the subset a filter or settings field needs:
 *
 *   * printable characters, inserted at the caret
 *   * Backspace / Delete, and Ctrl+Backspace for a whole word
 *
 * What it deliberately does not touch, because Qt still does those with
 * readOnly and doing them twice would double every keystroke:
 *
 *   * Return / Enter — `processKeyEvent` emits `accepted()` and
 *     `editingFinished()` on that path regardless of readOnly, so a site's
 *     `onAccepted:` or `Keys.onReturnPressed:` keeps working untouched
 *   * Left / Right / Home / End — `cursorForward()` is not readOnly-gated
 *   * Escape — falls through to the site's own handler
 *
 * The caret has to be re-armed by hand: `handleFocusEvent` only shows it
 * `if (!m_readOnly)`. A site whose field is focused binds
 * `onActiveFocusChanged: cursorVisible = activeFocus` for that.
 */
Singleton {
    id: root

    /**
     * Feed one key event to `field`. Returns true when this engine consumed it,
     * so a site's own `Keys.onPressed` can skip its branches for those keys.
     * Everything unconsumed is left exactly as Qt handles it.
     */
    function handle(field, event) {
        if (!field || !event)
            return false;

        if (event.modifiers & Qt.ControlModifier) {
            // Ctrl+A/C/V/X stay with Qt: selection works under readOnly, and
            // cut() would put text on the clipboard, which is the opposite of
            // what this exists to do. Only the word-delete is re-implemented.
            if (event.key === Qt.Key_Backspace) {
                deleteWordBackward(field);
                event.accepted = true;
                return true;
            }
            return false;
        }

        if (event.key === Qt.Key_Backspace) {
            backward(field);
            event.accepted = true;
            return true;
        }
        if (event.key === Qt.Key_Delete) {
            forward(field);
            event.accepted = true;
            return true;
        }

        if (event.text && event.text.length > 0) {
            // Printable input only. Key names carry an empty text, and control
            // characters never belong in a settings value.
            var code = event.text.charCodeAt(0);
            if (code >= 32 && code !== 127) {
                insert(field, event.text);
                event.accepted = true;
                return true;
            }
        }
        return false;
    }

    /** Characters a field will accept, as a regex source. Empty = any printable. */
    function allowed(field) {
        return field.entryChars ? String(field.entryChars) : "";
    }

    function cap(field) {
        var n = Number(field.maximumLength);
        return (n && n > 0) ? n : 4096;
    }

    function caret(field) {
        var p = Number(field.cursorPosition);
        if (!isFinite(p))
            p = field.text.length;
        return Math.max(0, Math.min(field.text.length, p));
    }

    /** Selection bounds, or -1/-1 when nothing is selected. Readable under readOnly. */
    function selection(field) {
        var s = Number(field.selectionStart);
        var e = Number(field.selectionEnd);
        if (!isFinite(s) || !isFinite(e) || e <= s)
            return { start: -1, end: -1 };
        return { start: Math.max(0, Math.min(field.text.length, s)),
                 end: Math.max(0, Math.min(field.text.length, e)) };
    }

    function collapse(field, at) {
        field.select(at, at);
        field.cursorPosition = at;
    }

    function insert(field, str) {
        var allow = allowed(field);
        if (allow.length > 0 && !new RegExp(allow).test(str))
            return;
        var sel = selection(field);
        if (sel.start >= 0) {
            // Typing over a selection replaces it, the way any editor does. This
            // is what makes the launcher's rename field behave: it selectAll()s
            // the existing label on open, and the first keystroke should take
            // its place rather than append after it.
            var t = field.text.substring(0, sel.start) + str + field.text.substring(sel.end);
            if (t.length > cap(field))
                return;
            field.text = t;
            collapse(field, sel.start + str.length);
            return;
        }
        if (field.text.length + str.length > cap(field))
            return;
        var p = caret(field);
        field.text = field.text.substring(0, p) + str + field.text.substring(p);
        field.cursorPosition = p + str.length;
    }

    function backward(field) {
        var sel = selection(field);
        if (sel.start >= 0) {
            field.text = field.text.substring(0, sel.start) + field.text.substring(sel.end);
            collapse(field, sel.start);
            return;
        }
        var p = caret(field);
        if (p <= 0)
            return;
        field.text = field.text.substring(0, p - 1) + field.text.substring(p);
        field.cursorPosition = p - 1;
    }

    function forward(field) {
        var sel = selection(field);
        if (sel.start >= 0) {
            field.text = field.text.substring(0, sel.start) + field.text.substring(sel.end);
            collapse(field, sel.start);
            return;
        }
        var p = caret(field);
        if (p >= field.text.length)
            return;
        field.text = field.text.substring(0, p) + field.text.substring(p + 1);
        field.cursorPosition = p;
    }

    /** Delete back to the previous word boundary, like Ctrl+Backspace in any editor. */
    function deleteWordBackward(field) {
        var t = field.text;
        var p = caret(field);
        if (p <= 0)
            return;
        var i = p;
        while (i > 0 && /\s/.test(t.charAt(i - 1)))
            i -= 1;
        while (i > 0 && !/\s/.test(t.charAt(i - 1)))
            i -= 1;
        if (i === p)
            i = Math.max(0, p - 1);
        field.text = t.substring(0, i) + t.substring(p);
        field.cursorPosition = i;
    }

    /** Replace the whole value, leaving the caret at its end. Used by "clear" glyphs. */
    function clear(field) {
        field.text = "";
        field.cursorPosition = 0;
    }
}
