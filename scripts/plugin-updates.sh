#!/usr/bin/env bash
#
# Which installed plugins are behind their remote, reported without changing
# anything.
#
# The bar could already update a plugin; it could not know one was out of date
# until you asked. That is the wrong direction round. An auto-update you have to
# think about is not automatic, and the one thing that makes silently updating
# someone's software acceptable is knowing what it would do first.
#
# Design constraints, all of them cost me something to keep:
#
#   Read-only. A check must not be able to alter an install. Nothing here
#   writes: `fetch` moves refs, never the working tree, and `rev-list` and
#   `rev-parse` are reads. The tests assert HEAD and the index are unchanged
#   afterwards, because that is the property that stops a refresh becoming a
#   surprise.
#
#   Side-effect-free per plugin. One unreachable remote cannot hide the rest:
#   a plugin we could not ask about is reported as `behind: null` — unknown,
#   not "up to date". Reporting it as current is how a broken network turns
#   into a missed update that looks like a clean bill of health.
#
#   Never blocks. Every fetch is time-boxed. An offline machine is a normal
#   state, not an error, and the bar has to stay responsive on one.
#
# Output is a JSON array, so it can be read straight out of a Process stdout:
#
#   [{"id":"omarchy.foo","behind":true,"commits":2},
#    {"id":"omarchy.bar","behind":false,"commits":0},
#    {"id":"omarchy.baz","behind":null}]
#
# An empty install — or none at all — is `[]`, not an error. Callers should never
# have to distinguish "nothing to update" from "could not check", which is
# exactly why `null` is a value of `behind` rather than a fourth field.

# No -e: a failing fetch on one plugin is an expected outcome to report, not a
# reason to abandon the rest.
set -uo pipefail

PLUGINS_DIR="${BETTER_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}"

# Seconds a single fetch may take. Long enough for a slow link on a big repo,
# short enough that a dead host cannot stall the bar behind it.
FETCH_TIMEOUT="${BETTER_PLUGIN_FETCH_TIMEOUT:-8}"

usage() {
    cat >&2 <<'EOF'
Usage: plugin-updates.sh [-h]

Report which installed git-managed plugins are behind their remote.
Read-only: never fetches into the working tree, never merges, never resets.

    -h, --help   show this
EOF
    exit 0
}

while (($# > 0)); do
    case "$1" in
    -h | --help)
        usage
        ;;
    -*)
        printf 'plugin-updates.sh: unknown option: %s\n' "$1" >&2
        exit 1
        ;;
    *)
        printf 'plugin-updates.sh: unexpected argument: %s\n' "$1" >&2
        exit 1
        ;;
    esac
done

# No install at all is an empty report, not a failure.
[[ -d $PLUGINS_DIR ]] || { printf '[]\n'; exit 0; }

# Built a record at a time and joined at the end, so the output stays valid no
# matter how many plugins there are — and a single bad id can never splice
# itself into the JSON. jq does the quoting, so a plugin directory with
# quotes or backslashes in its name cannot break the document.
TMP=$(mktemp "${TMPDIR:-/tmp}/better-plugin-updates.XXXXXX")
trap 'rm -f "$TMP"' EXIT

for dir in "$PLUGINS_DIR"/*/; do
    [[ -d $dir ]] || continue
    # Only git-managed plugins have a remote to be behind. A plugin cloned from
    # a built-in one, or installed by hand, is upstream-managed by nobody and
    # would otherwise be reported as up to date forever — a silent lie.
    [[ -d ${dir}/.git ]] || continue

    id=$(basename "$dir")
    # Same guard the updater uses. A name outside this shape is not a plugin
    # this script can safely name in shell or JSON.
    [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id != *..* ]] || continue

    behind=null
    commits=null

    # Time-boxed so an unreachable remote costs a bounded wait and nothing more.
    # `timeout` is not guaranteed everywhere; without it we still work, just
    # without the ceiling.
    if command -v timeout >/dev/null 2>&1; then
        timeout "$FETCH_TIMEOUT" git -C "$dir" fetch --quiet origin HEAD >/dev/null 2>&1
    else
        git -C "$dir" fetch --quiet origin HEAD >/dev/null 2>&1
    fi

    if (($? == 0)); then
        # A read against the ref the fetch just named. FETCH_HEAD is per-repo
        # and this loop only ever touches one repo at a time, so there is no
        # interleaving to guard against.
        head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
        remote=$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null)
        if [[ -n $head && -n $remote ]]; then
            if [[ $head == "$remote" ]]; then
                behind=false
                commits=0
            else
                behind=true
                commits=$(git -C "$dir" rev-list --count "$head..$remote" 2>/dev/null || echo 0)
            fi
        fi
    fi

    jq -nc --arg id "$id" --arg behind "$behind" --arg commits "$commits" \
        '{ id: $id,
           behind: (if $behind == "null" then null else ($behind == "true") end),
           commits: (if $commits == "null" then null else ($commits | tonumber) end) }' \
        >>"$TMP"
done

# Join the newline-delimited records into one array, always emitting valid JSON.
jq -s '.' "$TMP" 2>/dev/null || printf '[]\n'
