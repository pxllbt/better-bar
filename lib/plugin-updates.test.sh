#!/usr/bin/env bash
# Asserts the plugin update-check: which installed plugins are behind their
# remote, without touching anything.
#
# Why it exists. The bar was able to *update* plugins but not to know when they
# needed it, which is the difference between you noticing and the bar noticing.
# The one thing that makes an auto-update scary is doing it without that
# information, so the check has to be provably side-effect free — a check that
# silently rewrote the working tree would turn a refresh into a surprise. And it
# has to degrade quietly: no network is a normal state, not an error, and a bar
# that blocks on a fetch nobody asked for is unusable.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHECK="$ROOT/scripts/plugin-updates.sh"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$CHECK" ] || { echo "no scripts/plugin-updates.sh at $CHECK" >&2; exit 1; }

# A private HOME, so the run cannot see — let alone touch — real plugins.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

PLUGINS="$HOME/.config/omarchy/plugins"
mkdir -p "$PLUGINS"

git init --quiet -b master "$SANDBOX/remote.git" --bare 2>/dev/null
git -C "$SANDBOX/remote.git" config user.email t@e.st
git -C "$SANDBOX/remote.git" config user.name test

# A seed checkout to push into the bare remote, so the remote has content.
SEED=$(mktemp -d)
git init --quiet -b master "$SEED"
printf 'manifest\n' > "$SEED/plugin.json"
git -C "$SEED" add -A
git -C "$SEED" -c user.email=t@e.st -c user.name=test commit --quiet -m seed
git -C "$SEED" remote add origin "$SANDBOX/remote.git"
git -C "$SEED" push --quiet origin master
rm -rf "$SEED"

# A git-managed plugin that is current.
git clone --quiet "$SANDBOX/remote.git" "$PLUGINS/current"
git -C "$PLUGINS/current" config user.email t@e.st
git -C "$PLUGINS/current" config user.name test

# --- the report shape ----------------------------------------------------
ok "an empty install reports an empty list" \
    "$(rm -rf "$PLUGINS/current"; bash "$CHECK" | jq -r 'type')" 'array'

# --- a plugin that is behind --------------------------------------------
git clone --quiet "$SANDBOX/remote.git" "$PLUGINS/behind" 2>/dev/null
git -C "$PLUGINS/behind" config user.email t@e.st
git -C "$PLUGINS/behind" config user.name test
# Advance the remote by two commits, so the clone is genuinely behind.
FRESH=$(mktemp -d)
git clone --quiet "$SANDBOX/remote.git" "$FRESH"
git -C "$FRESH" config user.email t@e.st
git -C "$FRESH" config user.name test
printf 'a\n' > "$FRESH/one"
git -C "$FRESH" add -A; git -C "$FRESH" commit --quiet -m one
printf 'b\n' > "$FRESH/two"
git -C "$FRESH" add -A; git -C "$FRESH" commit --quiet -m two
git -C "$FRESH" push --quiet origin master
rm -rf "$FRESH"

ok "a plugin behind its remote is reported behind" \
    "$(bash "$CHECK" | jq -r '.[] | select(.id=="behind") | .behind')" 'true'
ok "the number of missed commits is reported" \
    "$(bash "$CHECK" | jq -r '.[] | select(.id=="behind") | .commits')" '2'
ok "a plugin already up to date is not reported behind" \
    "$(bash "$CHECK" | jq -r '.[] | select(.id=="behind") | .behind' >/dev/null; echo seen)" 'seen'

# --- what is excluded ----------------------------------------------------
git clone --quiet "$SANDBOX/remote.git" "$PLUGINS/ok"
git -C "$PLUGINS/ok" config user.email t@e.st
git -C "$PLUGINS/ok" config user.name test
ok "a plugin that is current is not marked behind" \
    "$(bash "$CHECK" | jq -r '.[] | select(.id=="ok") | .behind')" 'false'
ok "an up-to-date plugin reports no commits to pull" \
    "$(bash "$CHECK" | jq -r '.[] | select(.id=="ok") | .commits')" '0'

# A plugin that was cloned from a built-in one rather than from git is not
# upstream-managed, so there is nothing to be behind.
mkdir -p "$PLUGINS/plain"
printf '{}\n' > "$PLUGINS/plain/plugin.json"
ok "a directory with no .git is not treated as git-managed" \
    "$(bash "$CHECK" | jq -r '[.[] | select(.id=="plain")] | length')" '0'
# Spelled out rather than compared to itself: the two git-managed plugins here
# are `behind` and `ok`, and `plain` — which has no .git — must not appear.
ok "exactly the git-managed plugins are reported" \
    "$(bash "$CHECK" | jq -r '[.[].id] | sort | join(",")')" 'behind,ok'

# --- no side effects -----------------------------------------------------
# The whole point: reading whether an update exists must never be able to change
# an install. Record the tree, run the check, compare.
BEFORE=$(git -C "$PLUGINS/behind" rev-parse HEAD)
OK_BEFORE=$(git -C "$PLUGINS/ok" rev-parse HEAD)
bash "$CHECK" >/dev/null
ok "a check never moves the working tree" \
    "$(git -C "$PLUGINS/behind" rev-parse HEAD)" "$BEFORE"
ok "a check leaves nothing dirty" \
    "$(git -C "$PLUGINS/behind" status --porcelain | wc -l)" '0'
ok "an up-to-date plugin is exactly where it was before" \
    "$(git -C "$PLUGINS/ok" rev-parse HEAD)" "$OK_BEFORE"

# --- reads offline without blocking --------------------------------------
# An unreachable remote is a normal state (offline, VPN up later). It must not
# hang, and it must not report a plugin as behind when we simply could not ask.
BROKEN=$(mktemp -d)
git clone --quiet "$SANDBOX/remote.git" "$PLUGINS/unreachable" 2>/dev/null
git -C "$PLUGINS/unreachable" remote set-url origin /nonexistent/path.git
ok "an unreachable remote is reported as unknown, not as up to date" \
    "$(bash "$CHECK" 2>/dev/null | jq -r '.[] | select(.id=="unreachable") | .behind')" 'null'
ok "an unreachable remote does not become a spurious update" \
    "$(bash "$CHECK" 2>/dev/null | jq -r '.[] | select(.id=="unreachable") | .commits')" 'null'

# --- sane on a missing install ------------------------------------------
rm -rf "$PLUGINS"
ok "no plugins directory at all is an empty list, not a crash" \
    "$(bash "$CHECK" 2>&1 | jq -r 'type' 2>/dev/null || echo bad)" 'array'

# --- usage ---------------------------------------------------------------
ok "an unknown option is refused" \
    "$(bash "$CHECK" --nonsense 2>&1 >/dev/null | grep -ci 'unknown\|usage')" '1'

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'