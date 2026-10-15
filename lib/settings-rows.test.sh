#!/usr/bin/env bash
# Asserts no settings row is given a property it does not have.
#
# Why it exists, in one sentence: a `SettingsRow` was assigned `onClicked`, it
# does not have one, and the entire shell failed to load -- the bar vanished from
# the screen and stayed gone until it was fixed by hand.
#
# The failure mode is what makes this worth a test rather than a rule. A row is
# activated through the surface's row dispatcher, which reads the `rows:` array
# and calls `activate()` on the matching descriptor. Writing `onClicked:` on the
# row looks equivalent, is what a QML author would reach for first, and is not
# merely inert -- an unknown property on a typed object is a load-time error, so
# one bad row takes down every surface the shell builds, not just the page it
# sits on. Nothing about the page hints at the problem, and the error names a
# file and line rather than a cause.
#
# So: no SettingsRow block may contain a click handler, because clicks are
# dispatched centrally. This is checked structurally rather than by loading the
# shell, so it runs everywhere without a Wayland session.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACES="$ROOT/surfaces"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -d "$SURFACES" ] || { echo "no surfaces/ at $SURFACES" >&2; exit 1; }

# Walk every SettingsRow block and look for a click handler inside it. A block is
# the `SettingsRow {` line up to its matching close, tracked by brace depth so a
# nested element cannot end the block early.
offenders=""
for f in "$SURFACES"/*.qml; do
    [ -f "$f" ] || continue
    # Only the row's OWN properties, which are at brace depth 1 inside the block.
    # A click handler on a nested MouseArea is a different thing entirely -- that
    # is a real MouseArea with a real signal, and rows legitimately contain them
    # (the plugin list's per-row refresh, clone and remove buttons). Matching
    # anywhere in the block flags all of those and drowns the real signal, so the
    # depth is tracked and only depth 1 is reported.
    hits=$(awk '
        /SettingsRow[[:space:]]*\{/ { inblock = 1; depth = 1; next }
        inblock {
            n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m;
            if (depth <= 0) { inblock = 0; next }
            if (depth == 1 && $0 ~ /^[[:space:]]*(onClicked|onPressed|onDoubleClicked)[[:space:]]*:/)
                printf "%s:%d:%s\n", FILENAME, FNR, $0
        }
    ' "$f")
    [ -n "$hits" ] && offenders="${offenders}${hits}"$'\n'
done

ok "no settings row carries its own click handler" \
    "$([ -n "$offenders" ] && printf '%s' "$offenders" || echo none)" "none"

# The dispatcher is the thing that has to exist instead. A row with no handler
# anywhere is only reachable if the surface registers it in `rows:`.
ok "the update row is registered in the surface's row table" \
    "$(grep -c 'item: updatesRow' "$SURFACES/PluginsSurface.qml")" "1"
ok "the restart row is registered in the surface's row table" \
    "$(grep -c 'item: restartRow' "$SURFACES/PluginsSurface.qml")" "1"
# ...and carries an activate, since neither is a toggle or a nav destination.
ok "the update row activates rather than toggling" \
    "$(grep -A4 'item: updatesRow' "$SURFACES/PluginsSurface.qml" | grep -c 'activate:')" "1"
ok "the restart row activates rather than toggling" \
    "$(grep -A4 'item: restartRow' "$SURFACES/PluginsSurface.qml" | grep -c 'activate:')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'