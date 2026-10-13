/**
 * Unit tests for the keyboard editing engine in Singletons/TextEntry.qml.
 *
 * Why this exists in JS rather than as a QML harness: the engine is a pure
 * function set over a plain object ({ text, cursorPosition, selectionStart,
 * selectionEnd, maximumLength, entryChars, select() }), so it can be exercised
 * headlessly with no display, no Wayland seat and no Quickshell instance. A QML
 * harness would only ever have produced "I typed into a field once", which is
 * exactly the kind of check that passes while the caret ends up in the wrong
 * place.
 *
 * What it pins:
 *
 *   * the editing readOnly removed — insertion at the caret, Backspace, Delete,
 *     Ctrl+Backspace word delete — because that is the whole reason TextEntry
 *     exists at all
 *   * `maximumLength` and `entryChars`, which are the field-level rules Qt used
 *     to enforce and now does not, because the native insert() path never runs
 *   * the caret landing in the right place after every operation, which is what
 *     a visual check would miss
 *   * what `handle()` refuses to touch — Return and Escape stay with Qt, so
 *     `accepted()`/`editingFinished()` are not fired twice
 *
 * The subject is extracted from the QML source rather than duplicated, so a
 * change to the engine is tested, not a copy of it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const source = fs.readFileSync(path.join(root, "Singletons", "TextEntry.qml"), "utf8");

/** Keys the engine names, mirrored from Qt's enum so the stub is honest. */
const Qt = {
  ControlModifier: 0x04000000,
  Key_Backspace: 0x01000003,
  Key_Delete: 0x01000007,
  Key_Left: 0x01000012,
  Key_Right: 0x01000014,
  Key_Up: 0x01000013,
  Key_Down: 0x01000015,
  Key_Home: 0x01000010,
  Key_End: 0x01000011,
  Key_Return: 0x01000004,
  Key_Enter: 0x01000005,
  Key_Escape: 0x01000000,
};

/**
 * Pull every top-level `function` out of the singleton body and evaluate them
 * together, so a sibling call resolves to the sibling in scope. Returns the
 * engine object the QML file exports.
 */
function loadEngine() {
  const start = source.indexOf("Singleton {");
  assert.ok(start >= 0, "TextEntry.qml has no Singleton root");
  const bodyStart = source.indexOf("{", start);
  let depth = 0;
  let end = -1;
  for (let i = bodyStart; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}") {
      depth--;
      if (depth === 0) { end = i; break; }
    }
  }
  assert.ok(end > bodyStart, "could not find the end of the Singleton block");
  const body = source.slice(bodyStart + 1, end);

  // Collect `function name(args) { ... }` at four-space indentation.
  const decls = [];
  const re = /^    function (\w+)\(([^)]*)\)\s*\{/gm;
  let m;
  while ((m = re.exec(body)) !== null) {
    const open = body.indexOf("{", m.index + m[0].length - 1);
    let d = 0;
    let close = -1;
    for (let i = open; i < body.length; i++) {
      if (body[i] === "{") d++;
      else if (body[i] === "}") {
        d--;
        if (d === 0) { close = i; break; }
      }
    }
    assert.ok(close > open, `unbalanced body for function ${m[1]}`);
    decls.push({ name: m[1], args: m[2], text: body.slice(open, close + 1) });
  }

  assert.ok(decls.some((f) => f.name === "handle"), "TextEntry.qml declares no handle()");
  const names = decls.map((f) => f.name);
  const src = `"use strict";\n${decls.map((f) => `function ${f.name}(${f.args}) ${f.text}`).join("\n")}\n`
    + `return { ${names.join(", ")} };`;
  return new Function("Qt", src)(Qt);
}

const engine = loadEngine();

/** A stand-in for a readOnly TextField: the surface the engine writes to. */
function field(over = {}) {
  const self = {
    text: "",
    cursorPosition: 0,
    selectionStart: 0,
    selectionEnd: 0,
    maximumLength: 0,
    entryChars: "",
    select(start, end) {
      self.selectionStart = start;
      self.selectionEnd = end;
      self.cursorPosition = end;
    },
    ...over,
  };
  if (over.select) self.select = over.select;
  return self;
}

/** A synthetic key event, matching the shape the QML handler receives. */
function key(k, extra = {}) {
  return { key: k, modifiers: 0, text: "", accepted: false, ...extra };
}

// --- insertion ---------------------------------------------------------------

test("a printable character lands at the caret", () => {
  const f = field({ text: "ac", cursorPosition: 1 });
  engine.insert(f, "b");
  assert.equal(f.text, "abc");
  assert.equal(f.cursorPosition, 2, "caret advances past the inserted character");
});

test("insertion at the end appends", () => {
  const f = field({ text: "ab", cursorPosition: 2 });
  engine.insert(f, "c");
  assert.equal(f.text, "abc");
  assert.equal(f.cursorPosition, 3);
});

test("maximumLength is still enforced", () => {
  // Qt's native insert() never runs now, so this rule is TextEntry's to keep.
  const f = field({ text: "ab", cursorPosition: 2, maximumLength: 3 });
  engine.insert(f, "c");
  assert.equal(f.text, "abc");
  engine.insert(f, "d");
  assert.equal(f.text, "abc", "a character past the cap is dropped");
  assert.equal(f.cursorPosition, 3);
});

test("maximumLength does not strand the caret", () => {
  const f = field({ text: "abc", cursorPosition: 1, maximumLength: 3 });
  engine.insert(f, "X");
  assert.equal(f.text, "abc");
  assert.equal(f.cursorPosition, 1, "a rejected insertion leaves the caret put");
});

test("entryChars limits what a field will accept", () => {
  const f = field({ cursorPosition: 0, entryChars: "[0-9:]" });
  engine.insert(f, "0");
  engine.insert(f, "9");
  engine.insert(f, ":");
  assert.equal(f.text, "09:");
  assert.equal(f.cursorPosition, 3);
  engine.insert(f, "a");
  assert.equal(f.text, "09:", "a character outside the class is refused");
  assert.equal(f.cursorPosition, 3, "the caret does not advance for a refusal");
});

test("typing over a selection replaces it", () => {
  // The launcher's rename field selectAll()s the label on open; the first
  // keystroke has to take its place rather than append after it.
  const f = field({ text: "Old Name", cursorPosition: 8, selectionStart: 0, selectionEnd: 8 });
  engine.insert(f, "N");
  assert.equal(f.text, "N");
  assert.equal(f.selectionStart, f.selectionEnd, "the selection collapses");
  assert.equal(f.cursorPosition, 1);
});

// --- deletion ----------------------------------------------------------------

test("Backspace deletes the character before the caret", () => {
  const f = field({ text: "abc", cursorPosition: 3 });
  engine.backward(f);
  assert.equal(f.text, "ab");
  assert.equal(f.cursorPosition, 2);
});

test("Backspace at the start is a no-op", () => {
  const f = field({ text: "abc", cursorPosition: 0 });
  engine.backward(f);
  assert.equal(f.text, "abc");
  assert.equal(f.cursorPosition, 0);
});

test("Delete removes the character at the caret", () => {
  const f = field({ text: "abc", cursorPosition: 1 });
  engine.forward(f);
  assert.equal(f.text, "ac");
  assert.equal(f.cursorPosition, 1);
});

test("Delete at the end is a no-op", () => {
  const f = field({ text: "abc", cursorPosition: 3 });
  engine.forward(f);
  assert.equal(f.text, "abc");
  assert.equal(f.cursorPosition, 3);
});

test("Backspace over a selection deletes the selection", () => {
  // "abcdef" with 2..5 ("cde") selected leaves "ab" + "f".
  const f = field({ text: "abcdef", cursorPosition: 2, selectionStart: 2, selectionEnd: 5 });
  engine.backward(f);
  assert.equal(f.text, "abf");
  assert.equal(f.cursorPosition, 2);
});

test("Delete over a selection deletes the selection", () => {
  const f = field({ text: "abcdef", cursorPosition: 2, selectionStart: 1, selectionEnd: 3 });
  engine.forward(f);
  assert.equal(f.text, "adef");
  assert.equal(f.cursorPosition, 1);
});

test("Ctrl+Backspace removes a whole word", () => {
  const f = field({ text: "hello world", cursorPosition: 11 });
  engine.deleteWordBackward(f);
  assert.equal(f.text, "hello ");
  assert.equal(f.cursorPosition, 6);
});

test("Ctrl+Backspace stops at a word boundary, not zero", () => {
  const f = field({ text: "hello world", cursorPosition: 8 });
  engine.deleteWordBackward(f);
  assert.equal(f.text, "hello rld");
  assert.equal(f.cursorPosition, 6);
});

test("Ctrl+Backspace across a run of spaces stops at the word", () => {
  const f = field({ text: "a   b", cursorPosition: 5 });
  engine.deleteWordBackward(f);
  assert.equal(f.text, "a   ");
  assert.equal(f.cursorPosition, 4);
});

// --- caret bookkeeping -------------------------------------------------------

test("the caret is clamped when the text shortens under it", () => {
  const f = field({ text: "abcdef", cursorPosition: 6 });
  f.text = "ab";
  // `elapsed`-style derived reads are not applicable; simulate the clamp the
  // engine's callers rely on by re-inserting, which re-derives from `caret`.
  assert.equal(engine.caret(f), 2);
});

test("a non-numeric caret is treated as the end", () => {
  const f = field({ text: "abc", cursorPosition: NaN });
  assert.equal(engine.caret(f), 3);
});

// --- key routing -------------------------------------------------------------

test("handle() consumes a printable key and marks it accepted", () => {
  const f = field();
  const e = key(0, { text: "a" });
  assert.equal(engine.handle(f, e), true);
  assert.equal(f.text, "a");
  assert.equal(e.accepted, true);
});

test("handle() consumes Backspace and Delete", () => {
  const f = field({ text: "ab", cursorPosition: 2 });
  assert.equal(engine.handle(f, key(Qt.Key_Delete)), true);
  assert.equal(f.text, "ab", "Delete at the end changes nothing but is still consumed");
  f.text = "ab";
  f.cursorPosition = 2;
  assert.equal(engine.handle(f, key(Qt.Key_Backspace)), true);
  assert.equal(f.text, "a");
});

test("handle() leaves arrow keys to Qt and the site's handlers", () => {
  // Deliberate: cursorForward() is not readOnly-gated in Qt, and a site with
  // horizontalNav maps Left/Right to its own list movement in the same
  // Keys.onPressed that calls handle(). Consuming them here would swallow both.
  const f = field({ text: "ab", cursorPosition: 2 });
  for (const k of [Qt.Key_Up, Qt.Key_Down, Qt.Key_Left, Qt.Key_Right, Qt.Key_Home, Qt.Key_End]) {
    const e = key(k);
    assert.equal(engine.handle(f, e), false, `key ${k} must not be consumed`);
    assert.equal(e.accepted, false);
    assert.equal(f.text, "ab", `key ${k} must not edit the text`);
    assert.equal(f.cursorPosition, 2, `key ${k} must not move the caret itself`);
  }
});

test("handle() leaves Return and Escape alone", () => {
  // Qt still emits accepted()/editingFinished() for Return with readOnly, and a
  // site's Keys.onEscapePressed still fires. Handling them here too would fire
  // every activation twice.
  const f = field({ text: "ab", cursorPosition: 2 });
  for (const k of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Escape]) {
    const e = key(k);
    assert.equal(engine.handle(f, e), false, `key ${k} must not be consumed`);
    assert.equal(e.accepted, false);
    assert.equal(f.text, "ab", `key ${k} must not edit the text`);
  }
});

test("handle() refuses to delete a word on any other Ctrl combo", () => {
  // Ctrl+A/C/V/X stay with Qt: selection works under readOnly and cut() would
  // put text on the clipboard, the opposite of what readOnly is for.
  const f = field({ text: "hello", cursorPosition: 5 });
  const e = key(Qt.Key_C, { modifiers: Qt.ControlModifier });
  assert.equal(engine.handle(f, e), false);
  assert.equal(f.text, "hello");
});

test("handle() drops control characters rather than inserting them", () => {
  const f = field();
  const e = key(0, { text: "\u001b" });
  assert.equal(engine.handle(f, e), false, "an escaped text is not printable input");
  assert.equal(f.text, "");
});

test("handle() inserts a multi-character text run", () => {
  const f = field();
  engine.handle(f, key(0, { text: "ab" }));
  assert.equal(f.text, "ab");
  assert.equal(f.cursorPosition, 2);
});

test("clear() empties the value and parks the caret", () => {
  const f = field({ text: "abc", cursorPosition: 2 });
  engine.clear(f);
  assert.equal(f.text, "");
  assert.equal(f.cursorPosition, 0);
});

test("a selection helper reports nothing when the range is empty", () => {
  const f = field({ text: "abc", selectionStart: 2, selectionEnd: 2 });
  assert.equal(engine.selection(f).start, -1);
  assert.equal(engine.selection(f).end, -1);
});
