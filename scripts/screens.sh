#!/usr/bin/env bash
set -euo pipefail

# Translates a Better Bar "Screens" layout JSON into Hyprland monitor commands
# and ships them in ONE `hyprctl --batch` round trip -- one `keyword monitor`
# line per screen, in a single dispatcher call -- then parks the accepted
# layout as last-good so the surface can always recover from a bad apply.
#
# The batch is the PRIMARY transport. When the compositor rejects it -- a
# Hyprland build that dropped the legacy `monitor` keyword -- the very same
# layout is re-sent through `hyprctl eval` with the Lua `hl.monitor` API, so a
# modern build still gets its layout. The comma spec is identical in both.
#
# Called by the surface (stdin) and by `screensrescue` (the rescue IPC). The two
# share `apply_from_json` so the comma spec -- the one thing the surface and the
# model singleton must agree on -- lives in exactly one place.
#
# Schema (pinned by the plan, do not drift):
# { "version":1, "screens":[
#   { "output":"desc:MAKE MODEL", "mode":"1920x1080@100",
#     "position":"0x0", "scale":1, "transform":0, "mirror":"", "enabled":true } ] }
#
# Honoured exactly like wallpaper.sh does, so a stubbed XDG_STATE_HOME in tests
# lands last-good in the sandbox instead of touching the user's real state.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/better"
last_good="$state_dir/screens-last-good.json"

# The jq programs that flatten a layout into one record per screen.
#
# The fields are joined with US (0x1f), NOT with TAB: TAB is an IFS
# *whitespace* character, so bash collapses runs of it and every field after
# an empty one shifts left -- an empty mode turned into a position, a position
# into a scale, a scale into the transform. US is not whitespace, so an empty
# field stays an empty field and the spec keeps its positions.
#
# Values are stripped of CR/LF on the way in: a newline inside a mode or an
# output name would split the record here and inject a second `keyword ...`
# command into the batch later on.
JQ_APPLY='
def txt: if type == "string" then gsub("[\r\n]"; " ") else "" end;
def num($d):
    if type == "number" then .
    elif type == "string" then
        (if test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber else $d end)
    else $d end;
if type != "object" then error("layout is not an object")
elif (.screens | type) != "array" then error("layout has no screens array")
else .screens end
| .[]
| select(.output != null and .output != "")
| [ (.output | txt),
    (if .enabled then 1 else 0 end),
    (.mode // "" | txt),
    (.position // "" | txt),
    (.scale | num(1)),
    (.transform | num(0) | round),
    (.mirror // "" | txt) ]
| join("\u001f")'

JQ_PERSIST='
def txt: if type == "string" then gsub("[\r\n]"; " ") else "" end;
def num($d):
    if type == "number" then .
    elif type == "string" then
        (if test("^-?[0-9]+(\\.[0-9]+)?$") then tonumber else $d end)
    else $d end;
if type != "object" then error("layout is not an object")
elif (.screens | type) != "array" then error("layout has no screens array")
else .screens end
| .[]
| select(.output != null and .output != "")
| [ (.output | txt),
    (.mode // "" | txt),
    (.position // "" | txt),
    (.scale | num(1)) ]
| join("\u001f")'

# Strip CR/LF from a value that is about to be interpolated into a comma
# separated command string: a newline would end the command line and let the
# rest of the value inject a second `keyword ...` command into the batch.
spec_safe() {
    local s="$1"
    s="${s//$'\r'/ }"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# Escape a value for a Lua string literal. A bare `"` ends the literal and
# turns the rest of the payload into a syntax error -- a silent fallback to the
# batch path -- so backslashes and quotes are escaped, and the line breaks that
# cannot appear in a Lua literal at all become \r / \n escapes.
lua_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Apply one layout blob ($1 = raw JSON) through Hyprland.
#
# $2 = "1" persists the accepted layout as last-good (the `apply` path); "0"
# applies the layout and touches nothing else -- the `rescue` path, where the
# parked layout already IS the good state and re-parking it would be a lie.
#
# The layout is NEVER written to monitors.lua here: that is the explicit
# `persist` command, so an apply cannot silently rewrite the boot config, and
# cannot leave a new monitors.lua.bak.<epoch> behind on every keystroke.
#
# Returns non-zero on refuse or compositor rejection, without leaving a
# half-applied layout behind.
apply_from_json() {
    local layout="$1" persist="${2:-0}"
    local rows batch="" lua_cmds="" enabled_count=0
    local out en mode pos scale tr mirror spec cmd args

    # A layout that is not JSON is not a layout without screens: say so, so the
    # user is not told the (perfectly valid) refusal story about a typo.
    if ! rows=$(printf '%s' "$layout" | jq -r "$JQ_APPLY" 2>/dev/null); then
        printf 'better-screens: invalid layout JSON\n' >&2
        return 1
    fi

    while IFS=$'\x1f' read -r out en mode pos scale tr mirror; do
        [ -z "$out" ] && continue
        # Belt and braces: the jq already stripped CR/LF, but nothing that
        # reaches the batch may be able to end the command line.
        out=$(spec_safe "$out")
        mode=$(spec_safe "$mode")
        pos=$(spec_safe "$pos")
        mirror=$(spec_safe "$mirror")
        if [ "$en" = "1" ]; then
            enabled_count=$((enabled_count + 1))
            spec="$out,$mode,$pos,$scale,transform,${tr:-0}"
            # The Lua payload carries the same fields as the comma spec, with
            # the values escaped: an output name with a quote in it must not
            # break the literal.
            args="output = \"$(lua_escape "$out")\""
            if [ -n "$mode" ]; then
                args="$args, mode = \"$(lua_escape "$mode")\""
            fi
            if [ -n "$pos" ]; then
                args="$args, position = \"$(lua_escape "$pos")\""
            fi
            args="$args, scale = $scale"
            if [ -n "$tr" ] && [ "$tr" != "0" ]; then
                args="$args, transform = $tr"
            fi
            if [ -n "$mirror" ]; then
                spec="$spec,mirror,$mirror"
                args="$args, mirror = \"$(lua_escape "$mirror")\""
            fi
            lua_cmds="${lua_cmds}hl.monitor({ $args }); "
        else
            spec="$out,disable"
            lua_cmds="${lua_cmds}hl.monitor({ output = \"$(lua_escape "$out")\", disabled = true }); "
        fi
        cmd="keyword monitor $spec"
        if [ -z "$batch" ]; then
            batch="$cmd"
        else
            batch="$batch"$'\n'"$cmd"
        fi
    done <<< "$rows"

    if [ "$enabled_count" -eq 0 ]; then
        printf 'better-screens: refused -- layout has no enabled screen\n' >&2
        return 1
    fi

    # The batch is the primary transport: one synchronous dispatcher round trip
    # for every screen, which is both the perf win and the reason a partial
    # failure cannot abort the other monitors mid-batch. The Lua eval is the
    # fallback for a Hyprland that no longer knows the legacy `monitor`
    # keyword -- the same layout, the same specs.
    local applied=0
    if hyprctl --batch "$batch" >/dev/null 2>&1; then
        applied=1
    elif [ -n "$lua_cmds" ] && hyprctl eval "${lua_cmds} return 0" >/dev/null 2>&1; then
        applied=1
    fi

    if [ "$applied" -eq 0 ]; then
        printf 'better-screens: apply failed -- hyprctl rejected configuration\n' >&2
        return 1
    fi
    # Only the accepted layout becomes last-good, so a rejected apply can never
    # paper over itself: rescue replays the last thing that actually took. A
    # failed park is a failed apply -- swallowing it would leave the surface
    # reporting a success it cannot recover from.
    if [ "$persist" = "1" ]; then
        if ! mkdir -p "$state_dir"; then
            printf 'better-screens: cannot create %s -- layout not parked as last-good\n' "$state_dir" >&2
            return 1
        fi
        if ! printf '%s' "$layout" > "$last_good.tmp"; then
            rm -f "$last_good.tmp" 2>/dev/null || true
            printf 'better-screens: cannot write %s -- layout not parked as last-good\n' "$last_good" >&2
            return 1
        fi
        if ! mv -f "$last_good.tmp" "$last_good"; then
            rm -f "$last_good.tmp" 2>/dev/null || true
            printf 'better-screens: cannot park %s -- layout not saved as last-good\n' "$last_good" >&2
            return 1
        fi
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
#
# This is the ONLY thing that touches the boot config: `apply` and `rescue`
# leave monitors.lua alone, so a keystroke in the surface cannot rewrite it.
persist_to_lua() {
    local file="${MONITORS_LUA:-$HOME/.config/hypr/monitors.lua}"
    local layout_json rows
    layout_json="$(cat)"
    [ -n "$layout_json" ] || { printf 'better-screens: no layout on stdin\n' >&2; return 1; }
    # The file check comes after the stdin check: "no layout" is the reason the
    # caller gave us nothing to write, "no monitors.lua" is the reason we
    # cannot write it. Both are worth saying -- this runs only when the user
    # explicitly asked to persist.
    [ -f "$file" ] || { printf 'better-screens: no monitors.lua at %s\n' "$file" >&2; return 1; }
    if ! rows=$(printf '%s' "$layout_json" | jq -r "$JQ_PERSIST" 2>/dev/null); then
        printf 'better-screens: invalid layout JSON\n' >&2
        return 1
    fi
    [ -n "$rows" ] || { printf 'better-screens: layout has no screens to persist\n' >&2; return 1; }

    # One timestamped backup BEFORE any write. If the directory is read-only this
    # fails fast and the file is never touched -- the safety test relies on that
    # ordering.
    #
    # The stamp is nanosecond precise on purpose: with a plain second stamp two
    # writes in the same second land on the same backup name and the second
    # one overwrites the first -- losing the pristine copy of the file the
    # rollback needs. The fallback (a date without %N) is unique but coarse.
    local stamp backup
    stamp="$(date +%s%N 2>/dev/null)"
    case "$stamp" in
        '' | *[!0-9]*) stamp="$(date +%s).$$" ;;
    esac
    backup="$file.bak.$stamp"
    cp -a "$file" "$backup" \
        || { printf 'better-screens: cannot back up %s (read-only?)\n' "$file" >&2; return 1; }

    local tmp="$file.tmp.$$"
    # One awk pass rewrites every screen's block (the layout is small; this is
    # not the hot apply path). SCREENS carries the records (US separated) and
    # TARGET the file to rewrite; both go through the environment so no quoting
    # question can change a value (an awk -v assignment would eat backslashes
    # in a path). SIZE, the file's byte count, goes in through -v because it is
    # a plain number. LC_ALL=C keeps awk byte oriented, which is what the byte
    # count is compared against.
    #
    # The awk program is plain POSIX awk on purpose: `gensub` is a gawk
    # extension and /usr/bin/awk is mawk on Debian/Ubuntu, where a gawk-only
    # rewrite failed and the file was restored from the backup -- a persist
    # that never worked there.
    local size
    size="$(wc -c < "$file" | tr -d ' ')"
    if ! LC_ALL=C SCREENS="$rows" TARGET="$file" awk -v size="$size" '
        BEGIN {
            # The file is read through TARGET, not FILENAME: inside a BEGIN
            # action FILENAME is still empty.
            target = ENVIRON["TARGET"]
            text = ""
            while ((getline line < target) > 0) {
                text = text line "\n"
            }
            close(target)
            # A file whose last line has no newline of its own got one from
            # the read above; the byte count says so, so take it back off.
            if (size + 0 > 0 && length(text) > size + 0) {
                text = substr(text, 1, length(text) - 1)
            }
            nb = split(ENVIRON["SCREENS"], lines, "\n")
            for (i = 1; i <= nb; i++) {
                if (lines[i] == "") continue
                if (split(lines[i], f, "\037") < 4) continue
                text = apply_screen(text, f[1], f[2], f[3], f[4])
            }
            printf "%s", text
            exit
        }
        # Locate the hl.monitor({ ... }) block for this output and rewrite its
        # mode/position/scale in place; append a block if the output is unknown.
        function apply_screen(text, out, mode, pos, scl,
                              pat, p, start, rest, cb, head, block, tail) {
            pat = "output[[:space:]]*=[[:space:]]*\"" re_escape(out) "\""
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
            # A block whose mode/position/scale could not all be substituted is
            # left exactly as it was: the oracle refuses the whole screen in
            # that case, and a half rewritten block is worse than none.
            if (block == "") return text
            return head block tail
        }
        # Twin of lib/monitors.js replaceField: keep the "name = " prefix (with
        # its original spacing), swap only the value (a quoted string or a bare
        # token up to the next , / } / newline). Returns "" when the field is
        # not in the block at all -- the caller reads that as "leave it alone".
        function sub_field(b, name, val,   pat, p, vend, tail, c, q) {
            pat = name "[[:space:]]*=[[:space:]]*"
            p = match(b, pat)
            if (p == 0) return ""
            vend = p + RLENGTH
            c = substr(b, vend, 1)
            if (c == "\"") {
                q = index(substr(b, vend + 1), "\"")
                if (q > 0) {
                    tail = vend + q + 1
                } else {
                    tail = bare_run_end(b, vend)
                }
            } else {
                tail = bare_run_end(b, vend)
            }
            return substr(b, 1, vend - 1) val substr(b, tail)
        }
        # End of a bare (unquoted) value: it runs up to the next , } or newline.
        function bare_run_end(b, from,   n, i, ch) {
            n = length(b)
            i = from
            while (i <= n) {
                ch = substr(b, i, 1)
                if (ch == "," || ch == "}" || ch == "\n") break
                i++
            }
            return i
        }
        # Twin of lib/monitors.js replaceField applied to the three fields the
        # oracle writes; a field that is not there fails the whole block.
        function rewrite_block(b, mode, pos, scl,   r) {
            r = sub_field(b, "mode", "\"" mode "\"")
            if (r == "") return ""
            r = sub_field(r, "position", "\"" pos "\"")
            if (r == "") return ""
            r = sub_field(r, "scale", scl)
            if (r == "") return ""
            return r
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
        # Escape a value for use inside an awk regex -- the same job
        # lib/monitors.js escapeRe does for the oracle.
        function re_escape(s,   out, i, c) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "." || c == "[" || c == "]" || c == "{" || c == "}" ||
                    c == "(" || c == ")" || c == "*" || c == "+" || c == "?" ||
                    c == "^" || c == "$" || c == "|" || c == "\\") {
                    out = out "\\" c
                } else {
                    out = out c
                }
            }
            return out
        }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        cp -a "$backup" "$file" 2>/dev/null || true
        printf 'better-screens: persist rewrite failed\n' >&2
        return 1
    fi

    # Safety net: a persist that produced no hl.monitor( would brick boot. The
    # awk always rewrites or appends, so this should never trip -- but if it does,
    # roll back rather than write a broken file.
    if ! grep -q 'hl\.monitor(' "$tmp"; then
        rm -f "$tmp"
        cp -a "$backup" "$file" 2>/dev/null || true
        printf 'better-screens: persist produced no hl.monitor block\n' >&2
        return 1
    fi

    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp" 2>/dev/null || true
        cp -a "$backup" "$file" 2>/dev/null || true
        printf 'better-screens: persist could not replace %s\n' "$file" >&2
        return 1
    fi
    # Keep the backup history bounded: the newest five survive, the rest go.
    # Without this every persist left another monitors.lua.bak.<epoch> behind
    # and the directory grew without bound.
    local kept=0 b
    for b in "$file".bak.*; do
        [ -e "$b" ] || continue
        kept=$((kept + 1))
        if [ "$kept" -gt 5 ]; then
            rm -f -- "$b"
        fi
    done
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
        # Re-apply the parked layout with the same path. We do not rewrite
        # last-good here -- it is already the good state by definition -- and
        # we do not touch monitors.lua either: a rescue restores the screen,
        # it does not rewrite the boot config.
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
