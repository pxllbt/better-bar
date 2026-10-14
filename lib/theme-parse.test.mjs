/**
 * Unit tests for the colors.toml parser in Singletons/ThemeColors.qml.
 *
 * Why this exists: the parser split a line at `=` and then stripped the
 * surrounding quotes, which silently kept anything after the closing quote.
 * A TOML comment after the value — `accent = "#83b755"  # glass` — was
 * therefore parsed as the literal string `"#83b755"  # glass`.
 *
 * That is not a colour, so the bar fell back off the accent entirely: a
 * hand-written theme showed its background and foreground but no accent at
 * all. Stock omarchy themes are machine-generated and carry no inline
 * comments, which is why this only ever showed up on custom themes and
 * looked like "the bar doesn't follow my new theme".
 *
 * What it pins:
 *
 *   * an inline comment is stripped, and the quoted value before it survives
 *   * a `#` INSIDE the quotes (every hex colour) is not mistaken for a
 *     comment — the naive fix of cutting at the first `#` turns `"#83b755"`
 *     into an empty string and breaks every theme, which is worse
 *   * comment-only and blank lines are still skipped
 *   * a bare unquoted value with a trailing comment still parses
 *   * an unterminated quote does not throw and does not swallow the rest
 *
 * The subject is extracted from the QML source rather than duplicated, so a
 * change to the parser is tested, not a copy of it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, "..", "Singletons", "ThemeColors.qml"), "utf8");

// Lift the two parser helpers out of the QML so the test exercises the shipped
// code rather than a transcription of it. `parse` calls `stripComment`, so both
// have to come across for the extracted `parse` to run at all.
function lift(name) {
  const m = src.match(new RegExp(`function ${name}\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n    \\}`));
  assert.ok(m, `ThemeColors.qml still defines function ${name}`);
  return m[1];
}

const stripComment = new Function("value", lift("stripComment"));
const parse = new Function(
  "stripComment",
  `return (function parse(text) {${lift("parse")}})`)(stripComment);

// parseBorder defines pair/byte/alphaOf inside itself, so it lifts standalone.
const parseBorder = new Function(
  `return (function parseBorder(value) {${lift("parseBorder")}})`
)();

test("hyprland_active_border: a hashless 6-digit rgb() is hex, not decimal", () => {
  // The lanterns theme's real value. Hyprland writes rgb() with bare hex
  // digits, which is the form almost every hand-written theme uses.
  const stops = parseBorder("rgb(141412) rgb(009863) rgb(a6936b) rgb(141412) 135deg");
  assert.deepEqual(stops, ["#ff141412", "#ff009863", "#ffa6936b", "#ff141412"]);
});

test("hyprland_active_border: no stop is ever the red an all-digits hex decodes to", () => {
  // The regression this pins: "141412" is all digits, so a decimal reading
  // clamped it to 255 and produced #ffff0000 -- a pure red ring on a theme
  // whose accent is green.
  const stops = parseBorder("rgb(141412) rgb(009863) rgb(a6936b) rgb(141412) 135deg");
  for (const stop of stops) {
    assert.ok(!/^#ff(ff|00)0000$/i.test(stop), `${stop} is the decimal-clamped red`);
  }
});

test("hyprland_active_border: the 8-digit form still means #AARRGGBB", () => {
  // Channel order is the other half of this: Hyprland writes rrggbbaa and Qt
  // wants #AARRGGBB. Handing one to the other silently reinterprets them.
  assert.deepEqual(parseBorder("rgba(0055aaff)"), ["#ff0055aa"]);
  assert.deepEqual(parseBorder("rgba(ff8800ff)"), ["#ffff8800"]);
});

test("hyprland_active_border: the decimal comma form is still decimal", () => {
  assert.deepEqual(parseBorder("rgba(255,136,0,1.0)"), ["#ffff8800"]);
});

test("hyprland_active_border: a comma-separated all-digit form is still decimal", () => {
  // rgba(20,30,40,1.0) is 4 comma-separated channels, so it can only be the
  // decimal form -- 20/255=0x14, 30/255=0x1e, 40/255=0x28. The fix keys on
  // hex-vs-decimal per token, not on "contains a digit", so this does not
  // regress to 0x203040 the way a blanket hex reading would.
  assert.deepEqual(parseBorder("rgba(20,30,40,1.0)"), ["#ff141e28"]);
});

test("hyprland_active_border: rgb() without alpha is opaque", () => {
  assert.deepEqual(parseBorder("rgb(ff8800)"), ["#ffff8800"]);
});

test("keeps the quoted value and drops a trailing comment", () => {
  const out = parse('accent               = "#83b755"  # glass');
  assert.equal(out.accent, "#83b755");
});

test("does not treat a # inside the quotes as a comment", () => {
  // Every hex colour is "#rrggbb". Cutting at the first "#" would yield "".
  const out = parse('accent = "#83b755"');
  assert.equal(out.accent, "#83b755");
  assert.equal(out.accent.length, 7);
});

test("a comment with no space before it is still stripped", () => {
  const out = parse('background = "#141412"# night');
  assert.equal(out.background, "#141412");
});

test("parses the lanterns theme's colour block", () => {
  const toml = [
    'mode = "dark"',
    '',
    '# Lanterns - every colour measured from the wallpapers.',
    'accent               = "#83b755"  # glass',
    'selection            = "#0d4833"  # enamel',
    'background           = "#141412"  # night',
    'foreground           = "#d1cab5"  # bone',
    'hyprland_active_border = "rgb(141412) rgb(009863) rgb(a6936b) rgb(141412) 135deg"',
  ].join("\n");
  const out = parse(toml);
  assert.equal(out.accent, "#83b755");
  assert.equal(out.selection, "#0d4833");
  assert.equal(out.background, "#141412");
  assert.equal(out.foreground, "#d1cab5");
  // No comment, so this one must come through untouched.
  assert.equal(
    out.hyprland_active_border,
    "rgb(141412) rgb(009863) rgb(a6936b) rgb(141412) 135deg"
  );
});

test("every parsed colour is actually a colour", () => {
  const toml = 'accent = "#83b755"  # glass\nbackground = "#141412"  # night';
  for (const [key, value] of Object.entries(parse(toml))) {
    assert.match(value, /^#[0-9a-fA-F]{6}$/, `${key} is not a bare hex colour`);
  }
});

test("skips comment-only and blank lines", () => {
  const out = parse('# just a note\n\naccent = "#ffffff"\n');
  assert.deepEqual(Object.keys(out), ["accent"]);
});

test("an unquoted value with a comment parses", () => {
  const out = parse("mode = dark # the mode");
  assert.equal(out.mode, "dark");
});

test("an unterminated quote does not throw or swallow the next key", () => {
  const out = parse('accent = "#83b755\nforeground = "#d1cab5"');
  assert.ok("foreground" in out, "the line after an unterminated quote still parses");
  assert.equal(out.foreground, "#d1cab5");
});

test("stock machine-generated themes are unchanged", () => {
  const out = parse('mode = "dark"\naccent = "#89b4fa"\nbackground = "#1e1e2e"');
  assert.equal(out.mode, "dark");
  assert.equal(out.accent, "#89b4fa");
  assert.equal(out.background, "#1e1e2e");
});
