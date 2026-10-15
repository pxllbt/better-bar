#!/usr/bin/env bash
# Asserts Better Bar's plugin-host facade degrades safely for a service-only
# plugin bar widget.
#
# Why this exists: OmaSpotify's BarWidget reads its service with
# `bar.shell.serviceFor(...)`. Better Bar is a replacement bar, not the plugin
# host process, so that lookup cannot return the host's service object. When the
# member was missing entirely the widget threw at load and left a broken chip in
# the strip; now the stub answers null and the widget's own guard keeps it
# icon-only until the host owns the panel.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STUB="$ROOT/components/PluginBarStub.qml"
PLUGINS="$ROOT/Singletons/Plugins.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$STUB" ] || { echo "no PluginBarStub.qml at $STUB" >&2; exit 1; }
[ -f "$PLUGINS" ] || { echo "no Plugins.qml at $PLUGINS" >&2; exit 1; }

ok "the bar stub answers serviceFor instead of throwing" \
    "$(grep -c 'function serviceFor()' "$STUB")" "1"

ok "serviceFor returns null for a bar that owns no plugin services" \
    "$(grep -A3 'function serviceFor()' "$STUB" | grep -c 'return null;')" "1"

ok "the stub can hide a host plugin surface" \
    "$(grep -c 'function hide(target)' "$STUB")" "1"

ok "the stub can toggle a host plugin surface" \
    "$(grep -c 'function toggle(target, payload)' "$STUB")" "1"

ok "the stub answers plugin-open queries without pretending to host them" \
    "$(grep -A2 'function isPluginOpen()' "$STUB" | grep -c 'return false;')" "1"

ok "Spotify resolves the music glyph" \
    "$(grep -c 'music|media|player|spotify' "$PLUGINS")" "1"

ok "a plugin with no better.render override stays glyph-rendered" \
    "$(grep -c 'return meta && String(meta.render || "")' "$PLUGINS")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
