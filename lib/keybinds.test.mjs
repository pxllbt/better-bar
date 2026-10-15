import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

/**
 * Keybind model shaping for the native Better Bar keybind manager.
 *
 * The manager UI needs one predictable list shape it can bind to. These are
 * the rules that shape is held to before any QML touches it:
 *
 *   - chords normalize case and spacing, so `ctrl + alt + x` and
 *     "CTRL+ALT+X" are the same key on screen.
 *   - the backend's raw JSON is never trusted to have every field a row
 *     needs; a blank or partial entry must still render, not crash.
 *   - "modified" means the user's own override, which is what makes a Reset
 *     button meaningful.
 *   - conflicts are flattened so a shared chord can be shown as one row
 *     instead of hiding every action behind it.
 */
const src = readFileSync("./lib/keybinds.js", "utf8").replace(/^\.pragma library\s*/, "");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);

const model = {
    active: [
        {
            key: "ctrl + alt + x",
            raw_key: "CTRL+ALT+X",
            description: "Terminal",
            action: "omarchy-launch-terminal",
            category: "Applications",
            status: "default",
            source: "default"
        },
        {
            key: "SUPER+SHIFT+B",
            description: "My Browser",
            action: "omarchy-launch-browser",
            category: "Applications",
            status: "custom",
            source: "user",
            default_key: "SUPER + B",
            default_action: "omarchy-launch-browser"
        },
        {
            key: "SUPER + Q",
            description: "Kill window",
            action: "hl.dsp.window.close()",
            category: "Window Management",
            status: "disabled",
            source: "default"
        }
    ],
    catalog: [
        {
            id: "menu.apps",
            name: "Apps Menu",
            description: "Summon the applications list menu",
            command: "omarchy-menu toggle apps",
            category: "Menus & System",
            default_key: "super + alt + space",
            is_bound: false,
            current_key: ""
        }
    ],
    conflicts: [
        {
            key: "ALT + TAB",
            bindings: [
                { description: "Next window", action: "hl.dsp.window.cycle_next()", status: "modified" },
                { description: "Cycle windows", action: "{ tui = \"btop\" }", status: "custom" }
            ]
        }
    ]
};

test("normalizes a chord's case and separators", () => {
    assert.equal(ctx.normalizeKey("ctrl + alt + x"), "CTRL + ALT + X");
    assert.equal(ctx.normalizeKey("  super+shift+b "), "SUPER + SHIFT + B");
});

test("parses a model and normalizes active rows", () => {
    const parsed = ctx.parseModel(JSON.stringify(model));
    const terminal = parsed.active.find((r) => r.description === "Terminal");
    assert.equal(terminal.key, "CTRL + ALT + X");
    assert.equal(parsed.totals.total_modified, 1);
});

test("shows every active binding under the active tab", () => {
    const rows = ctx.rowsFor(model, "active");
    assert.equal(rows.length, 3);
    assert.equal(rows.map((r) => r.key).join(" | "),
        "SUPER + Q | SUPER + SHIFT + B | CTRL + ALT + X");
});

test("only overrides are rows under the modified tab", () => {
    const rows = ctx.rowsFor(model, "modified");
    assert.equal(rows.length, 1);
    assert.equal(rows[0].description, "My Browser");
    assert.equal(ctx.canReset(rows[0]), true);
});

test("flattens a conflict into one row that names the shared chord", () => {
    const rows = ctx.rowsFor(model, "conflicts");
    assert.equal(rows.length, 1);
    assert.equal(rows[0].key, "ALT + TAB");
    assert.equal(rows[0].bindings.length, 2);
    assert.equal(ctx.canReset(rows[0]), false);
});

test("maps a catalog preset into a bindable row", () => {
    const rows = ctx.rowsFor(model, "catalog");
    assert.equal(rows.length, 1);
    assert.equal(rows[0].key, "SUPER + ALT + SPACE");
    assert.equal(rows[0].description, "Apps Menu");
    assert.equal(rows[0].action, "omarchy-menu toggle apps");
});

test("search matches key, description, action and category together", () => {
    const rows = ctx.rowsFor(model, "active").filter((r) => ctx.matches(r, "super+q"));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].description, "Kill window");

    const byCommand = ctx.rowsFor(model, "active").filter((r) => ctx.matches(r, "omarchy-launch-browser"));
    assert.equal(byCommand.length, 1);
    assert.equal(byCommand[0].description, "My Browser");
});

test("builds a chord from modifier flags and the pressed key", () => {
    assert.equal(ctx.keyFromEvent(false, false, false, false, "Key_Q", "q"), "Q");
    assert.equal(ctx.keyFromEvent(false, false, false, true, "Key_W", "w"), "SUPER + W");
    assert.equal(ctx.keyFromEvent(true, true, false, true, "Key_S", "S"), "SUPER + CTRL + ALT + S");
    assert.equal(ctx.keyFromEvent(false, false, false, false, "Key_Return", "\r"), "RETURN");
});

test("ignores a bare modifier press so it cannot bind a half-chord", () => {
    assert.equal(ctx.keyFromEvent(false, false, false, false, "Key_Control", ""), "");
    assert.equal(ctx.keyFromEvent(false, false, true, false, "Key_Shift", ""), "");
});
