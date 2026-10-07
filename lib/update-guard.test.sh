#!/usr/bin/env bash
# Asserts that the in-bar updater cannot silently discard work.
#
# The bug this exists for: the Update surface ran `git reset --hard
# refs/remotes/origin/master` against the install with no prior check. That is
# the only way to survive a force-push or a diverged history, and it is the
# right command for a managed deployment. It also deletes every local commit
# and every uncommitted change in the checkout, with no prompt, from a row
# whose whole purpose is to be pressed without reading.
#
# Ten files in the checkout this was written for carried git's skip-worktree
# bit, so `git status` reported the tree as almost clean and ~580 lines of work
# were invisible to everything in the bar. The lesson for the assertions below:
# the guard has to read the git index from a subprocess, not from anything the
# shell has cached.
#
# Each check is a grep over the surface source. These assert wiring is present;
# they do not run a reset against a real repo, because a test that can delete
# a worktree is not a test anybody runs twice.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
SURFACE="$ROOT/surfaces/UpdateSurface.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SURFACE" ] || { echo "no UpdateSurface.qml at $SURFACE" >&2; exit 1; }

# The reset itself stays: force-pushes and replaced histories are real and a
# plain `git pull` fatals on them. What must exist is a check in front of it.
ok "the reset is still hard, because pull cannot survive a force-push" \
    "$(grep -cE 'reset", "--hard"' "$SURFACE")" "1"

# --- the two kinds of work an update destroys ------------------------------
# Uncommitted changes and local commits are discarded by different commands and
# are not interchangeable. One flag covering both would leave a case uncovered.
ok "a worktree-dirty flag exists" \
    "$(grep -cE 'property bool localDirty' "$SURFACE")" "1"
ok "a local-commits flag exists" \
    "$(grep -cE 'property bool localCommits' "$SURFACE")" "1"
ok "both are combined into one risky flag" \
    "$(grep -cE 'readonly property bool updateRisky: localCommits \|\| localDirty' "$SURFACE")" "1"

# --- the probes ------------------------------------------------------------
# Each risk needs its own subprocess: status --porcelain for uncommitted work
# (which counts untracked files too), rev-list --count for local commits.
ok "porcelain status is probed" \
    "$(grep -cE '"status", "--porcelain"' "$SURFACE")" "1"
ok "skip-worktree and assume-unchanged files are probed" \
    "$(grep -cE '"ls-files", "-v"' "$SURFACE")" "1"
# QProcess.onExited carries (exitCode, exitStatus), not stdout.
ok "git output is not read from onExited's second argument" \
    "$(grep -cE 'function \(exitCode, standardOutput\)' "$SURFACE")" "0"
ok "both reverse commit counts use StdioCollector" \
    "$(grep -cE 'onStreamFinished: root\.(applyLocalCommits|applyPending)' "$SURFACE")" "2"
# Two counts, opposite directions: how far behind master this checkout is
# (update-probe..HEAD is the local-commits direction, HEAD..update-probe the
# pending-commits one). Both must exist or one of the two questions is unasked.
ok "rev-list --count is used for both directions" \
    "$(grep -cE '"rev-list", "--count"' "$SURFACE")" "2"
ok "local commits are counted as commits ahead of the fetched ref" \
    "$(grep -cE '"rev-list", "--count", "refs/remotes/origin/update-probe\.\.HEAD"' "$SURFACE")" "1"

# The count needs a current ref. Probing before the fetch would compare against
# a ref that only moves on fetch, so 0 would mean "not looked at yet".
# The probe must refresh the very ref it then counts against. Counting against
# a ref nothing moved would make 0 mean "not looked at yet" rather than "clean".
ok "the commit count is taken against the ref the probe refreshes" \
    "$(grep -cE '"fetch", "--quiet", "origin", "\+master:refs/remotes/origin/update-probe"' "$SURFACE")" "2"
ok "the probe's count runs after its fetch, not in parallel" \
    "$(grep -cE 'headRefProbeProc.running = true' "$SURFACE")" "1"

ok "a singleton updater polls and notifies once per remote head" \
    "$(grep -cE 'singleton Updater Updater\.qml' "$ROOT/Singletons/qmldir")" "1"
ok "the notification helper exists" \
    "$(grep -cE 'function notify\(summary, body, actions, timeout\)' "$ROOT/Singletons/Notifs.qml")" "1"
ok "the update surface sub honors updater count" \
    "$(grep -cE 'Updater\.pending > 0' "$ROOT/surfaces/Appearance.qml")" "1"

# --- the confirmation ------------------------------------------------------
ok "the confirmation row exists" \
    "$(grep -cE 'id: confirmRow' "$SURFACE")" "1"
ok "the confirmation is visible only when work was found" \
    "$(grep -cE 'visible: root.updateRisky' "$SURFACE")" "1"

# Two labels, not one. A single generic prompt would hide which of the two
# distinct losses is being agreed to.
ok "the confirmation names uncommitted changes" \
    "$(grep -cE 'Discard changes and update' "$SURFACE")" "1"
ok "the confirmation names local commits" \
    "$(grep -cE 'Discard local commits and update' "$SURFACE")" "1"

# --- it has to actually be reachable ---------------------------------------
# A guard that nothing calls is decoration. doUpdate must reach the probe, and
# the probe's answer must decide between updating and asking.
ok "doUpdate probes before fetching" \
    "$(grep -cE 'function doUpdate' "$SURFACE")" "1"
ok "the probe runs instead of the fetch on the first tap" \
    "$(grep -cE 'dirtProbeProc.running = true' "$SURFACE")" "1"
ok "a clean checkout goes straight to the update" \
    "$(grep -cE 'root.runUpdate\(\)' "$SURFACE")" "2"
ok "runUpdate is the path that actually fetches" \
    "$(grep -cE 'function runUpdate' "$SURFACE")" "1"

# The confirm row must be in the navigable list, or it renders but can never be
# reached by keyboard or click.
ok "the confirmation is registered as a navigable row" \
    "$(grep -cE 'item: confirmRow' "$SURFACE")" "1"

[ "$failed" -eq 0 ] && printf '\nall green\n' || printf '\n%s failing\n' "$failed"
exit $((failed > 0))