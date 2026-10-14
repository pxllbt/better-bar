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

# Persist a layout to monitors.lua, rewriting each output's own hl.monitor({...})
# block in place or appending a fresh one for unknown outputs. The transform is
# a byte-for-byte twin of lib/monitors.js setMonitor/appendMonitor -- the test-
# only oracle the plan pins -- so this writer and the oracle can never drift; the
# writer test diffs them, byte for byte. Like the oracle, it writes mode,
# position and scale (transform/mirror are applied live by `apply` and are not
# persisted to the boot config; see task-2-report.md).
persist_to_lua() {
    local file="${MONITORS_LUA:-$HOME/.config/hypr/monitors.lua}"
    [ -f "$file" ] || { printf 'better-screens: no monitors.lua at %s\n' "$file" >&2; return 1; }
    local layout_json tsv
    layout_json="$(cat)"
    [ -n "$layout_json" ] || { printf 'better-screens: no layout on stdin\n' >&2; return 1; }
    tsv=$(printf '%s' "$layout_json" | jq -r '
        .screens[]?
        | select(.output != null and .output != "")
        | [ (.output // ""), (.mode // "preferred"), (.position // "auto"), (.scale // 1) ]
        | @tsv' 2>/dev/null) || tsv=""
    [ -n "$tsv" ] || { printf 'better-screens: layout has no screens to persist\n' >&2; return 1; }

    # One timestamped backup BEFORE any write. If the directory is read-only this
    # fails fast and the file is never touched -- the safety test relies on that
    # ordering.
    local backup="$file.bak.$(date +%s)"
    cp -a "$file" "$backup" \
        || { printf 'better-screens: cannot back up %s (read-only?)\n' "$file" >&2; return 1; }

    local tmp="$file.tmp.$$"
    # Process every screen in one awk pass (the layout is small; this is not the
    # hot apply path). SCREENS is passed via the environment so jq's @tsv tabs and
    # newlines survive unescaped into awk.
    SCREENS="$tsv" awk '
        BEGIN { RS = "\0"; ORS = "" }
        {
            text = $0
            nb = split(ENVIRON["SCREENS"], lines, "\n")
            for (i = 1; i <= nb; i++) {
                if (lines[i] == "") continue
                if (split(lines[i], f, "\t") < 4) continue
                text = apply_screen(text, f[1], f[2], f[3], f[4])
            }
            printf "%s", text
        }
        # Locate the hl.monitor({ ... }) block for this output and rewrite its
        # mode/position/scale in place; append a block if the output is unknown.
        function apply_screen(text, out, mode, pos, scl,
                              pat, p, start, rest, cb, head, block, tail) {
            pat = "output[[:space:]]*=[[:space:]]*\"" out "\""
            p = match(text, pat)
            if (p == 0) return text append_block(out, mode, pos, scl)
            start = find_block_start(text, p)
            if (start == 0 || start > p) return text
            rest = substr(text, start)
            cb = index(rest, "})")
            if (cb == 0) return text
            # Build the three slices on their own lines (a newline after a bare
            # identifier terminates the statement in gawk, even inside parens, so
            # multi-line `a _ b _ c` is unsafe) and concatenate them in a single
            # return.
            head = substr(text, 1, start - 1)
            block = rewrite_block(substr(rest, 1, cb + 1), mode, pos, scl)
            tail = substr(rest, cb + 2)
            return head block tail
        }
        # Twin of lib/monitors.js replaceField: keep the "name = " prefix (with
        # its original spacing), swap only the value (a quoted string or a bare
        # token up to the next , / }).
        function rewrite_block(b, mode, pos, scl) {
            b = sub_field(b, "mode", "\"" mode "\"")
            b = sub_field(b, "position", "\"" pos "\"")
            b = sub_field(b, "scale", scl)
            return b
        }
        function sub_field(b, name, val) {
            return gensub("(" name "[[:space:]]*=[[:space:]]*)(\"[^\"]*\"|[^,}]*)",
                          "\\1" val, "1", b)
        }
        # Twin of lib/monitors.js appendMonitor field layout (aligned, four-space
        # indent, trailing comma before the close).
        function append_block(o, m, p, s) {
            return "\nhl.monitor({\n    output   = \"" o "\",\n    mode     = \"" m "\",\n    position = \"" p "\",\n    scale    = " s ",\n})\n"
        }
        # Last "hl.monitor({" at or before the output match -- its enclosing open.
        function find_block_start(text, p,   idx, s, last, cand) {
            last = 0; s = 1
            while ((idx = index(substr(text, s), "hl.monitor({")) > 0) {
                cand = s + idx - 1
                if (cand > p) break
                last = cand; s = cand + 1
            }
            return last
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; cp -a "$backup" "$file" 2>/dev/null || true; printf 'better-screens: persist rewrite failed\n' >&2; return 1; }

    # Safety net: a persist that produced no hl.monitor( would brick boot. The
    # awk always rewrites or appends, so this should never trip -- but if it does,
    # roll back rather than write a broken file.
    if ! grep -q 'hl\.monitor(' "$tmp"; then
        rm -f "$tmp"
        cp -a "$backup" "$file" 2>/dev/null || true
        printf 'better-screens: persist produced no hl.monitor block\n' >&2
        return 1
    fi

    mv -f "$tmp" "$file"
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
    persist)
        # persist_to_lua reads the layout JSON from stdin and rewrites
        # MONITORS_LUA in place.
        persist_to_lua || exit 1
        ;;
    *)
        printf 'usage: screens.sh {apply|persist|rescue}\n' >&2
        exit 2
        ;;
esac
