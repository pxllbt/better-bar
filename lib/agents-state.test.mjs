#!/usr/bin/env node
// Asserts the state machine that drives the agent badge from inside OpenCode.
//
// Why it exists: the badge is the whole point, and the states are easy to get
// subtly wrong in ways that only show up as noise. A `waiting` that fires on the
// permission request itself flashes a pulsing "!" for a frame on every
// auto-approved action -- which teaches you to ignore the one badge that is
// supposed to mean "this needs you". A `done` that lingers is worse: a badge
// that never clears is a badge you stop seeing. And a permission that gets
// answered must retract the pending count, or the session reports `waiting`
// forever on a prompt nobody is looking at.
//
// The transition table is therefore asserted exactly, not sampled.

import { strict as assert } from "node:assert";
import { WAIT_DELAY, INITIAL, needsWaitTimer, reduce } from "./agents-state.mjs";

let failed = 0;
let passed = 0;

function test(name, fn) {
    try {
        fn();
        passed++;
        process.stdout.write(`PASS ${name}\n`);
    } catch (e) {
        failed++;
        process.stdout.write(`FAIL ${name}\n  ${e.message}\n`);
    }
}

// A convenience that walks a list of signals and collects what was emitted, so
// a scenario reads as the sequence it is.
function run(signals, from) {
    const emits = [];
    let state = from || INITIAL;
    for (const s of signals) {
        state = reduce(state, s);
        if (state.emit) emits.push(state.emit);
    }
    return { emits, state };
}

test("the wait delay is long enough to not flash, short enough to be useful", () => {
    assert.ok(WAIT_DELAY >= 1000, "under 1s and it flickers on auto-approve");
    assert.ok(WAIT_DELAY <= 5000, "over 5s and the badge arrives after you gave up");
});

test("a fresh session reports nothing until something happens", () => {
    assert.deepEqual(run([]).emits, []);
});

test("a prompt starts work", () => {
    assert.deepEqual(run(["prompt"]).emits, ["working"]);
});

test("a tool finishing is work continuing", () => {
    assert.deepEqual(run(["prompt", "tool", "tool"]).emits, ["working", "working", "working"]);
});

test("going idle reports done", () => {
    assert.deepEqual(run(["prompt", "idle"]).emits, ["working", "done"]);
});

test("a permission request alone does not report waiting", () => {
    // The whole point of the delay: answering in a few ms must not flash.
    const { emits, state } = run(["prompt", "permission"]);
    assert.deepEqual(emits, ["working", "working"]);
    assert.equal(state.emit, "working", "stays working while the timer runs");
});

test("a permission request that outlives the delay reports waiting", () => {
    const { emits } = run(["prompt", "permission", "timer"]);
    assert.deepEqual(emits, ["working", "working", "waiting"]);
});

test("answering before the delay prevents waiting entirely", () => {
    const { emits } = run(["prompt", "permission", "replied", "timer"]);
    assert.ok(!emits.includes("waiting"), `flashed waiting: ${emits.join(",")}`);
});

test("answering a request returns the session to working", () => {
    const { emits } = run(["prompt", "permission", "replied"]);
    assert.deepEqual(emits, ["working", "working", "working"]);
});

test("a second permission while one is open keeps both counted", () => {
    // Answering one must not retract the badge for the other.
    const { state } = run(["prompt", "permission", "permission", "replied"]);
    assert.equal(state.pending, 1, "one request still outstanding");
});

test("one outstanding permission is still worth a badge", () => {
    // Two requested, one answered: the other genuinely needs you, so waiting is
    // correct here. Retracting on the first reply would hide a real request.
    const { emits } = run(["prompt", "permission", "permission", "replied", "timer"]);
    assert.ok(emits.includes("waiting"), `hid a real request: ${emits.join(",")}`);
});

test("clearing every request drops the badge for good", () => {
    const { emits } = run(["prompt", "permission", "permission", "replied", "replied", "timer"]);
    assert.ok(!emits.includes("waiting"), `still waiting with nothing pending: ${emits.join(",")}`);
});

test("an unknown event does not cancel a wait already owed", () => {
    // OpenCode grows new events; one landing mid-permission must not silently
    // swallow the badge.
    const { emits } = run(["prompt", "permission", "some.future.event", "timer"]);
    assert.ok(emits.includes("waiting"), `a stray event cancelled the wait: ${emits.join(",")}`);
});

test("pending cannot go negative on a stray reply", () => {
    const state = reduce(INITIAL, "replied");
    assert.equal(state.pending, 0);
});

test("work resuming cancels a pending wait", () => {
    // If the agent is already running again the question no longer matters.
    const { emits } = run(["prompt", "permission", "tool", "timer"]);
    assert.ok(!emits.includes("waiting"), `waited on a moot question: ${emits.join(",")}`);
});

test("a permission after idle reports waiting again", () => {
    const { emits } = run(["prompt", "idle", "permission", "timer"]);
    assert.deepEqual(emits, ["working", "done", "working", "waiting"]);
});

test("a timer with nothing pending reports working, not waiting", () => {
    const { emits } = run(["prompt", "timer"]);
    assert.deepEqual(emits, ["working", "working"]);
});

test("a timer before any permission does not invent one", () => {
    assert.ok(!run(["timer"]).emits.includes("waiting"));
});

test("an unknown signal is ignored rather than crashing the session", () => {
    // OpenCode adds events. A new one must not take the badge down.
    const { emits } = run(["prompt", "totally.new.event", "tool"]);
    assert.deepEqual(emits, ["working", "working"]);
});

test("a null state is treated as fresh", () => {
    assert.equal(reduce(null, "prompt").emit, "working");
});

test("needsWaitTimer is true only while a wait is owed", () => {
    assert.equal(needsWaitTimer(reduce(INITIAL, "permission")), true);
    assert.equal(needsWaitTimer(reduce(INITIAL, "prompt")), false);
    assert.equal(needsWaitTimer(reduce(INITIAL, "replied")), false);
    assert.equal(needsWaitTimer(null), false);
});

test("every emitted state is one the bar knows how to draw", () => {
    // Guards against a typo here becoming a silently blank badge. The bar draws
    // only working and waiting; done is reported for the reporter's own record.
    const known = new Set(["working", "waiting", "done"]);
    const all = ["prompt", "tool", "busy", "idle", "permission", "replied", "timer"];
    for (const a of all) {
        for (const b of all) {
            for (const emit of run([a, b]).emits) {
                assert.ok(known.has(emit), `"${emit}" from ${a},${b} is not a bar state`);
            }
        }
    }
});

test("the states the reporter sends are exactly the ones agents.sh accepts", async () => {
    // The two sides are separate files in separate languages; this is the seam.
    const { execFileSync } = await import("node:child_process");
    const out = execFileSync("bash", ["scripts/agents.sh"], { encoding: "utf8" });
    for (const state of ["working", "waiting", "done"]) {
        assert.ok(out.includes(state), `agents.sh usage does not mention ${state}`);
    }
});

process.stdout.write(`\n${passed} passing, ${failed} failing\n`);
process.exit(failed > 0 ? 1 : 0);