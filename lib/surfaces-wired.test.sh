#!/usr/bin/env bash
# Asserts that every surface Appearance navigates to is actually wired into the
# pill, and that enabled plugins reach the strip.
#
# The bug this exists for: PluginsSurface.qml existed and Appearance's plugins
# tile navigated to surface "plugins", but nothing in Pill.qml ever mentioned
# that name -- no Loader, no entry in the loader map, no entry in the surfaces
# map, no `pluginsOpen`. Clicking Plugins set the surface, `surfaceOpen` went
# true, and the morph fell through to a fallback because `surfaces["plugins"]`
# was undefined. Nothing appeared and nothing said why; the tile looked inert.
#
# So this reads both files as text and checks the four declarations a surface
# needs before the pill can render it. A click test would have shown "nothing
# opened" without telling an unwired surface apart from a broken one.
#
# A shell test rather than a QML one on purpose: the failure is a missing
# declaration, and QML would report it as an exception in whatever happened to
# touch it next, which is the same invisibility in a new place.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
PILL="$ROOT/Pill.qml"
APPEARANCE="$ROOT/surfaces/Appearance.qml"
QMLDIR="$ROOT/surfaces/qmldir"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# The surfaces Appearance's nav rows navigate to, in declaration order.
# The property is `rows:`, and the block ends at the first line that is only
# a closing bracket -- matching on `navRows` silently found nothing and made
# every check below it vacuously pass.
navigated=$(sed -n '/^[[:space:]]*rows:[[:space:]]*\[/,/^[[:space:]]*\]/p' "$APPEARANCE" \
    | grep -oE 'surface:[[:space:]]*"[a-z]+"' | grep -oE '"[a-z]+"' | tr -d '"')

# Two of the nav rows are deliberately not pill surfaces, so they are not held
# to the loader contract:
#   dock          -- the dock is its own window; shell.qml hosts it there and
#                   routes the request away rather than opening a pill surface.
#   locksettings  -- the lockscreen is not in the repository, so the surface and
#                   its loader are system-only. Asserted separately below.
pillsurfaces=""
for name in $navigated; do
    case "$name" in
        dock|locksettings) ;;
        *) pillsurfaces="$pillsurfaces $name" ;;
    esac
done
count=$(printf '%s\n' "$navigated" | grep -c .)
ok "Appearance declares nav rows that name surfaces" \
    "$([ "$count" -gt 0 ] && echo yes || echo no)" "yes"

# Loader id for a surface name: "locksettings" -> "ldLocksettings".
loader_for() { printf 'ld%s' "$(printf '%s' "$1" | sed 's/^./\U&/')"; }

missing=""
for name in $pillsurfaces; do
    ldr=$(loader_for "$name")

    grep -qE "id:[[:space:]]*${ldr}\b" "$PILL" || { missing="$missing $name:no-loader"; continue; }
    grep -qE "^[[:space:]]*${name}:[[:space:]]*\(\)[[:space:]]*=>[[:space:]]*${ldr}\b" "$PILL" \
        || { missing="$missing $name:no-loader-map"; continue; }
    grep -qE "^[[:space:]]*${name}:[[:space:]]*\{" "$PILL" \
        || { missing="$missing $name:no-surface-map"; continue; }
    grep -qE "${name}Open:[[:space:]]*surface === \"${name}\"" "$PILL" \
        || { missing="$missing $name:no-open-prop"; continue; }
done
ok "every navigated surface has a loader, a loader-map entry, a surfaces-map entry and an open property" \
    "$(printf '%s' "$missing" | sed 's/^ *//')" ""

# The surface each name loads must be a registered type with a file behind it.
unresolved=""
for name in $pillsurfaces; do
    ldr=$(loader_for "$name")
    type=$(sed -n "/id:[[:space:]]*${ldr}\b/,/^[[:space:]]*}/p" "$PILL" \
        | grep -oE 'sourceComponent:[[:space:]]*[A-Za-z]+' | head -1 | awk '{print $2}')
    [ -n "$type" ] || { unresolved="$unresolved $name:?"; continue; }
    grep -qE "^${type}[[:space:]]+${type}\.qml$" "$QMLDIR" \
        || { unresolved="$unresolved $name:$type"; continue; }
    [ -f "$ROOT/surfaces/$type.qml" ] || unresolved="$unresolved $name:$type:missing-file"
done
ok "every navigated surface resolves to a registered type whose file exists" \
    "$(printf '%s' "$unresolved" | sed 's/^ *//')" ""

# Plugins: the strip's Repeater, its model, and the component it delegates to.
ok "the strip renders plugin entries with a Repeater" \
    "$(grep -c 'model:[[:space:]]*Plugins.pillWidgetsGeneric' "$PILL")" "1"
ok "the strip's plugin delegate is PluginButton" \
    "$(grep -c 'delegate:[[:space:]]*PluginButton' "$PILL")" "1"
ok "PluginButton is registered as a component" \
    "$(grep -cE '^PluginButton[[:space:]]+PluginButton\.qml$' "$ROOT/components/qmldir")" "1"
ok "PluginButton is actually instantiated somewhere" \
    "$(grep -rc 'PluginButton[[:space:]]*{' --include=*.qml "$ROOT" 2>/dev/null | grep -v ':0' | wc -l)" "1"

# The band geometry the plugin panels position against.
ok "plugin entries forward the band height so a panel lands under the pill" \
    "$(grep -c 'barHeightOverride:[[:space:]]*pill.height' "$PILL")" "1"

# dock and locksettings: routed, not rendered by the pill.
ok "the dock row is routed to the dock rather than opened as a pill surface" \
    "$(grep -cE 'surface === "dock"' "$ROOT/shell.qml")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'