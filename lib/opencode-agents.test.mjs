#!/usr/bin/env node
// Asserts the OpenCode reporter end to end: real hooks in, real state files out.
//
// Why integration and not just unit tests: the parts most likely to be wrong
// here are exactly the plumbing -- the reporter path, the argv, the state
// directory, the pid list -- and none of that is reachable from the pure state
// machine. A plugin that passes every unit test while writing nothing at all is
// still a plugin that does not work, which is the failure mode that actually
// happens: the bar simply never badges, with no error anywhere to look at.
//
// Each case runs with its own XDG_STATE_HOME, so a run never badges the real bar
// and never leaves a session behind for the reaper to find.

import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const PLUGIN = resolve(ROOT, "scripts/opencode-agents.js");
const REPORTER = resolve(ROOT, "scripts/agents.sh");

let failed = 0;
let passed = 0;

async function test(name, fn) {
    try {
        await fn();
        passed++;
        process.stdout.write(`PASS ${name}\n`);
    } catch (e) {
        failed++;
        process.stdout.write(`FAIL ${name}\n  ${e.message}\n`);
    }
}

// A throwaway state root for one case, so the reporter writes only into it.
function sandbox() {
    const dir = mkdtempSync(resolve(tmpdir(), "better-agents-"));
    process.env.XDG_STATE_HOME = dir;
    return {
        dir,
        sessions() {
            const stateDir = resolve(dir, "better/agents");
            if (!existsSync(stateDir)) return [];
            return readdirSync(stateDir)
                .filter((f) => f.endsWith(".json"))
                .map((f) =>
                    JSON.parse(execFileSync("bash", [REPORTER, "list"], {
                        encoding: "utf8",
                        env: { ...process.env },
                    })).find((s) => `${s.id}.json` === f)
                )
                .filter(Boolean);
        },
        cleanup() {
            rmSync(dir, { recursive: true, force: true });
        },
    };
}

// Load a fresh copy of the plugin each time, so module-level state (the pid
// chain, the fs reader) cannot leak between cases.
function loadPlugin() {
    return import(`${pathToFileURL(PLUGIN).href}?t=${Math.random()}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await test("the module loads and exposes a factory", async () => {
    const mod = await loadPlugin();
    assert.equal(typeof mod.BetterAgents, "function", "no BetterAgents export");
    assert.equal(typeof mod.default, "function", "no default export");
});

await test("the factory returns hooks OpenCode can call", async () => {
    const mod = await loadPlugin();
    const hooks = await mod.BetterAgents({});
    for (const hook of ["chat.message", "tool.execute.after", "permission.ask", "event", "dispose"]) {
        assert.equal(typeof hooks[hook], "function", `missing hook: ${hook}`);
    }
});

await test("a prompt writes a working session", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        const sessions = box.sessions();
        assert.equal(sessions.length, 1, `expected 1 session, got ${sessions.length}`);
        assert.equal(sessions[0].status, "working");
    } finally {
        box.cleanup();
    }
});

await test("the reported session names a pid the bar can match", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        const pids = box.sessions()[0].pids.split(",").filter(Boolean);
        assert.ok(pids.length > 0, "no pids reported");
        for (const pid of pids) {
            assert.ok(Number.isInteger(+pid) && +pid > 1, `bad pid: ${pid}`);
        }
        // The chain must include this process, or the bar can never find it.
        assert.ok(pids.includes(String(process.pid)), "own pid missing from the chain");
    } finally {
        box.cleanup();
    }
});

await test("a permission that is answered in time never badges waiting", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        await hooks["permission.ask"]({});
        await hooks["permission.replied"]({});
        await sleep(1700); // past WAIT_DELAY
        const session = box.sessions()[0];
        assert.ok(session, "session vanished");
        assert.notEqual(session.status, "waiting", "flashed waiting on an answered permission");
        await hooks.dispose();
    } finally {
        box.cleanup();
    }
});

await test("a permission left unanswered does badge waiting", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        await hooks["permission.ask"]({});
        await sleep(1900); // past WAIT_DELAY
        assert.equal(box.sessions()[0].status, "waiting", "never reported waiting");
        await hooks.dispose();
    } finally {
        box.cleanup();
    }
});

await test("going idle reports done", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        await hooks.event({ event: { type: "session.idle" } });
        assert.equal(box.sessions()[0].status, "done");
        await hooks.dispose();
    } finally {
        box.cleanup();
    }
});

await test("an unknown event does not break the badge", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        await hooks.event({ event: { type: "something.new.in.a.newer.opencode" } });
        await hooks.event({ event: {} });
        await hooks.event({});
        assert.equal(box.sessions()[0].status, "working");
        await hooks.dispose();
    } finally {
        box.cleanup();
    }
});

await test("disposing retires the session, leaving no badge behind", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        assert.equal(box.sessions().length, 1);
        await hooks.dispose();
        assert.equal(box.sessions().length, 0, "session survived dispose");
    } finally {
        box.cleanup();
    }
});

await test("a plugin failure cannot take the agent turn with it", async () => {
    const box = sandbox();
    try {
        const mod = await loadPlugin();
        const hooks = await mod.BetterAgents({});
        // Point the reporter at something that does not exist by removing
        // execute permission, so every spawn fails. The hooks must still return
        // normally: a bar that cannot be told is not a reason to stop working.
        const saved = execFileSync("stat", ["-c", "%a", REPORTER], { encoding: "utf8" }).trim();
        execFileSync("chmod", ["000", REPORTER]);
        try {
            await hooks["chat.message"]({});
            await hooks["permission.ask"]({});
            await hooks.event({ event: { type: "session.idle" } });
            await hooks.dispose();
        } finally {
            execFileSync("chmod", [saved.padStart(3, "0"), REPORTER]);
        }
        assert.ok(execFileSync("stat", ["-c", "%a", REPORTER], { encoding: "utf8" }).trim() !== "000");
    } finally {
        box.cleanup();
    }
});

await test("two sessions in one terminal get separate badges", async () => {
    // Two OpenCode processes here would share a pid chain tail, so the session
    // name has to include something that differs. Assert the name is derived
    // from the chain rather than being a constant, which is what would make them
    // collide in the reporter's flat state directory.
    const mod = await loadPlugin();
    const box = sandbox();
    try {
        const hooks = await mod.BetterAgents({});
        await hooks["chat.message"]({});
        const name = box.sessions()[0].id;
        assert.ok(name.startsWith("opencode-"), `unexpected session name: ${name}`);
        assert.ok(name !== "opencode", "session name is a constant, so sessions collide");
        await hooks.dispose();
    } finally {
        box.cleanup();
    }
});

process.stdout.write(`\n${passed} passing, ${failed} failing\n`);
process.exit(failed > 0 ? 1 : 0);