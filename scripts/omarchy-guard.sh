#!/usr/bin/env bash
# Better Bar survival guard for Omarchy updates.
#
# An Omarchy update moves the shared shell underneath this bar. The failure mode
# is silent: Better Bar comes back unchanged, then some custom integration quietly
# stops because a shared file or the plugin registry moved. This guard is the
# small, boring opposite — it watches the installed Omarchy version, and when it
# sees a new one it rescans the host and re-asserts Better Bar's key custom
# menu row. It reports what happened instead of pretending nothing changed.
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
                "  --repair Re-assert Better Bar's custom menu row now" \
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
mkdir -p "$STATE_DIR"

# The row that keeps Better Bar's native keybind manager from being duplicated
# by the stock Setup > Keybindings Lua editor row. A plugin can rewrite the
# shared menu file; Omarchy can move it; either way this row must come back.
ensure_menu_guard() {
    local row='  "setup.keybindings": {"icon":"","label":"Keybindings","when":"false","action":"omarchy-launch-config-editor \"$HOME/.config/hypr/bindings.lua\""},'
    local action="none"

    if [ ! -f "$MENU_FILE" ]; then
        printf '{\n%s\n}\n' "$row" >"$MENU_FILE"
        action="created-menu-guard"
    elif ! grep -qF '"setup.keybindings"' "$MENU_FILE"; then
        # Insert after the opening brace, before whatever the file already
        # carries, so an existing object stays valid.
        awk -v row="$row" '
            BEGIN { inserted=0 }
            {
                if (!inserted && $0 ~ /^[[:space:]]*\{[[:space:]]*$/) {
                    print
                    print row
                    inserted=1
                    next
                }
                print
            }
            END {
                if (!inserted) {
                    print "{"
                    print row
                    print "}"
                }
            }
        ' "$MENU_FILE" >"$MENU_FILE.guard" && mv -f "$MENU_FILE.guard" "$MENU_FILE"
        action="reasserted-menu-guard"
    fi

    printf '%s' "$action"
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

# Always cheap and idempotent: the row is a few lines of JSON and its absence is
# the visible corruption an update or a plugin rewrite leaves behind.
MENU_ACTION="$(ensure_menu_guard)"
if [ "$MENU_ACTION" != "none" ]; then
    ACTIONS+=("$MENU_ACTION")
fi

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
    '{version:$version, previous:$previous, changed:$changed, actions:$actions}')"

if [ "$DO_JSON" = true ]; then
    printf '%s\n' "$STATUS_JSON"
else
    if [ "$CHANGED" = true ]; then
        printf 'Omarchy guard: update detected (%s), Better Bar re-asserted itself.\n' "$CURRENT_VERSION"
    elif [ "$MENU_ACTION" != "none" ]; then
        printf 'Omarchy guard: re-asserted Better Bar menu row.\n'
    else
        printf 'Omarchy guard: nothing to do.\n'
    fi
fi
