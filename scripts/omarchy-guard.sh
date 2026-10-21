#!/usr/bin/env bash
# Better Bar survival guard for Omarchy updates.
#
# An Omarchy update moves the shared shell underneath this bar. The failure mode
# is silent: Better Bar comes back unchanged, then some custom integration quietly
# stops because a shared file or the plugin registry moved. This guard is the
# small, boring opposite — it watches the installed Omarchy version, and when it
# sees a new one it rescans the host and re-asserts Better Bar's key custom
# menu rows. It reports what happened instead of pretending nothing changed.
set -uo pipefail

DO_JSON=false
DO_REPAIR=false
for arg in "$@"; do
    case "$arg" in
        --json) DO_JSON=true ;;
        --repair) DO_REPAIR=true ;;
        -h|--help)
            printf '%s\n' \
                "Usage: omarchy-guard.sh [--json] [--repair]" \
                "  --json    Emit machine-readable JSON status" \
                "  --repair Re-assert Better Bar's custom menu rows now" \
                "  (no args) Record the current Omarchy version if it is the first run"
            exit 0
            ;;
        *)
            printf 'omarchy-guard.sh: unknown argument: %s\n' "$arg" >&2
            exit 1
            ;;
    esac
done

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/better"
STATE_FILE="$STATE_DIR/omarchy-guard.json"
MENU_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"

# The menu model is the code the launcher itself reads the extension file with,
# so the guard asks it whether the file is usable instead of guessing at the
# format.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MENU_MODEL="$REPO_ROOT/lib/menu.js"
mkdir -p "$STATE_DIR"

# The two rows this bar owns in the shared menu file.
#
# Both hide a stock row by re-declaring it with a failing `when`, and both
# restate every field: normalizeItem() fills in a default for every key, so a
# sparse override does not merely hide the row, it blanks the stock icon, label
# and action and leaves a corrupt entry behind.
#
# The inner quotes of the keybind action are ESCAPED, and that is not a style
# choice. An unescaped quote is not valid JSONC, and every parser that reads
# this file -- the stock Omarchy menu and lib/menu.js alike -- throws the whole
# file away when it sees one, which silently drops every other custom row with
# it. The row is therefore detected by the escaped quote it carries: a row
# without one is a row whose quotes are unescaped, and it gets rewritten.
MENU_KEYBIND_ID='"setup.keybindings"'
MENU_KEYBIND_ROW='  "setup.keybindings": {"icon":"","label":"Keybindings","when":"false","action":"omarchy-launch-config-editor \"$HOME/.config/hypr/bindings.lua\""},'
MENU_SPEEDTEST_ID='"trigger.tests.network-speedtest"'
MENU_SPEEDTEST_ROW='  "trigger.tests.network-speedtest": {"icon":"󰓅","label":"Network Speed Test","when":"false","action":"omarchy-shell shell summon omarchy.speedtest"},'

export OMARCHY_GUARD_KEYBIND_ID="$MENU_KEYBIND_ID"
export OMARCHY_GUARD_SPEEDTEST_ID="$MENU_SPEEDTEST_ID"

# A guard row has to restate every field, and it has to be parseable on its own.
menu_row_is_complete() {
    local row="$1"
    printf '%s' "$row" | grep -q '"icon"' || return 1
    printf '%s' "$row" | grep -q '"label"' || return 1
    printf '%s' "$row" | grep -q '"action"' || return 1
    printf '%s' "$row" | grep -qE '"when"[[:space:]]*:[[:space:]]*"false"' || return 1
    return 0
}

# Re-assert the rows this bar owns in the shared menu file.
#
# A plugin can rewrite the shared menu file; Omarchy can move it; either way
# these rows must come back, in the exact shape they are written here. Returns
# one action name per line, or "none".
ensure_menu_guard() {
    local actions=""

    if [ ! -f "$MENU_FILE" ]; then
        mkdir -p "$(dirname "$MENU_FILE")"
        printf '{\n%s\n%s\n}\n' "$MENU_KEYBIND_ROW" "$MENU_SPEEDTEST_ROW" >"$MENU_FILE"
        printf 'created-menu-guard'
        return 0
    fi

    # Only the lines that define a row count: a commented-out row is not a row.
    local rows keybind_line speedtest_line
    rows="$(grep -v '^[[:space:]]*//' "$MENU_FILE" || true)"
    keybind_line="$(printf '%s\n' "$rows" | grep -F "$MENU_KEYBIND_ID" | head -1)"
    speedtest_line="$(printf '%s\n' "$rows" | grep -F "$MENU_SPEEDTEST_ID" | head -1)"

    local keybind_state="missing" speedtest_state="missing"
    if [ -n "$keybind_line" ]; then
        keybind_state="replace"
        if menu_row_is_complete "$keybind_line" && printf '%s' "$keybind_line" | grep -qF '\"'; then
            keybind_state="keep"
        fi
    fi
    if [ -n "$speedtest_line" ]; then
        speedtest_state="replace"
        if menu_row_is_complete "$speedtest_line"; then
            speedtest_state="keep"
        fi
    fi

    if [ "$keybind_state" = "keep" ] && [ "$speedtest_state" = "keep" ]; then
        printf 'none'
        return 0
    fi

    # The rows travel through the environment, not through awk's -v: awk eats
    # the backslash of an escape sequence in a -v assignment, which is exactly
    # how the keybind row used to be written with its quotes unescaped.
    export OMARCHY_GUARD_KEYBIND_ROW="$MENU_KEYBIND_ROW"
    export OMARCHY_GUARD_KEYBIND_STATE="$keybind_state"
    export OMARCHY_GUARD_SPEEDTEST_ROW="$MENU_SPEEDTEST_ROW"
    export OMARCHY_GUARD_SPEEDTEST_STATE="$speedtest_state"

    awk '
        BEGIN { n = 0; open_at = 0 }
        {
            line = $0
            if (line !~ /^[[:space:]]*\/\//) {
                if (index(line, ENVIRON["OMARCHY_GUARD_KEYBIND_ID"]) > 0) {
                    seen_keybind = 1
                    if (ENVIRON["OMARCHY_GUARD_KEYBIND_STATE"] == "replace")
                        line = ENVIRON["OMARCHY_GUARD_KEYBIND_ROW"]
                }
                if (index(line, ENVIRON["OMARCHY_GUARD_SPEEDTEST_ID"]) > 0) {
                    seen_speedtest = 1
                    if (ENVIRON["OMARCHY_GUARD_SPEEDTEST_STATE"] == "replace")
                        line = ENVIRON["OMARCHY_GUARD_SPEEDTEST_ROW"]
                }
            }
            lines[++n] = line
            if (open_at == 0 && line ~ /^[[:space:]]*\{[[:space:]]*$/)
                open_at = n
        }
        END {
            if (open_at == 0) {
                print "{"
                if (!seen_keybind) print ENVIRON["OMARCHY_GUARD_KEYBIND_ROW"]
                if (!seen_speedtest) print ENVIRON["OMARCHY_GUARD_SPEEDTEST_ROW"]
                for (i = 1; i <= n; i++) print lines[i]
                print "}"
            } else {
                for (i = 1; i <= n; i++) {
                    print lines[i]
                    if (i == open_at) {
                        if (!seen_keybind) print ENVIRON["OMARCHY_GUARD_KEYBIND_ROW"]
                        if (!seen_speedtest) print ENVIRON["OMARCHY_GUARD_SPEEDTEST_ROW"]
                    }
                }
            }
        }
    ' "$MENU_FILE" >"$MENU_FILE.guard" && mv -f "$MENU_FILE.guard" "$MENU_FILE"

    if [ "$keybind_state" = "replace" ] || [ "$speedtest_state" = "replace" ]; then
        printf 'repaired-menu-guard'
    fi
    if [ "$keybind_state" = "missing" ] || [ "$speedtest_state" = "missing" ]; then
        printf '\nreasserted-menu-guard'
    fi
    return 0
}

# A node that can read the menu model. mise owns node on this desktop and the
# bar's own environment does not always carry the shims on PATH. The installed
# binaries come before the shims: a shim needs mise's own configuration, and
# without it the shim fails instead of running node.
find_node() {
    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi
    local candidate
    for candidate in \
        "$HOME"/.local/share/mise/installs/node/*/bin/node \
        /usr/local/bin/node \
        /usr/bin/node \
        "$HOME/.local/share/mise/shims/node"; do
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    if command -v mise >/dev/null 2>&1; then
        candidate="$(mise which node 2>/dev/null || true)"
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    fi
    return 1
}

# Does the extension file actually parse, with both guard rows in it?
#
# A row being present is not the same as the file being usable: a file that
# does not parse is not a file with a missing row, it is a file the menu throws
# away whole, custom rows and all. The model is the one the launcher uses, so
# the answer is the answer the launcher gets.
#
# The answer is a verdict, not an exit code: a node that cannot even start is
# an unverified menu, not a broken one, and the two must not look alike.
#
# 0 = sound, 1 = broken, 2 = could not be checked.
menu_file_is_sound() {
    local node_bin
    node_bin="$(find_node)" || return 2
    [ -n "$node_bin" ] || return 2
    [ -f "$MENU_MODEL" ] || return 2

    local out verdict
    out="$("$node_bin" - "$MENU_MODEL" "$MENU_FILE" 2>&1 <<'JS'
const fs = require("fs");
const vm = require("vm");

function report(line) {
    console.log(line);
    process.exit(0);
}

try {
    const src = fs.readFileSync(process.argv[2], "utf8");
    const ctx = {};
    vm.createContext(ctx);
    vm.runInContext(src, ctx);

    const items = ctx.parseMenuJsonc(fs.readFileSync(process.argv[3], "utf8"));
    if (!items.length)
        report("broken:the extension file parsed to zero rows");

    function row(id) {
        for (var i = 0; i < items.length; i++)
            if (items[i].id === id) return items[i];
        return null;
    }

    const keybind = row(process.env.OMARCHY_GUARD_KEYBIND_ID.replace(/"/g, ""));
    if (!keybind || keybind.when !== "false" || !keybind.action)
        report("broken:the keybind guard row did not survive the parse");

    const speedtest = row(process.env.OMARCHY_GUARD_SPEEDTEST_ID.replace(/"/g, ""));
    if (!speedtest || speedtest.when !== "false" || !speedtest.icon || !speedtest.label || !speedtest.action)
        report("broken:the network speed test guard row did not survive the parse");

    report("sound");
} catch (e) {
    report("error:" + (e && e.message ? e.message : String(e)));
}
JS
)"
    verdict="$(printf '%s\n' "$out" | grep -E '^(sound|broken:|error:)' | tail -1)"
    case "$verdict" in
        sound)
            return 0
            ;;
        broken:*)
            printf 'omarchy-guard: %s\n' "${verdict#broken:}" >&2
            return 1
            ;;
        error:*)
            printf 'omarchy-guard: the menu file could not be checked: %s\n' "${verdict#error:}" >&2
            return 2
            ;;
        *)
            printf 'omarchy-guard: node could not read the menu file\n' >&2
            return 2
            ;;
    esac
}

CURRENT_VERSION="$(omarchy-version 2>/dev/null || true)"
PREVIOUS_VERSION=""
if [ -f "$STATE_FILE" ]; then
    PREVIOUS_VERSION="$(jq -r '.version // ""' "$STATE_FILE" 2>/dev/null || true)"
fi

ACTIONS=()
CHANGED=false

if [ -n "$CURRENT_VERSION" ]; then
    if [ ! -f "$STATE_FILE" ]; then
        ACTIONS+=("initialised")
    elif [ "$CURRENT_VERSION" != "$PREVIOUS_VERSION" ]; then
        CHANGED=true
        ACTIONS+=("omarchy-update-detected")
        # Plugin and service registrations are the part of the shell that moves
        # under the bar on an update, so rescan before reporting success.
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
        ACTIONS+=("rescanPlugins")
    fi
else
    ACTIONS+=("omarchy-version-unavailable")
fi

# Always cheap and idempotent: the rows are a few lines of JSON and their
# absence -- or their corruption -- is the visible breakage an update or a
# plugin rewrite leaves behind.
MENU_ACTIONS="$(ensure_menu_guard)"
MENU_CHANGED=false
if [ -n "$MENU_ACTIONS" ] && [ "$MENU_ACTIONS" != "none" ]; then
    MENU_CHANGED=true
    while IFS= read -r menu_action; do
        [ -n "$menu_action" ] || continue
        ACTIONS+=("$menu_action")
    done <<<"$MENU_ACTIONS"
fi

# Then the check that matters: does the file the menu reads still parse? A
# guard that only greps for its own rows declares victory over a file every
# parser throws away.
MENU_PARSE="ok"
menu_file_is_sound
case $? in
    0) ;;
    2)
        MENU_PARSE="unverified"
        printf 'omarchy-guard: node is unavailable, the menu file was not verified\n' >&2
        ACTIONS+=("menu-parse-unverified")
        ;;
    *)
        MENU_PARSE="broken"
        printf 'omarchy-guard: the menu file does not parse, the menu is dropping every custom row\n' >&2
        ACTIONS+=("menu-parse-broken")
        ;;
esac

if [ -n "$CURRENT_VERSION" ] && { [ ! -f "$STATE_FILE" ] || [ "$CURRENT_VERSION" != "$PREVIOUS_VERSION" ]; }; then
    jq -n --arg version "$CURRENT_VERSION" --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{version:$version, checked:$checked}' >"$STATE_FILE"
fi

ACTIONS_JSON="[]"
for action in ${ACTIONS[@]+"${ACTIONS[@]}"}; do
    ACTIONS_JSON="$(printf '%s' "$ACTIONS_JSON" | jq -c --arg a "$action" '. + [$a]')"
done

STATUS_JSON="$(jq -n \
    --arg version "$CURRENT_VERSION" \
    --arg previous "$PREVIOUS_VERSION" \
    --argjson changed "$CHANGED" \
    --argjson actions "$ACTIONS_JSON" \
    --arg menu "$MENU_PARSE" \
    '{version:$version, previous:$previous, changed:$changed, actions:$actions, menu:$menu}')"

if [ "$DO_JSON" = true ]; then
    printf '%s\n' "$STATUS_JSON"
else
    if [ "$CHANGED" = true ]; then
        printf 'Omarchy guard: update detected (%s), Better Bar re-asserted itself.\n' "$CURRENT_VERSION"
    elif [ "$MENU_CHANGED" = true ]; then
        printf 'Omarchy guard: re-asserted Better Bar menu rows.\n'
    else
        printf 'Omarchy guard: nothing to do.\n'
    fi
fi

# A menu file that does not parse is a real failure, not a status: say so
# loudly instead of reporting success over a file the menu discards.
if [ "$MENU_PARSE" = "broken" ]; then
    exit 1
fi
