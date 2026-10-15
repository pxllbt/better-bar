// Agent badge reporter for Better Bar.
//
// Tells the bar what this OpenCode session is doing, so a terminal running an
// agent gets a badge on its workspace: breathing while it works, a pulsing "!"
// when it needs an answer.
//
// Reports go out through scripts/agents.sh, the same script any other agent
// drives from a hook, so the bar needs no OpenCode-specific code at all -- and
// so adding Claude Code or anything else later is a second file rather than a
// second code path.
//
//   working  the agent is running
//   waiting  it needs an answer
//   done     the turn finished
//   end      the session is gone
//
// The session is named after the process tree rather than OpenCode's own id.
// The bar resolves a badge by asking Hyprland which workspace a pid is on, and
// a pid that walks up to the terminal is what makes that lookup work; an
// OpenCode session id tells the bar nothing it can match on.
//
// Install by symlinking, so `git pull` or a plugin update keeps it current:
//
//   ln -sfn <better-bar>/scripts/opencode-agents.js ~/.config/opencode/plugins/better-agents.js
//
// The rules that decide what the bar shows live in ../lib/agents-state.mjs,
// which is pure and unit tested; this file is only the plumbing.
//
// Reference for the plugin API: the spaces plugin that does the same job for
// omarchy-spaces, https://github.com/tornikegomareli/omarchy-spaces

import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { dirname, resolve } from "node:path"
import { WAIT_DELAY, INITIAL, needsWaitTimer, reduce } from "../lib/agents-state.mjs"

// The reporter, resolved relative to this file rather than to the symlink in
// ~/.config/opencode/plugins, so it follows the checkout it lives in.
const HERE = dirname(fileURLToPath(import.meta.url))
const REPORTER = resolve(HERE, "agents.sh")

// ---------------------------------------------------------------------------
// Process tree
// ---------------------------------------------------------------------------

// The bar badges a workspace by matching pids against Hyprland's client list,
// and that list only knows about the terminal. So collect this process and every
// ancestor up to pid 1: whichever of them is the terminal is the one that
// identifies the workspace. Reporting only our own pid would attribute a badge
// to whatever workspace the process happens to sit in, which is nothing.
//
// Deliberately a best-effort scan rather than an error: a pid we cannot read
// just does not appear in the list.
function processChain() {
    const pids = []
    let pid = process.pid
    // Bounded so a pid cycle cannot spin here.
    for (let hop = 0; hop < 32 && pid > 1; hop++) {
        pids.push(pid)
        let parent = 0
        try {
            // /proc/<pid>/stat is "pid (comm) state ppid ...". comm is
            // parenthesised and may itself contain spaces and parentheses, so
            // read from the last ')' rather than splitting the whole line --
            // an agent named `my (weird) agent` would otherwise shift every
            // field and report a nonsense parent.
            const stat = readFile(`/proc/${pid}/stat`, "utf8")
            const tail = stat.slice(stat.lastIndexOf(")") + 2).split(" ")
            parent = parseInt(tail[1], 10) || 0
        } catch {
            break
        }
        if (parent <= 0 || pids.includes(parent)) break
        pid = parent
    }
    return pids
}

let readFile = null
async function ensureReader() {
    if (readFile) return readFile
    ({ readFileSync: readFile } = await import("node:fs"))
    return readFile
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

// Fire and forget. The bar must never be able to slow down, wedge, or fail an
// agent turn: a reporter that throws inside a hook would take the session with
// it. So every call is sync, detached, and swallows everything.
function report(state, session, pids) {
    try {
        spawnSync(REPORTER, [state, session, pids.join(",")], {
            stdio: "ignore",
            timeout: 2000,
        })
    } catch {
        // A bar that cannot be told is not a reason to stop working.
    }
}

/**
 * The reporter OpenCode loads. Returns an object whose keys become hooks.
 *
 * @param {{ project?: unknown, directory?: string, client?: unknown, $?: unknown }} input
 */
export const BetterAgents = async ({ directory } = {}) => {
    await ensureReader()

    const pids = processChain()
    // Name the session after its own top-level pid so two sessions in one
    // terminal do not fight over one badge, and so the name is stable for the
    // life of the session.
    const session = `opencode-${pids[pids.length - 1] || process.pid}`

    let state = INITIAL
    let timer = null

    const settle = (signal) => {
        state = reduce(state, signal)
        if (!state.emit) return
        report(state.emit, session, pids)

        // Re-arm the wait delay only while one is genuinely owed. This is what
        // keeps an instantly-approved permission from flashing "!" at you.
        if (needsWaitTimer(state)) {
            if (!timer) {
                timer = setTimeout(() => settle("timer"), WAIT_DELAY)
                // Never hold the process open for a badge.
                if (typeof timer.unref === "function") timer.unref()
            }
        } else if (timer) {
            clearTimeout(timer)
            timer = null
        }
    }

    return {
        // A user prompt means work started.
        "chat.message": async () => settle("prompt"),

        // A finished tool means work is still going on. Without this the badge
        // would sit at `working` from the prompt and never be told anything
        // else, so this also carries any newly raised permission.
        "tool.execute.after": async () => settle("tool"),

        // The explicit signal: the agent is blocked on a human decision. It does
        // not become `waiting` until WAIT_DELAY, because most permissions here
        // are auto-approved and a badge that flickers is a badge ignored.
        "permission.ask": async () => settle("permission"),
        "permission.replied": async () => settle("replied"),

        // Lifecycle events, if this OpenCode build emits them. Unknown shapes
        // are absorbed by `reduce`, so a version bump cannot break the badge.
        event: async ({ event }) => {
            const type = (event && event.type) || ""
            if (type === "session.status" || type === "session.busy") settle("busy")
            else if (type === "session.idle") settle("idle")
        },

        dispose: async () => {
            if (timer) clearTimeout(timer)
            timer = null
            report("end", session, pids)
        },
    }
}

export default BetterAgents