#!/usr/bin/env bash
# Agent activity reporter for the bar's workspace badges.
#
# A terminal running a coding agent should say so on the bar: a spinner while it
# works, a pulsing "!" when it is waiting on you, a check when it is done. This
# is the write side of that -- one small JSON file per session, which the bar
# watches. It is deliberately a script rather than QML so any agent can drive it
# from a hook without knowing anything about the bar.
#
#   agents.sh working <session> [pid,pid...]   the agent is doing something
#   agents.sh waiting <session> [pid,pid...]   it needs you
#   agents.sh done    <session> [pid,pid...]   it finished a turn
#   agents.sh end     <session>                the session is over; drop the badge
#   agents.sh list                             every live session, as JSON
#   agents.sh clear                            drop every session
#
# `waiting` is a guess unless the agent says so: a hook that cannot tell the
# difference between "asked a question" and "about to be interrupted" should not
# claim it needs you. Agents that answer their own permission prompts report
# `working` throughout, which is why that is the default.
#
# A session whose processes are all gone is reaped, so an agent that dies without
# sending `end` -- a closed terminal, a crashed editor -- does not leave a badge
# stuck on the bar forever.
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/better/agents"
# A session with no `end` is dropped once it has been quiet this long. Long
# enough that a long tool call is not mistaken for a dead session, short enough
# that a stale badge is not something you have to clear by hand.
STALE_SECONDS="${BETTER_AGENTS_STALE_SECONDS:-900}"

die() { printf 'better-agents: %s\n' "$1" >&2; exit 1; }

mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"

# Strip anything that is not a safe filename component out of the session id, so
# a reporter cannot write outside the state directory.
safe_id() {
    printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64
}

alive() {
    # A session is alive while any of its pids exists. An empty pid list is
    # treated as alive so a reporter that does not know its pid is not reaped
    # out from under itself; the stale timer is what cleans those up.
    [ -z "${1:-}" ] && return 0
    local p
    local IFS=,
    for p in $1; do
        [ -n "$p" ] || continue
        [ -d "/proc/$p" ] && return 0
    done
    return 1
}

write_session() {
    local id="$1" status="$2" pids="$3" now
    now=$(date +%s)
    jq -n --arg id "$id" --arg status "$status" --arg pids "$pids" \
          --argjson since "$now" \
          '{id:$id, status:$status, pids:$pids, since:$since}' \
        > "$STATE_DIR/$id.json.tmp" && mv "$STATE_DIR/$id.json.tmp" "$STATE_DIR/$id.json"
}

reap() {
    # Drop sessions whose processes are gone, and sessions that have gone quiet
    # for longer than the stale window. Both are cheap and bounded.
    local f id pids since now age
    now=$(date +%s)
    for f in "$STATE_DIR"/*.json; do
        [ -e "$f" ] || continue
        id=$(basename "$f" .json)
        pids=$(jq -r '.pids // ""' "$f" 2>/dev/null)
        since=$(jq -r '.since // 0' "$f" 2>/dev/null || echo 0)
        age=$((now - ${since:-0}))
        if ! alive "$pids" || [ "$age" -ge "$STALE_SECONDS" ]; then
            rm -f "$f"
        fi
    done
}

cmd="${1:-list}"
case "$cmd" in
    working|waiting|done)
        [ -n "${2:-}" ] || die "usage: agents.sh $cmd <session> [pid,pid...]"
        id=$(safe_id "$2")
        [ -n "$id" ] || die "session id is empty after sanitising"
        write_session "$id" "$cmd" "${3:-}"
        ;;
    end)
        [ -n "${2:-}" ] || die "usage: agents.sh end <session>"
        rm -f "$STATE_DIR/$(safe_id "$2").json"
        ;;
    clear)
        rm -f "$STATE_DIR"/*.json
        ;;
    list)
        reap
        # An array of the live sessions, oldest first, so the bar can pick the
        # most urgent state for a workspace that has more than one agent on it.
        found=0
        printf '['
        for f in "$STATE_DIR"/*.json; do
            [ -e "$f" ] || continue
            if [ "$found" = 1 ]; then printf ','; fi
            jq -c '.' "$f" 2>/dev/null && found=1
        done
        printf ']\n'
        ;;
    *)
        die "unknown command '$cmd' (working|waiting|done|end|list|clear)"
        ;;
esac
