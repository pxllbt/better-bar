/**
 * The state machine behind Better Bar's agent badge, as seen by OpenCode.
 *
 * Kept pure and separate from the plugin so it can be unit tested without
 * OpenCode, and so the rules that decide what the bar shows are written down in
 * one place instead of being implied by a pile of event handlers.
 *
 * Three states reach the bar:
 *
 *   working  the agent is running
 *   waiting  it needs an answer
 *   done     it finished its turn
 *
 * and `end` retires the session entirely. `done` is deliberately not a resting
 * state: the bar shows nothing for it, because a check mark that never clears is
 * a check mark you stop seeing.
 *
 * The one subtlety is `waiting`. A permission request that is answered in
 * milliseconds -- which is most of them, when the agent runs with --auto -- would
 * otherwise flash a pulsing "!" at you for a frame. So `waiting` is not emitted
 * on the request itself; it is emitted only if the request is still outstanding
 * after WAIT_DELAY. That is the difference between a badge that means something
 * and one that flickers.
 */

/** How long a permission request must stay unanswered before it counts. */
export const WAIT_DELAY = 1500;

/** The state a fresh session starts in. */
export const INITIAL = { emit: null, pending: 0 };

/** True when this state still owes the bar a `waiting` timer. */
export function needsWaitTimer(state) {
    return !!state && !!state.timer;
}

/**
 * Fold one signal into a session's state.
 *
 * `signal` is one of:
 *
 *   prompt      the user submitted a message
 *   tool        a tool finished running
 *   busy        the session reported a non-idle status
 *   idle        the session went idle
 *   permission  a permission request went out
 *   replied     a permission request was answered
 *   timer       the wait delay elapsed with the request still open
 *
 * Returns a new state; `emit` is the state to report (or null to stay quiet) and
 * `timer` says whether a `timer` signal is still owed.
 */
export function reduce(state, signal) {
    const prev = state || INITIAL;

    switch (signal) {
        // Anything that means the agent is doing something settles a pending
        // permission too: if it is already running again, the prompt is moot.
        case "prompt":
        case "tool":
        case "busy":
            return { emit: "working", timer: false, pending: 0 };

        case "permission":
            return { emit: "working", timer: true, pending: (prev.pending || 0) + 1 };

        case "replied": {
            const pending = Math.max(0, (prev.pending || 0) - 1);
            if (pending > 0)
                return { emit: null, timer: true, pending };
            return { emit: "working", timer: false, pending: 0 };
        }

        // Only an unanswered request that outlived the delay becomes "waiting".
        case "timer":
            if ((prev.pending || 0) > 0)
                return { emit: "waiting", timer: false, pending: prev.pending };
            return { emit: "working", timer: false, pending: 0 };

        case "idle":
            return { emit: "done", timer: false, pending: 0 };

        // OpenCode adds events over time, so an unrecognised one has to be a
        // no-op rather than a crash. Two things must still hold: a wait that is
        // already owed stays owed (a stray event must not cancel a badge the
        // agent genuinely needs), and nothing is re-reported -- `emit` means
        // "tell the bar now", so handing back the previous state verbatim would
        // make every new event push a duplicate report.
        default:
            return { emit: null, timer: needsWaitTimer(prev), pending: prev.pending || 0 };
    }
}
