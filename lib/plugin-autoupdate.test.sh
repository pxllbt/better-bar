#!/usr/bin/env bash
# Asserts the plugin update *check*, bulk update, and self-heal at the bar level.
#
# Why it exists: the bar could update a plugin on request but could not know one
# was out of date, and updating all of them left the new code sitting on disk
# unloaded — which looks exactly like an update that failed. Both are the "auto"
# half of the ask: the bar noticing on your behalf, instead of you noticing.
#
# The self-heal is the part worth guarding hardest. Restarting someone's shell
# unasked is disruptive, so it must fire only when something genuinely changed,
# and never merely because someone opened the Plugins surface. A bug there is
# not a cosmetic one — it would kill their session.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SINGLETON="$ROOT/Singletons/Plugins.qml"
CHECKSCRIPT="$ROOT/scripts/plugin-updates.sh"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SINGLETON" ] || { echo "no Singletons/Plugins.qml" >&2; exit 1; }
[ -f "$CHECKSCRIPT" ] || { echo "no scripts/plugin-updates.sh" >&2; exit 1; }

# --- the check is wired to the script that does the work -----------------
ok "the check runs the read-only update-check script" \
    "$(grep -c 'plugin-updates.sh' "$SINGLETON")" "1"
ok "the script is resolved through the config, not hardcoded" \
    "$(grep -c 'hyprPath("scripts", "plugin-updates.sh")\|"scripts", "plugin-updates.sh"' "$SINGLETON")" "1"

# --- the answers are exposed where the UI can see them -------------------
ok "pending updates are exposed as a list" \
    "$(grep -c 'property var pendingUpdates' "$SINGLETON")" "1"
ok "a count is exposed alongside the list" \
    "$(grep -c 'property int updateCount' "$SINGLETON")" "1"
ok "a check in flight is distinguishable from no check" \
    "$(grep -c 'property bool checkingUpdates' "$SINGLETON")" "1"

# The report's `behind` is tri-state: true, false, and null for "could not ask",
# which is not the same as "up to date". Only a definite true counts as an
# update available; treating null as current is how a broken network becomes a
# clean bill of health.
ok "only a definitely-behind plugin counts as pending" \
    "$(grep -c '\.behind === true' "$SINGLETON")" "1"
ok "an unknown plugin is never counted as pending" \
    "$(grep -c 'behind === true' "$SINGLETON")" "1"

# --- bulk update ---------------------------------------------------------
# The CLI already treats no-id as "all git-managed", so the bar must not be the
# thing that invents its own loop over plugins — that would race the CLI's own
# rescan and rollback.
ok "bulk update passes no id, so the CLI updates everything" \
    "$(grep -c 'function updateAll' "$SINGLETON")" "1"
ok "updateAll delegates to the existing update verb rather than reimplementing it" \
    "$(grep -A3 'function updateAll' "$SINGLETON" | grep -c 'update(')" "1"
# `--yes` has to actually reach the CLI. It is not in updateAll's body, and
# asserting there would be asserting the wrong function: update() builds the
# argv, so that is where the flag belongs.
ok "the CLI is passed --yes, so it cannot stall waiting to ask" \
    "$(grep -A2 'function update(id)' "$SINGLETON" | grep -c 'yes')" "1"
ok "the argv is built once, in one place, rather than per call site" \
    "$(grep -c 'omarchy-plugin-" + verb' "$SINGLETON")" "1"

# --- self-heal, and only when something changed -------------------------
# An update that leaves new code on disk without restarting the shell is
# indistinguishable, from the outside, from an update that failed. So restart,
# but only on a definite change.
ok "the singleton knows when the shell needs restarting" \
    "$(grep -c 'property bool needsShellRestart' "$SINGLETON")" "1"
ok "a change is detected from the CLI's own output, not assumed" \
    "$(grep -c 'indexOf("Updated ")' "$SINGLETON")" "1"
ok "the restart is a request the surface can act on, never fired by the singleton" \
    "$(grep -c 'needsShellRestart = true' "$SINGLETON")" "0"
ok "the restart is offered to the user rather than performed for them" \
    "$(grep -c 'function restartShell' "$SINGLETON")" "1"
ok "the restart shells out to omarchy's own restart" \
    "$(grep -c 'omarchy-restart-shell' "$SINGLETON")" "1"
ok "the restart clears its own request once acted on" \
    "$(grep -A2 'function restartShell' "$SINGLETON" | grep -c 'needsShellRestart = false')" "1"

# --- the surface shows it ------------------------------------------------
SURFACE="$ROOT/surfaces/PluginsSurface.qml"
ok "the surface offers a bulk update" \
    "$(grep -c 'updateAll()' "$SURFACE")" "1"
ok "the surface surfaces the pending count from the singleton, not a local copy" \
    "$(grep -c 'Plugins.updateCount' "$SURFACE")" "4"
ok "the count drives three distinct renderings, so each state is legible" \
    "$(grep -c 'Plugins.updateCount > 0' "$SURFACE")" "3"
ok "the surface offers the restart when one is owed" \
    "$(grep -c 'needsShellRestart' "$SURFACE")" "2"
# Two, and deliberately so: the row offers a manual check, and opening the
# surface fires one because coming here is usually about a plugin that is not
# working — and "an update is waiting" is the cheapest possible answer.
ok "the surface can trigger the check" \
    "$(grep -c 'checkForUpdates' "$SURFACE")" "2"
ok "opening the surface checks, because that is when you want to know" \
    "$(grep -A10 'onOpenChanged' "$SURFACE" | grep -c 'checkForUpdates')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'