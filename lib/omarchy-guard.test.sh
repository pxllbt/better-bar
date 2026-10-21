#!/usr/bin/env bash
# Asserts the Omarchy survival guard is real and self-running.
#
# Why this exists: an Omarchy update can move the shared shell forward under
# Better Bar. Better Bar’s own update guard already protects local work from a
# Better Bar update; this is the other side — when Omarchy itself changes, the
# bar should notice, rescan, re-assert its custom menu rows, and report what it
# did instead of silently looking broken after an upgrade.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT/scripts/omarchy-guard.sh"
SINGLETON="$ROOT/Singletons/OmarchyGuard.qml"
FLAGS="$ROOT/Singletons/Flags.qml"
SURFACE="$ROOT/surfaces/DisplaySurface.qml"
QMLDIR="$ROOT/Singletons/qmldir"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SCRIPT" ] || { echo "no scripts/omarchy-guard.sh at $SCRIPT" >&2; exit 1; }

ok "the guard script exists" "yes" "$([ -f "$SCRIPT" ] && echo yes || echo no)"
ok "the guard script is executable" "yes" "$([ -x "$SCRIPT" ] && echo yes || echo no)"

ok "the guard tracks the installed omarchy version" \
    "$(grep -c 'omarchy-version' "$SCRIPT")" "2"

ok "the guard persists the last seen version" \
    "$(grep -c 'omarchy-guard.json' "$SCRIPT")" "1"

ok "the guard rescans the host when the version moved" \
    "$(grep -c 'rescanPlugins' "$SCRIPT")" "2"

ok "the guard re-asserts the hidden keybind menu row" \
    "$(grep -c 'setup.keybindings' "$SCRIPT")" "2"

ok "the guard re-asserts the hidden network speed test row" \
    "$(grep -c 'trigger.tests.network-speedtest' "$SCRIPT")" "2"

# awk eats the backslash of an escape sequence in a -v assignment, so a row
# written through `awk -v row=...` loses its escaped quotes and lands in the
# menu file as invalid JSONC. Every parser then throws the whole file away and
# the menu silently loses every custom row. The rows travel through the
# environment instead.
ok "the guard does not write menu rows through awk -v" \
    "$(grep -c -- '-v row=' "$SCRIPT")" "0"

ok "the guard checks that the menu file parses" \
    "$(grep -c 'parseMenuJsonc' "$SCRIPT")" "1"

ok "the guard has a machine-readable status mode" \
    "$(grep -c -- '--json' "$SCRIPT")" "3"

ok "the survival flag is persisted" \
    "$(grep -c 'property alias omarchySurvival' "$FLAGS")" "1"
ok "survival defaults to on" \
    "$(grep -c 'property bool omarchySurvival: true' "$FLAGS")" "1"

ok "the guard singleton is registered" \
    "$(grep -c '^singleton OmarchyGuard OmarchyGuard.qml$' "$QMLDIR")" "1"

ok "the guard singleton reads the guard script" \
    "$(grep -c 'omarchy-guard.sh' "$SINGLETON")" "1"

ok "the interface settings expose the survival row" \
    "$(grep -c 'id: omarchySurvivalRow' "$SURFACE")" "1"

# The guard has to REPAIR a broken row, not only add a missing one.
#
# An unescaped quote in the keybind action is not valid JSONC. Every parser
# that reads the extension file -- the stock Omarchy menu and lib/menu.js
# alike -- throws the whole file away when it sees one, so the menu silently
# loses every custom row at once, and a guard that only greps for its own id
# calls that a success.
#
# It runs against a throwaway HOME, so the user's own menu file is never
# touched.
if command -v node >/dev/null 2>&1; then
    TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-guard-test.XXXXXX")"
    trap 'rm -rf "$TMP_HOME"' EXIT

    # The rows the menu model actually sees, one per line.
    menu_rows() {
        node - "$ROOT/lib/menu.js" "$1" <<'JS' 2>/dev/null
const fs = require("fs");
const vm = require("vm");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx);
const items = ctx.parseMenuJsonc(fs.readFileSync(process.argv[3], "utf8"));
for (var i = 0; i < items.length; i++)
    console.log(items[i].id + "|" + items[i].when + "|" + items[i].label + "|" + items[i].action);
JS
    }

    EXT="$TMP_HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
    mkdir -p "$(dirname "$EXT")"

    # 1. A malformed row: the quotes of the action are not escaped.
    cat >"$EXT" <<'JSONC'
{
  "setup.keybindings": {"icon":"","label":"Keybindings","when":"false","action":"omarchy-launch-config-editor "$HOME/.config/hypr/bindings.lua""},
}
JSONC
    env HOME="$TMP_HOME" XDG_CONFIG_HOME="$TMP_HOME/.config" XDG_STATE_HOME="$TMP_HOME/state" \
        bash "$SCRIPT" >/dev/null 2>&1

    ROWS="$(menu_rows "$EXT")"
    ok "the guard repairs a malformed keybind row" \
        "$(printf '%s\n' "$ROWS" | grep -c 'setup\.keybindings|false|Keybindings|omarchy-launch-config-editor "')" "1"
    ok "the guard leaves no unescaped quote behind" \
        "$(grep -cF 'bindings.lua""}' "$EXT")" "0"
    ok "the guard re-asserts the speedtest row while it repairs" \
        "$(printf '%s\n' "$ROWS" | grep -c 'trigger\.tests\.network-speedtest|false|Network Speed Test|omarchy-shell shell summon omarchy.speedtest')" "1"
    ok "the repaired menu file parses" \
        "$(printf '%s\n' "$ROWS" | grep -c .)" "2"

    # 2. A file that lost the rows entirely -- the plugin rewrite case.
    cat >"$EXT" <<'JSONC'
{
  "personal.notes": {"icon":"N","label":"Notes","action":"true"},
}
JSONC
    env HOME="$TMP_HOME" XDG_CONFIG_HOME="$TMP_HOME/.config" XDG_STATE_HOME="$TMP_HOME/state" \
        bash "$SCRIPT" >/dev/null 2>&1

    ROWS="$(menu_rows "$EXT")"
    ok "the guard re-asserts the keybind row after a rewrite" \
        "$(printf '%s\n' "$ROWS" | grep -c 'setup\.keybindings|false|Keybindings|omarchy-launch-config-editor "')" "1"
    ok "the guard re-asserts the speedtest row after a rewrite" \
        "$(printf '%s\n' "$ROWS" | grep -c 'trigger\.tests\.network-speedtest|false|Network Speed Test|omarchy-shell shell summon omarchy.speedtest')" "1"
    ok "the guard leaves the other rows of the file alone" \
        "$(printf '%s\n' "$ROWS" | grep -c 'personal\.notes||Notes|true')" "1"

    # 3. A file that is not valid JSONC at all cannot be repaired by guessing:
    # the guard has to say so instead of declaring victory.
    printf '%s\n' '{ "broken": ' >"$EXT"
    env HOME="$TMP_HOME" XDG_CONFIG_HOME="$TMP_HOME/.config" XDG_STATE_HOME="$TMP_HOME/state" \
        bash "$SCRIPT" >/dev/null 2>&1
    ok "the guard fails loudly on a menu file it cannot parse" \
        "$?" "1"
fi

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
