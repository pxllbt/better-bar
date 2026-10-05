#!/usr/bin/env bash
# Asserts that uninstall.sh cannot delete a user's settings by accident.
#
# The bug this exists for: uninstall.sh removed ~/.local/state/better and
# ~/.cache/better without asking. On this machine that destroyed real
# preferences — theme, accent, wallpaper and dock choices — which were not
# recoverable, and it happened while the script was being run as a test. A
# previous version of the test harness did not redirect XDG_STATE_HOME, so a
# "harmless" invocation reached the real HOME.
#
# So the script now takes --keep-state and --dry-run, and prompts on a terminal.
# These assertions pin that behaviour, and each one is checked by running the
# real script against a sandboxed HOME with stub binaries on PATH — no stubbing
# of the script itself, because a stubbed uninstall.sh would pass these tests
# while the real one kept deleting things.
#
# Every XDG root is redirected, not just HOME. See lib/omshell-load.test.sh for
# why that is not redundant.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
UNINSTALL="$ROOT/uninstall.sh"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$UNINSTALL" ] || { echo "no uninstall.sh at $UNINSTALL" >&2; exit 1; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

# Build one throwaway HOME with the plugin installed in it, plus saved state.
# $1 is the sandbox name; prints the path to the uninstall script inside it.
mkhome() {
    local h="$SANDBOX/$1"
    mkdir -p "$h/.config/omarchy/plugins" "$h/.local/state/better" "$h/.cache/better" "$h/bin"
    cp -r "$ROOT" "$h/.config/omarchy/plugins/pix.bar"
    rm -rf "$h/.config/omarchy/plugins/pix.bar/.git"
    echo '{"lockMethod":"hyprlock"}' > "$h/.local/state/better/flags.json"
    echo 'cached' > "$h/.cache/better/session"
    # An omarchy stub, so nothing reaches the real command. plugin list reports
    # pix.bar as registered, which is the branch that also restores the stock
    # bar.
    printf '#!/bin/sh\ncase "$*" in\n  "plugin list --json") echo %s ;;\nesac\nexit 0\n' \
        "'[{\"id\":\"pix.bar\"}]'" > "$h/bin/omarchy"
    chmod +x "$h/bin/omarchy"
    echo "$h/.config/omarchy/plugins/pix.bar/uninstall.sh"
}

# Run the script in a sandbox home. Extra args pass through. No stdin, so a
# prompt would read EOF and take its default.
run() {
    local script="$1"; shift
    local h="${script%/uninstall.sh}"
    h="${h%/.config/omarchy/plugins/pix.bar}"
    env -i PATH="$h/bin:/usr/bin:/bin" HOME="$h" \
        XDG_CONFIG_HOME="$h/.config" \
        XDG_STATE_HOME="$h/.local/state" \
        XDG_DATA_HOME="$h/.local/share" \
        XDG_CACHE_HOME="$h/.cache" \
        sh "$script" "$@" </dev/null 2>&1
}

state_present() {
    local h="${1%/uninstall.sh}"
    h="${h%/.config/omarchy/plugins/pix.bar}"
    [ -f "$h/.local/state/better/flags.json" ] && echo yes || echo no
}

plugin_present() {
    local h="${1%/uninstall.sh}"
    h="${h%/.config/omarchy/plugins/pix.bar}"
    [ -d "$h/.config/omarchy/plugins/pix.bar" ] && echo yes || echo no
}

# --- --dry-run removes nothing at all -------------------------------------
S=$(mkhome dryrun)
before_state=$(state_present "$S")
out=$(run "$S" --dry-run)
ok "dry run says nothing will be removed" \
    "$(printf '%s' "$out" | grep -c 'Nothing will be removed')" "1"
ok "dry run leaves the plugin dir alone" "$(plugin_present "$S")" "yes"
ok "dry run leaves saved settings alone" "$(state_present "$S")" "$before_state"

# --- the non-interactive guard ---------------------------------------------
# This is the case that cost real preferences. With no terminal to ask on, the
# only safe answer is to keep the state and say so.
S=$(mkhome notty)
out=$(run "$S")
ok "without a terminal it refuses to delete settings" "$(state_present "$S")" "yes"
# The message is asserted alongside the outcome on purpose. State surviving is
# also what happens when the script dies early for an unrelated reason, so on
# its own it is a weak signal: a broken copy that aborted before reaching the
# state paths would pass it while deleting nothing at all. Requiring the
# explanation means the state was kept *because* the script decided to keep it.
ok "and it says why" \
    "$(printf '%s' "$out" | grep -c 'Not a terminal')" "1"
# And the plugin must still go. "Kept everything" is not the same behaviour as
# "kept the settings, removed the program files", and only the second is right.
ok "and it still removes the plugin itself" "$(plugin_present "$S")" "no"

# --- --keep-state is explicit and honoured ---------------------------------
S=$(mkhome keepstate)
out=$(run "$S" --keep-state)
ok "--keep-state keeps saved settings" "$(state_present "$S")" "yes"
ok "--keep-state removes the plugin" "$(plugin_present "$S")" "no"

# --- the flags are documented and parsed ----------------------------------
# Counted in the usage header and the case arms only, not across the whole file:
# a count over every mention would pass even if the flag were undocumented, and
# would break the next time a comment mentions it. grep -F because these are
# literal leading-dash strings and -E would read \-\- as an escaped backslash.
# Matched on the usage lines themselves ("#   uninstall.sh --flag"), so a
# prose mention further down the header does not satisfy this.
ok "--dry-run is in the usage header" \
    "$(sed -n '1,25p' "$UNINSTALL" | grep -cE '^#   uninstall\.sh +--dry-run')" "1"
ok "--keep-state is in the usage header" \
    "$(sed -n '1,25p' "$UNINSTALL" | grep -cE '^#   uninstall\.sh +--keep-state')" "1"
ok "both flags are parsed" \
    "$(grep -cE '^        --dry-run\)' "$UNINSTALL")" "1"
ok "--keep-state is accepted" \
    "$(grep -cE '^        --keep-state\)' "$UNINSTALL")" "1"

[ "$failed" -eq 0 ] && printf '\nall green\n' || printf '\n%s failing\n' "$failed"
exit $((failed > 0))