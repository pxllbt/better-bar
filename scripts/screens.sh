#!/usr/bin/env bash
set -euo pipefail

# Translates a Better Bar "Screens" layout JSON into Hyprland monitor commands
# and ships them in ONE `hyprctl --batch` round trip, then parks the accepted
# layout as last-good so the surface can always recover from a bad apply.
#
# Called by the surface (stdin) and by `screensrescue` (the rescue IPC). The two
# share `apply_from_json` so the comma spec -- the one thing the surface and the
# model singleton must agree on -- lives in exactly one place.
#
# Schema (pinned by the plan, do not drift):
# { "version":1, "screens":[
#   { "output":"desc:MAKE MODEL", "mode":"1920x1080@100",
#     "position":"0x0", "scale":1, "transform":0, "mirror":"", "enabled":true } ] }

# Honoured exactly like wallpaper.sh does, so a stubbed XDG_STATE_HOME in tests
# lands last-good in the sandbox instead of touching the user's real state.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/better"
last_good="$state_dir/screens-last-good.json"

# Apply one layout blob ($1 = raw JSON) through Hyprland. When $2 == "1" the
# blob is also parked as last-good on success. Returns non-zero on refuse or
# compositor rejection, without leaving a half-applied layout behind.
apply_from_json() {
    local layout="$1" persist="${2:-0}"
    local batch="" enabled_count=0 out en mode pos scale tr mirror spec cmd

    # One jq pass over the JSON, one tab-separated line per screen -- never jq
    # per screen. Screens with an empty/missing `output` are filtered here: a
    # spec with no target carries no output and would at best be a no-op, at
    # worst a Hyprland parse error, so they are dropped before the loop.
    while IFS=$'\t' read -r out en mode pos scale tr mirror; do
        [ -z "$out" ] && continue
        mirror="${mirror:-}"
        if [ "$en" = "1" ]; then
            enabled_count=$((enabled_count + 1))
            # Tagged-token form the legacy `monitor` keyword expects:
            # <output>,<mode>,<position>,<scale>,transform,<n>[,mirror,<target>]
            spec="$out,$mode,$pos,$scale,transform,${tr:-0}"
            if [ -n "$mirror" ]; then
                spec="$spec,mirror,$mirror"
            fi
        else
            # `disable` is the token Hyprland's monitor keyword uses to drop an
            # output from the layout; mode/position/scale are meaningless then.
            spec="$out,disable"
        fi
        cmd="keyword monitor $spec"
        if [ -z "$batch" ]; then
            batch="$cmd"
        else
            batch="$batch"$'\n'"$cmd"
        fi
    done < <(printf '%s' "$layout" \
        | jq -r '
            .screens[]?
            | select(.output != null and .output != "")
            | [ (.output // ""),
                (if .enabled then 1 else 0 end),
                (.mode    // "preferred"),
                (.position // "auto"),
                (.scale   // 1),
                (.transform // 0),
                (.mirror  // "") ]
            | @tsv' 2>/dev/null) || true

    # Refuse before the first compositor call: a layout with no enabled screen
    # blanks the desktop, and turning off the last monitor is almost always a
    # drag mistake, not a choice. hyprctl is never invoked, so the stub/log in
    # tests stays empty on refusal.
    if [ "$enabled_count" -eq 0 ]; then
        printf 'better-screens: refused -- layout has no enabled screen\n' >&2
        return 1
    fi

    # One synchronous dispatcher round trip for every screen (the wiki warns
    # that each hyprctl call is synchronous, so batching is a real perf win and
    # also means a partial failure does not abort the other monitors mid-batch).
    if ! hyprctl --batch "$batch"; then
        printf 'better-screens: apply failed -- hyprctl rejected the batch\n' >&2
        return 1
    fi

    # Only the accepted layout becomes last-good, so a rejected apply can never
    # paper over itself: rescue replays the last thing that actually took.
    if [ "$persist" = "1" ]; then
        mkdir -p "$state_dir"
        printf '%s' "$layout" > "$last_good.tmp"
        mv -f "$last_good.tmp" "$last_good"
    fi
    return 0
}

cmd="${1:-}"
case "$cmd" in
    apply)
        # Slurp stdin once. The raw JSON is what gets parked as last-good, so it
        # is read verbatim rather than round-tripped through jq and risk a
        # whitespace/ordering diff.
        layout_json="$(cat)"
        if [ -z "$layout_json" ]; then
            printf 'better-screens: refused -- no layout on stdin\n' >&2
            exit 1
        fi
        apply_from_json "$layout_json" 1 || exit 1
        ;;
    rescue)
        [ -f "$last_good" ] \
            || { printf 'better-screens: no last-good layout to rescue\n' >&2; exit 1; }
        # Re-apply the parked layout with the same single-batch path. We do not
        # rewrite last-good here -- it is already the good state by definition.
        apply_from_json "$(cat "$last_good")" 0 || exit 1
        ;;
    *)
        printf 'usage: screens.sh {apply|rescue}\n' >&2
        exit 2
        ;;
esac
