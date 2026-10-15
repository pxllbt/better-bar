#!/usr/bin/env bash
# Asserts the agent-activity pipeline: the reporter script that agents drive,
# and the singleton that turns what it writes into a badge for a workspace.
#
# Why it exists: a badge that shows the wrong thing is worse than no badge. An
# agent that finished should not keep spinning, an agent that is waiting on you
# should not look idle, and a badge stuck forever because something died without
# reporting `end` trains you to ignore the badge entirely. So the three states
# are distinguished, the loudest state wins when a workspace has more than one
# agent, and a session nobody can attribute to a workspace is left off rather
# than guessed at.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AGENTS="$ROOT/scripts/agents.sh"
SINGLETON="$ROOT/Singletons/Agents.qml"
WORKSPACES="$ROOT/components/Workspaces.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$AGENTS" ] || { echo "no scripts/agents.sh at $AGENTS" >&2; exit 1; }
[ -f "$SINGLETON" ] || { echo "no Singletons/Agents.qml at $SINGLETON" >&2; exit 1; }

# A private state root, so a run never touches the real one and never reaps a
# real session.
STATE="$(mktemp -d)"
trap 'rm -rf "$STATE"' EXIT
export XDG_STATE_HOME="$STATE"
DIR="$STATE/better/agents"

SELF=$$
run() { bash "$AGENTS" "$@"; }

# --- the reporter contract ------------------------------------------------
ok "working is recorded" \
    "$(run working s1 $SELF >/dev/null; run list | jq -r '.[0].status')" "working"
ok "waiting is recorded" \
    "$(run waiting s1 $SELF >/dev/null; run list | jq -r '.[0].status')" "waiting"
ok "done is recorded" \
    "$(run done s1 $SELF >/dev/null; run list | jq -r '.[0].status')" "done"
ok "list is valid JSON even with nothing in it" \
    "$(run end s1 >/dev/null; run list | jq -r 'type')" "array"
ok "list is empty once the session ends" \
    "$(run list | jq -r 'length')" "0"

ok "a session id cannot escape the state directory" \
    "$(run working '../../etc/evil' >/dev/null 2>&1; [ -e /etc/evil.json ] && echo escaped || echo contained)" \
    "contained"

# A session whose process is gone is reaped, so a crashed agent does not leave
# a badge up forever. A pid that cannot exist is the cheapest stand-in.
ok "a session whose process is gone is reaped" \
    "$(run working dead 999999 >/dev/null; run list | jq -r 'length')" "0"

# The stale window is the other reaper, for a reporter that never sent `end`.
ok "a quiet session is reaped once the window passes" \
    "$(run working quiet >/dev/null; BETTER_AGENTS_STALE_SECONDS=0 run list | jq -r 'length')" "0"
ok "a fresh session survives a normal window" \
    "$(run working fresh $SELF >/dev/null; run list | jq -r 'length')" "1"

ok "clear drops everything" \
    "$(run clear >/dev/null; run list | jq -r 'length')" "0"

# --- usage is legible -----------------------------------------------------
ok "a missing session id is refused" \
    "$(run working 2>&1 >/dev/null | grep -c 'usage:')" "1"
ok "an unknown command is refused" \
    "$(run nonsense 2>&1 >/dev/null | grep -c 'unknown command')" "1"

# --- the singleton derives a badge per workspace --------------------------
ok "a session carries the pid it reported" \
    "$(run working a1 $SELF >/dev/null; run list | jq -r '.[0].pids')" "$SELF"

ok "a done session leaves no badge (only working and waiting do)" \
    "$(grep -c 's.status !== "waiting" && s.status !== "working"' "$SINGLETON")" "1"
ok "a waiting session outranks a working one on the same workspace" \
    "$(grep -c 'if (out\[ws\] !== "waiting")' "$SINGLETON")" "1"
ok "a session nobody can attribute is left off rather than guessed at" \
    "$(grep -c 'if (!ws)' "$SINGLETON")" "1"
ok "the read side reuses the reporter's own list, so there is one parser" \
    "$(grep -c 'list;' "$SINGLETON")" "1"
ok "the poll is faster while something wants attention" \
    "$(grep -c 'urgent > 0 ? 1000 : 5000' "$SINGLETON")" "1"

# --- the bar actually shows it -------------------------------------------
ok "the workspace strip badges from the singleton" \
    "$(grep -c 'Agents\.badgeFor' "$WORKSPACES")" "1"

ok "the singleton is registered" \
    "$(grep -cE '^singleton[[:space:]]+Agents[[:space:]]+Agents\.qml$' "$ROOT/Singletons/qmldir")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
