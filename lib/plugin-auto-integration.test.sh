#!/usr/bin/env bash
# Asserts the plugin auto-integration path is really there.
#
# The plugin strip already hosts a newly enabled bar-widget, but same work as
# Better Recast needs the self-tending half too: a plugin installed while the
# bar is running should be noticed and enabled, an enabled failure should retry
# itself, and an unattended update should be opt-in rather than impossible.
#
# This is a static contract test: it checks the runtime wiring exists, but it
# does not install a plugin.
set -uo pipefail

ROOT=${1:-}
if [ -z "$ROOT" ]; then
    ROOT=$(cd "$(dirname "$0")/.." && pwd)
fi
FLAGS="$ROOT/Singletons/Flags.qml"
PLUGINS="$ROOT/Singletons/Plugins.qml"
SURFACE="$ROOT/surfaces/PluginsSurface.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$FLAGS" ] || { echo "no $FLAGS" >&2; exit 1; }
[ -f "$PLUGINS" ] || { echo "no $PLUGINS" >&2; exit 1; }
[ -f "$SURFACE" ] || { echo "no $SURFACE" >&2; exit 1; }

# --- persisted flags --------------------------------------------------------
ok "auto-adopt is persisted" \
    "$(grep -c 'property alias pluginAutoIntegrate' "$FLAGS")" "1"
ok "auto-check is persisted" \
    "$(grep -c 'property alias pluginAutoCheck' "$FLAGS")" "1"
ok "auto-update is persisted" \
    "$(grep -c 'property alias pluginAutoUpdate' "$FLAGS")" "1"
ok "self-heal is persisted" \
    "$(grep -c 'property alias pluginSelfHeal' "$FLAGS")" "1"

# Auto-update is deliberately opt-in. If this flips to true, a plugin with a
# broken remote or a surprise API change can rewrite itself before the user
# has seen the changelog, so the default asserting "off" is load-bearing.
ok "auto-update defaults off" \
    "$(grep -c 'property bool pluginAutoUpdate: false' "$FLAGS")" "1"

# --- adoption transition ----------------------------------------------------
ok "the first-sight set is persisted" \
    "$(grep -c 'function markSeen' "$PLUGINS")" "1"
ok "forgetting an uninstalled plugin is honest" \
    "$(grep -c 'function forgetSeen' "$PLUGINS")" "1"
ok "a new plugin is enabled from the registry read" \
    "$(grep -c 'function integrateFresh' "$PLUGINS")" "1"
ok "the list read reconciles new plugins" \
    "$(grep -c 'root.reconcileSeen()' "$PLUGINS")" "3"

# The first run must not enable everything the user previously left off, so
# the empty-seen-set branch is gated on there being something in the file.
ok "a first run marks without enabling" \
    "$(grep -c 'var firstRun = root.seenPluginIds.length === 0;' "$PLUGINS")" "1"

# --- self-heal --------------------------------------------------------------
ok "broken and missing together arm the heal timer" \
    "$(grep -c 'root.brokenPlugins.length > 0 || root.missingPlugins.length > 0' "$PLUGINS")" "1"
ok "the heal timer repeats only while healing is needed" \
    "$(grep -c 'running: root.healingNeeded && !root.busy' "$PLUGINS")" "1"
ok "auto-update only fires with both the check and the update enabled" \
    "$(grep -c 'if (Flags.pluginAutoCheck && Flags.pluginAutoUpdate' "$PLUGINS")" "1"

# --- settings surface -------------------------------------------------------
ok "auto-adopt has a settings row" \
    "$(grep -c 'id: autoAdoptRow' "$SURFACE")" "1"
ok "self-heal has a settings row" \
    "$(grep -c 'id: selfHealRow' "$SURFACE")" "1"
ok "auto-update has a settings row" \
    "$(grep -c 'id: autoUpdateRow' "$SURFACE")" "1"
ok "repair now is wired to healAll" \
    "$(grep -c 'activate: Plugins.healAll' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
