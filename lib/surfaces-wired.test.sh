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

# One of the nav rows is deliberately not a pill surface, so it is not held to
# the loader contract:
#   dock  -- the dock is its own window; shell.qml hosts it there and routes the
#            request away rather than opening a pill surface.
pillsurfaces=""
for name in $navigated; do
    case "$name" in
        dock) ;;
        *) pillsurfaces="$pillsurfaces $name" ;;
    esac
done
count=$(printf '%s\n' "$navigated" | grep -c .)
ok "Appearance declares nav rows that name surfaces" \
    "$([ "$count" -gt 0 ] && echo yes || echo no)" "yes"

# Loader id for a surface name: "fontpicker" -> "ldFontpicker".
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

# Plugins: the strip's Repeater, the layout model it renders, and the
# delegate that hosts PluginButton.
ok "the strip renders plugin entries with a Repeater" \
    "$(grep -c 'model:[[:space:]]*StripLayout.resolved' "$PILL")" "1"
ok "the strip's plugin delegate is StripCell" \
    "$(grep -c 'delegate:[[:space:]]*StripCell' "$PILL")" "1"
ok "StripCell mounts PluginButton" \
    "$(grep -c 'PluginButton[[:space:]]*{' "$ROOT/components/StripCell.qml")" "1"
ok "PluginButton is registered as a component" \
    "$(grep -cE '^PluginButton[[:space:]]+PluginButton\.qml$' "$ROOT/components/qmldir")" "1"
ok "PluginButton is actually instantiated somewhere" \
    "$(grep -rc 'PluginButton[[:space:]]*{' --include=*.qml "$ROOT" 2>/dev/null | grep -v ':0' | wc -l)" "1"

# The band geometry the plugin panels position against.
ok "plugin strip entry forwards the band height" \
    "$(grep -c 'barHeightOverride:[[:space:]]*pill.height' "$PILL")" "1"

# dock: routed, not rendered by the pill.
ok "the dock row is routed to the dock rather than opened as a pill surface" \
    "$(grep -cE 'surface === "dock"' "$ROOT/shell.qml")" "1"

if command -v node >/dev/null 2>&1; then
    if node - "$ROOT/surfaces/PluginHostSurface.qml" "$PILL" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const pill = fs.readFileSync(process.argv[3], "utf8");
assert(/onRequestClose:\s*pill\.requestClose\(\)/.test(pill), "pill receives popup close requests");
assert(/function onOpenedChanged\(\)\s*\{\s*root\.panelOpenedChanged\(\);/.test(source), "host handles popup closure");
const start = source.indexOf("    function panelOpenedChanged() {");
const end = source.indexOf("    function inject()", start);
assert(start >= 0 && end > start, "panel close handler exists");
let closes = 0;
const root = { open: true, panelWasOpened: false, requestClose() { closes++; } };
const widget = { item: { opened: false } };
const panelOpenedChanged = vm.runInNewContext(`(${source.slice(start, end).trim()})`, { root, widget });
panelOpenedChanged();
assert.equal(closes, 0);
widget.item.opened = true;
panelOpenedChanged();
widget.item.opened = false;
panelOpenedChanged();
assert.equal(closes, 1, "closing the popup should close the pill");
panelOpenedChanged();
assert.equal(closes, 1, "a close must be handled once");
root.panelWasOpened = false;
panelOpenedChanged();
assert.equal(closes, 1, "a plugin without an open popup must not close");
widget.item.opened = true;
panelOpenedChanged();
widget.item.opened = false;
panelOpenedChanged();
assert.equal(closes, 2, "closing a bar-widget popup should close the pill too");
root.open = false;
panelOpenedChanged();
assert.equal(closes, 2, "an already closed pill must not close again");
const openStart = source.indexOf("    onOpenChanged: {");
const openEnd = source.indexOf("    mTop:", openStart);
assert(openStart >= 0 && openEnd > openStart, "host handles pill close");
const openBody = source.slice(openStart, openEnd).trim().replace(/^onOpenChanged:\s*\{/, "").replace(/\}\s*$/, "");
let popupCloses = 0;
widget.item.opened = true;
widget.item.close = () => { popupCloses++; widget.item.opened = false; };
root.panelWasOpened = true;
vm.runInNewContext(`(function() { ${openBody} })`, { root, widget, open: false })();
assert.equal(popupCloses, 1, "hiding the pill should hide its popup after the surface resets");
function binding(qml, pattern, scope) {
    const match = pattern.exec(qml);
    assert(match, `missing binding: ${pattern}`);
    return vm.runInNewContext(match[1], scope);
}
const active = /readonly property bool popupActive:\s*([^\n]+)/;
assert.equal(binding(source, active, { widget: { item: { opened: true } } }), true);
assert.equal(binding(source, active, { widget: { item: { opened: false } } }), false);
assert.equal(binding(source, active, { widget: { item: {} } }), false);
const loader = source.slice(source.indexOf("id: widget"), source.indexOf("onStatusChanged", source.indexOf("id: widget")));
const loaderOpacity = /^\s*opacity:\s*([^\n]+)/m;
assert.equal(binding(loader, loaderOpacity, { root: { popupActive: true } }), 0);
assert.equal(binding(loader, loaderOpacity, { root: { popupActive: false } }), 1);
const popup = /readonly property bool pluginPopupOpen:\s*([^\n]+)/;
assert.equal(binding(pill, popup, { pluginSurfaceOpen: true, ldPluginSurface: { item: { popupActive: true } } }), true);
assert.equal(binding(pill, popup, { pluginSurfaceOpen: false, ldPluginSurface: { item: { popupActive: true } } }), false);
const rest = pill.slice(pill.indexOf("id: rest"), pill.indexOf("Behavior on opacity", pill.indexOf("id: rest")));
const restOpacity = /^\s*opacity:\s*([^\n]+)/m;
const restPill = { expanded: true, dragActive: false, mode: "plugin", morphCloseness: 1, pluginPopupOpen: true };
assert.equal(binding(rest, restOpacity, { pill: restPill, Math }), 1, "popup should show the compact pill face");
restPill.pluginPopupOpen = false;
assert.equal(binding(rest, restOpacity, { pill: restPill, Math }), 0, "inline plugins keep their surface");
const strip = pill.slice(pill.indexOf("id: stripFace"), pill.indexOf("anchors.centerIn: parent", pill.indexOf("id: stripFace")));
const stripVisible = /^\s*visible:\s*([^\n]+)/m;
const stripPill = { specialView: "", stripBar: true, surfaceOpen: true, pluginPopupOpen: true };
assert.equal(binding(strip, stripVisible, { pill: stripPill }), true);
stripPill.pluginPopupOpen = false;
assert.equal(binding(strip, stripVisible, { pill: stripPill }), false);
const bar = source.slice(source.indexOf("id: barStub"), source.indexOf("Flickable {", source.indexOf("id: barStub")));
const barHeight = /^\s*barHeightOverride:\s*([^\n]+)/m;
assert.equal(binding(bar, barHeight, { root: { barHeightOverride: 39, height: 10 } }), 39);
const hostLoader = pill.slice(pill.indexOf("id: ldPluginSurface"), pill.indexOf("id: ldLauncher", pill.indexOf("id: ldPluginSurface")));
assert.equal(binding(hostLoader, barHeight, { pill: { y: 8, height: 39 } }), 47, "popup anchor must clear the pill's top inset");
JS
    then
        ok "plugin popup lifecycle and compact pill presentation" "yes" "yes"
    else
        ok "plugin popup lifecycle and compact pill presentation" "no" "yes"
    fi
else
    ok "node is available for popup lifecycle test" "no" "yes"
fi

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'