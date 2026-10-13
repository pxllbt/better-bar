import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

/**
 * Backspace, Delete and insert-at-caret in the search field.
 *
 * THE BUG THIS EXISTS FOR. The field is a plain Item with a JS buffer, because a
 * TextInput would read the clipboard on every change signal. Its buffer is
 * mirrored through `property alias text`, and `onBufferChanged` clamps the caret
 * down whenever that buffer assignment runs.
 *
 * The clamp fires synchronously inside the assignment -- and deleteBackward()
 * only decremented the caret AFTER it. For a backspace at the end of the text
 * the clamp has already produced the correct answer (the buffer is one shorter),
 * so the extra `-= 1` decremented it a second time. Typing "hello" and deleting
 * left "hell", "hel", "hl", "l", and then a caret of 0 that made every further
 * backspace return early: one character stuck, and the buffer corrupted along
 * the way because each step skipped a character.
 *
 * The fix derives the new caret from the caret captured BEFORE the edit and
 * writes it after the buffer, so the clamp is a no-op and the two agree.
 */

// A proxy that reproduces the component's buffer/caret pair, including the
// synchronous onBufferChanged clamp.
class Proxy {
    constructor() { this._buffer = ""; this._caret = 0; }
    get buffer() { return this._buffer; }
    set buffer(v) {
        this._buffer = v;
        this._caret = Math.max(0, Math.min(this._caret, this._buffer.length));
    }
    get caret() { return this._caret; }
    set caret(v) { this._caret = v; }
}

// The three mutators, transcribed from the fixed SearchField.qml.
const insertString = (f, str) => {
    const at = f.caret;
    f.buffer = f.buffer.substring(0, at) + str + f.buffer.substring(at);
    f.caret = at + str.length;
};
const deleteBackward = (f) => {
    if (f.caret <= 0) return false;
    const p = f.caret;
    f.buffer = f.buffer.substring(0, p - 1) + f.buffer.substring(p);
    f.caret = p - 1;
    return true;
};
const deleteForward = (f) => {
    const p = f.caret;
    if (p >= f.buffer.length) return false;
    f.buffer = f.buffer.substring(0, p) + f.buffer.substring(p + 1);
    f.caret = p;
    return true;
};

const type = (f, s) => { for (const c of s) insertString(f, c); };
const clear = (f) => {
    // Exactly what the keyboard does, one press at a time. The bound is captured
    // once: re-reading f.buffer.length inside the condition would shrink the
    // bound as the buffer empties and stop the loop early, which reads as the
    // very bug this file is testing for.
    const n = f.buffer.length + 3;
    for (let i = 0; i < n; i++) deleteBackward(f);
};

test("SearchField derives the caret from its pre-edit value", () => {
    const src = readFileSync("./components/SearchField.qml", "utf8");
    const back = src.slice(src.indexOf("function deleteBackward()"),
                           src.indexOf("function deleteForward()"));
    assert.match(back, /var p = inputProxy\.caret;/,
        "deleteBackward captures the caret before mutating the buffer");
    assert.match(back, /inputProxy\.caret = p - 1;/,
        "deleteBackward writes an absolute caret");
    assert.doesNotMatch(back, /inputProxy\.caret -= 1/,
        "no decrement after the buffer assignment -- the clamp already did it");

    const fwd = src.slice(src.indexOf("function deleteForward()"),
                          src.indexOf("A caret move out of sync"));
    assert.match(fwd, /inputProxy\.caret = p;/,
        "deleteForward writes an absolute caret");

    const ins = src.slice(src.indexOf("function insertString(str)"),
                          src.indexOf("function deleteBackward()"));
    assert.match(ins, /var at = inputProxy\.caret;/,
        "insertString captures the caret before mutating the buffer");
    assert.match(ins, /inputProxy\.caret = at \+ str\.length;/,
        "insertString writes an absolute caret");
});

test("typing a query and backspacing erases everything", () => {
    const f = new Proxy();
    type(f, "hello");
    clear(f);
    assert.equal(f.buffer, "");
});

test("delete is lossless for queries of any length", () => {
    for (const q of ["a", "ab", "abc", "the quick brown fox", "a".repeat(64)]) {
        const f = new Proxy();
        type(f, q);
        clear(f);
        assert.equal(f.buffer, "", `query "${q}" left "${f.buffer}"`);
        assert.equal(f.caret, 0);
    }
});

test("no intermediate buffer skips a character", () => {
    // The double decrement also corrupted the text: each step jumped two
    // positions, so "abcde" came back as "ace". Every intermediate must stay a
    // subsequence of what was typed.
    const f = new Proxy();
    type(f, "abcdef");
    const seen = [];
    while (f.buffer.length && seen.length < 20) {
        seen.push(f.buffer);
        deleteBackward(f);
    }
    for (const s of seen) {
        assert.ok("abcdef".includes(s), `intermediate "${s}" is not a subsequence`);
    }
});

test("backspace from a mid-string caret removes exactly the character before it", () => {
    const f = new Proxy();
    type(f, "abcde");
    f.caret = 2;                      // sits between "ab" and "cde"
    deleteBackward(f);
    assert.equal(f.buffer, "acde");
    assert.equal(f.caret, 1);
});

test("insert at a caret splices rather than appends", () => {
    const f = new Proxy();
    type(f, "ab");
    f.caret = 1;
    insertString(f, "XY");
    assert.equal(f.buffer, "aXYb");
    assert.equal(f.caret, 3);
});

test("delete forward removes the character at the caret", () => {
    const f = new Proxy();
    type(f, "abcde");
    f.caret = 2;
    deleteForward(f);
    assert.equal(f.buffer, "abde");
    assert.equal(f.caret, 2, "delete-forward must not move the caret");
});

test("delete at the ends is a no-op, not a corruption", () => {
    const empty = new Proxy();
    assert.equal(deleteBackward(empty), false);
    assert.equal(deleteForward(empty), false);
    assert.equal(empty.buffer, "");

    const full = new Proxy();
    type(full, "abc");
    assert.equal(deleteForward(full), false, "forward delete at the end is a no-op");
    assert.equal(full.buffer, "abc");
});
