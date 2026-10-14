/**
 * Pure-model tests for Singletons/Screens.qml.
 *
 * The identity/pairing/draft/refit/refuse helpers are lifted straight out of the
 * shipped QML by regex -- the same lift pattern lib/theme-parse.test.mjs uses for
 * ThemeColors.qml -- so the test exercises the shipped code, not a transcription
 * of it. buildDraft is lifted with pairByIdentity as a dependency, exactly the
 * way theme-parse wires parse <- stripComment.
 *
 * The five functions are pure and the test never touches a compositor: they take
 * plain monitor objects (the shape `parse` in lib/monitors.js already produces,
 * plus the identity + identity fields the singleton adds) and return plain data.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, "..", "Singletons", "Screens.qml"), "utf8");

// Lifts the body of `function name(...) { ... }` (closing brace at 4-space
// indent) out of the QML source, the same way theme-parse.test.mjs does.
function lift(name) {
    const m = src.match(new RegExp(`function ${name}\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n    \\}`));
    assert.ok(m, `Screens.qml still defines function ${name}`);
    return m[1];
}

const identityOf = new Function(`return (function identityOf(mon) {${lift("identityOf")}})`)();
const pairByIdentity = new Function(`return (function pairByIdentity(live, profileScreens) {${lift("pairByIdentity")}})`)();
const buildDraft = new Function("pairByIdentity", `return (function buildDraft(live, profile) {${lift("buildDraft")}})`)(pairByIdentity);
const refit = new Function(`return (function refit(draft) {${lift("refit")}})`)();
const refuseApply = new Function(`return (function refuseApply(draft) {${lift("refuseApply")}})`)();

// -- identity --

test("identityOf prefers serial, then desc:make model, then connector name", () => {
    assert.equal(identityOf({ name: "eDP-1", serial: "ABC123", make: "LG", model: "27MD5KL-W" }), "ABC123");
    assert.equal(identityOf({ name: "HDMI-A-1", make: "HKC", model: "OVERSEAS LIMITED S01" }), "desc:HKC OVERSEAS LIMITED S01");
    assert.equal(identityOf({ name: "DP-3", make: "", model: "X" }), "DP-3");
    assert.equal(identityOf({ name: "DP-3" }), "DP-3");
});

// -- pairing --

test("pairByIdentity matches by identity even when the connector name differs", () => {
    const live = [
        { name: "eDP-1", identity: "ABC" },
        { name: "HDMI-A-1", identity: "desc:HKC OVERSEAS LIMITED S01" },
    ];
    // The profile still names the old port; identity matching pairs it to the
    // live screen regardless.
    const prof = [
        { identity: "desc:HKC OVERSEAS LIMITED S01", output: "DP-1" },
        { identity: "ABC" },
    ];
    const r = pairByIdentity(live, prof);
    assert.equal(r.present, 2);
    assert.equal(r.total, 2);
    assert.equal(r.matched[0].live.name, "HDMI-A-1");
});

test("pairByIdentity reports present/total and a missing screen is not a full match", () => {
    const live = [{ name: "eDP-1", identity: "ABC" }];
    const prof = [
        { identity: "ABC" },
        { identity: "MISSING" },
    ];
    const r = pairByIdentity(live, prof);
    assert.equal(r.present, 1);
    assert.equal(r.total, 2);
    assert.equal(r.matched.length, 2);
    assert.equal(r.matched[0].live.name, "eDP-1");
    assert.equal(r.matched[1].live, null);
    assert.equal(r.full, false);
});

// -- buildDraft --

test("buildDraft starts matched screens from the profile and unmatched live screens from live", () => {
    const live = [
        { name: "eDP-1", identity: "ABC", output: "eDP-1", mode: "1920x1080@60", position: "0x0", scale: 1, transform: 0, mirror: "", enabled: true },
        { name: "HDMI-A-1", identity: "desc:HKC", output: "desc:HKC", mode: "1920x1080@100", position: "0x0", scale: 1, transform: 0, mirror: "", enabled: true },
    ];
    const profile = { screens: [
        { identity: "ABC", mode: "1920x1200@60", position: "0x0", scale: 1.5, transform: 0, mirror: "", enabled: true },
    ] };
    const r = buildDraft(live, profile);
    assert.equal(r.present, 1);
    assert.equal(r.total, 1);
    // matched eDP from profile + unmatched HDMI from live.
    assert.equal(r.draft.length, 2);
    const edp = r.draft.find(s => s.name === "eDP-1");
    assert.equal(edp.mode, "1920x1200@60");      // profile
    assert.equal(edp.scale, 1.5);                // profile
    const hdmi = r.draft.find(s => s.name === "HDMI-A-1");
    assert.equal(hdmi.mode, "1920x1080@100");    // live (not in profile)
    assert.equal(hdmi.scale, 1);                 // live
});

// -- refit --

function boxes(out) { return out.map(s => ({ name: s.name, x: s.x, y: s.y, w: s.ew, h: s.eh })); }
function overlaps(a, b) {
    const ox = Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x));
    const oy = Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
    return ox * oy > 0;
}

test("refit packs three overlapping screens into a non-overlapping row", () => {
    const draft = [
        { name: "A", width: 100, height: 100, x: 0, y: 0, scale: 1, transform: 0 },
        { name: "B", width: 100, height: 100, x: 0, y: 0, scale: 1, transform: 0 },
        { name: "C", width: 100, height: 100, x: 0, y: 0, scale: 1, transform: 0 },
    ];
    const out = refit(draft);
    const b = boxes(out);
    for (let i = 0; i < b.length; i++) {
        for (let j = i + 1; j < b.length; j++) {
            assert.equal(overlaps(b[i], b[j]), false, `${b[i].name} overlaps ${b[j].name}`);
        }
    }
    // abutting in name order
    assert.equal(b[0].x, 0);
    assert.equal(b[1].x, b[0].x + b[0].w);
    assert.equal(b[2].x, b[1].x + b[1].w);
});

test("refit grows a screen's footprint when its scale rises and shifts its neighbour", () => {
    const draft = [
        { name: "A", width: 100, height: 100, x: 0, y: 0, scale: 1, transform: 0 },
        { name: "B", width: 100, height: 100, x: 100, y: 0, scale: 1, transform: 0 },
    ];
    refit(draft);                       // A at 0..100, B at 100..200
    draft.find(s => s.name === "A").scale = 2; // A footprint doubles
    const out = refit(draft);
    const a = out.find(s => s.name === "A");
    const bb = out.find(s => s.name === "B");
    assert.equal(a.ew, 200);            // 100 * scale 2
    assert.equal(bb.x, 200);            // B pushed to the end of A's scaled width
    assert.equal(overlaps({ x: a.x, y: a.y, w: a.ew, h: a.eh }, { x: bb.x, y: bb.y, w: bb.ew, h: bb.eh }), false);
});

test("refit swaps width/height for a 90deg transform", () => {
    const draft = [
        { name: "A", width: 100, height: 200, x: 0, y: 0, scale: 1, transform: 1 },
    ];
    const out = refit(draft);
    assert.equal(out[0].ew, 200);       // 100 <-> 200 swapped by rotation
    assert.equal(out[0].eh, 100);
});

// -- refuseApply (zero enabled) --

test("refuseApply returns false when every screen is disabled", () => {
    assert.equal(refuseApply([
        { name: "A", enabled: false },
        { name: "B", enabled: false },
    ]), false);
});

test("refuseApply returns true when at least one screen is enabled", () => {
    assert.equal(refuseApply([
        { name: "A", enabled: true },
        { name: "B", enabled: false },
    ]), true);
});
