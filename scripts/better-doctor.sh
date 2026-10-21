#!/usr/bin/env bash
# Better Bar Diagnostic & Self-Repair Engine
#
# One command that tells the truth about the bar: whether it is running, whether
# the desktop it draws on is intact, and whether the source tree it was built
# from still agrees with itself.
#
# The engine this replaces reported "All systems healthy! (0 issues detected)" on
# a tree that had eight failing test suites, a singleton that was never
# registered, a settings-search entry pointing at a surface that had been
# deleted, and a CI file pointing at a test that had been deleted. It checked
# LIVENESS -- is the process up, is the layer mapped, is awww running -- and
# called that health. Liveness is the easy half. The half that actually bit was
# AGREEMENT: between the tree and its own registry, and between the tree and
# the machine it is installed on. A bar can be perfectly alive and still be
# broken in nine ways at once.
#
# So the checks come in two kinds, and both have to pass:
#
#   RUNTIME  the live session -- process topology, layer-shell surfaces, the
#            wallpaper daemon and the data it paints, the monitor layout.
#   STATIC   the source tree -- the QML integrity gate, qmldir registration
#            drift, the surface registry, script syntax, the settings-flag
#            schema, and the project's own test suite.
#
# Every check records a status and a message, and the report is emitted in a
# FIXED order. The previous version iterated a bash associative array, so the
# order changed from run to run -- and a report you cannot diff against last
# week's report is not a report.
#
# Usage:
#   better-doctor.sh            everything that is cheap
#   better-doctor.sh --deep     also the full test suite and the live
#                                omarchy-shell load test
#   better-doctor.sh --fix      repair what can be repaired
#   better-doctor.sh --json     machine-readable status
#   better-doctor.sh --report   sanitized Markdown for a GitHub issue
set -uo pipefail

DO_FIX=false
DO_JSON=false
DO_REPORT=false
DO_DEEP=false
STATIC_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --fix) DO_FIX=true ;;
        --json) DO_JSON=true ;;
        --report) DO_REPORT=true ;;
        --deep) DO_DEEP=true ;;
        --static) STATIC_ONLY=true ;;
        -h|--help)
            echo "Usage: better-doctor.sh [--fix] [--json] [--report] [--deep] [--static]"
            echo "  --fix     Automatically repair detected issues (kill duplicate bars, start daemons, fix symlinks)"
            echo "  --json    Emit machine-readable JSON status"
            echo "  --report  Emit sanitized Markdown summary for GitHub issues"
            echo "  --deep    Also run the full test suite and the live omarchy-shell load test"
            echo "  --static  Only the checks that read the source tree -- no live session, no suite."
            echo "            This is the mode CI runs: a checkout on a build agent has no"
            echo "            bar, no compositor and no wallpaper, so the runtime checks"
            echo "            would report a broken machine that is actually fine."
            exit 0
            ;;
        *) echo "better-doctor: unknown option '$arg'" >&2; exit 2 ;;
    esac
done

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OMARCHY_PLUGIN_DIR="${HOME}/.config/omarchy/plugins/pix.bar"
STANDALONE_DIR="${HOME}/.local/share/quickshell/better"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
FLAGS_FILE="$STATE_DIR/better/flags.json"

ISSUES=0
FIXED=0

# The report order is the order these are appended, never the order of a hash
# table. Two runs over the same tree must produce byte-identical reports, or
# "what changed since last time" is unanswerable.
ORDER=()
declare -A RESULTS
declare -A STATUS

record() {
    local key="$1" status="$2" msg="$3"
    ORDER+=("$key")
    RESULTS["$key"]="$msg"
    STATUS["$key"]="$status"
    case "$status" in
        FAIL|WARN) ISSUES=$((ISSUES + 1)) ;;
        FIXED) FIXED=$((FIXED + 1)) ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# 0. Dependencies.
#
# The old engine called `jq` and `hyprctl` without ever checking they were
# installed. Both were wrapped in `2>/dev/null || echo ""`, so a missing jq did
# not fail the check -- it made the check read EMPTY, which reads as "no
# problem found". A diagnostic that goes quiet when its tools are missing is
# worse than no diagnostic, because it reports success.
# ---------------------------------------------------------------------------
MISSING_DEPS=""
for dep in jq python3; do
    have "$dep" || MISSING_DEPS="$MISSING_DEPS $dep"
done
# hyprctl is only used by the RUNTIME checks, and --static does not run
# them. A checkout on a build agent has no compositor, so asking it for
# hyprctl there reported a missing tool as a problem with the machine --
# and the doctor counts a WARN as an issue, so it failed CI over a tool
# that CI does not need and cannot have.
if [ "$STATIC_ONLY" = false ]; then
    have hyprctl || MISSING_DEPS="$MISSING_DEPS hyprctl"
fi
if [ -n "$MISSING_DEPS" ]; then
    record "dependencies" "WARN" "missing tool(s):$MISSING_DEPS -- some checks below cannot answer"
else
    record "dependencies" "PASS" "jq, hyprctl, python3 all present"
fi

HAVE_JQ=false
have jq && HAVE_JQ=true

# ---------------------------------------------------------------------------
# The runtime sections (1-5) read the live session. In --static mode they are
# skipped entirely: a checkout on a build agent has no bar, no compositor and
# no wallpaper, so asking it about those things reports a broken machine that
# is actually fine -- and a gate that cries wolf is a gate nobody trusts.
# ---------------------------------------------------------------------------
# Defaults, so the summary block below can report them even when the runtime
# checks were skipped.
bar_count=0
watcher_running=false
awww_running=false
layers_ok=false

if [ "$STATIC_ONLY" = false ]; then

# ---------------------------------------------------------------------------
# 1. Process Topology
#
# `ps` and the count are separate reads, so a bar that exits in between is still
# listed. Counting it would report a duplicate for a bar that is already gone --
# and a doctor that cries wolf gets ignored on the runs that matter, so each pid
# is re-checked against /proc before it counts.
# ---------------------------------------------------------------------------
# The bar is not always a process of its own: as an Omarchy plugin it is
# hosted by the omarchy shell, and as a standalone install it is a quickshell
# serving this directory. Both count as "the bar". A quickshell serving
# something else -- another app, a scratch config -- does not, and counting it
# would report duplicates on a desktop that has exactly one bar.
OMARCHY_SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
bar_pids=()
while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ -d "/proc/$pid" ] || continue
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
    case "$cmdline" in
        *"$OMARCHY_SHELL_DIR"*|*"$INSTALL_DIR"*) bar_pids+=("$pid") ;;
    esac
done < <(ps -eo pid,args 2>/dev/null | grep -E "[q]uickshell" | awk '{print $1}')

bar_count=${#bar_pids[@]}
watcher_running=false
if pgrep -f "better-watch" >/dev/null 2>&1; then
    watcher_running=true
fi

if [ "$bar_count" -eq 1 ]; then
    record "processes" "PASS" "1 instance, pid ${bar_pids[0]}"
elif [ "$bar_count" -eq 0 ]; then
    record "processes" "FAIL" "0 instances running"
    if [ "$DO_FIX" = true ] && [ -x "$INSTALL_DIR/scripts/better-watch" ]; then
        nohup "$INSTALL_DIR/scripts/better-watch" >/dev/null 2>&1 &
        record "processes" "FIXED" "started the better-watch supervisor"
    fi
else
    record "processes" "FAIL" "$bar_count duplicate instances: ${bar_pids[*]}"
    if [ "$DO_FIX" = true ]; then
        # Keep the watcher-managed one if available, otherwise keep the first
        keeper="${bar_pids[0]}"
        for pid in "${bar_pids[@]}"; do
            ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || echo "")
            if [ -n "$ppid" ] && grep -q "better-watch" "/proc/$ppid/cmdline" 2>/dev/null; then
                keeper="$pid"
                break
            fi
        done
        for pid in "${bar_pids[@]}"; do
            if [ "$pid" != "$keeper" ]; then
                kill "$pid" 2>/dev/null || true
                FIXED=$((FIXED + 1))
            fi
        done
        record "processes" "FIXED" "kept pid $keeper, terminated duplicates"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Layer-Shell Surface Health
# ---------------------------------------------------------------------------
layers_ok=false
if have hyprctl; then
    layer_output=$(hyprctl layers 2>/dev/null || echo "")
    if echo "$layer_output" | grep -q "namespace: better"; then
        layers_ok=true
        record "layers" "PASS" "better namespace mapped"
    else
        record "layers" "WARN" "better layer not currently mapped"
    fi

    # Check for colliding background layers covering awww
    if echo "$layer_output" | grep -q "namespace: omarchy-background"; then
        record "background_collision" "FAIL" "omarchy-background layer is mapped, occluding awww wallpaper"
        if [ "$DO_FIX" = true ]; then
            omarchy plugin disable omarchy.background >/dev/null 2>&1 || true
            omarchy plugin disable io.github.prostratepossum.starwatch-background >/dev/null 2>&1 || true
            omarchy restart shell >/dev/null 2>&1 || true
            record "background_collision" "FIXED" "disabled conflicting background plugin and restarted omarchy shell"
            FIXED=$((FIXED + 1))
        fi
    fi
else
    record "layers" "SKIP" "hyprctl not available"
fi

# ---------------------------------------------------------------------------
# 3. Wallpaper Daemon Health
# ---------------------------------------------------------------------------
awww_running=false
if pgrep -x "awww-daemon" >/dev/null 2>&1 || (have hyprctl && hyprctl layers 2>/dev/null | grep -q "namespace: awww-daemon"); then
    awww_running=true
    record "awww" "PASS" "awww-daemon running"
else
    record "awww" "WARN" "awww-daemon not running"
    if [ "$DO_FIX" = true ] && have awww; then
        awww toggle >/dev/null 2>&1 || true
        FIXED=$((FIXED + 1))
        record "awww" "FIXED" "started awww-daemon"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Background Symlink Integrity
# ---------------------------------------------------------------------------
bg_link="$STATE_DIR/omarchy/current/background"
if [ -L "$bg_link" ] || [ -f "$bg_link" ]; then
    resolved_bg=$(readlink -f "$bg_link" 2>/dev/null || echo "")
    if [ -n "$resolved_bg" ] && [ -f "$resolved_bg" ]; then
        record "background_link" "PASS" "$resolved_bg"
    else
        record "background_link" "FAIL" "broken symlink: $bg_link -> $resolved_bg"
        if [ "$DO_FIX" = true ]; then
            theme_bg=$(ls "$STATE_DIR/omarchy/current/theme/backgrounds/"*.{jpg,png,jpeg} 2>/dev/null | head -1 || echo "")
            if [ -n "$theme_bg" ] && [ -f "$theme_bg" ]; then
                ln -nsf "$theme_bg" "$bg_link" 2>/dev/null || true
                FIXED=$((FIXED + 1))
                record "background_link" "FIXED" "repointed to $theme_bg"
            fi
        fi
    fi
else
    record "background_link" "WARN" "no background symlink at $bg_link"
fi

# ---------------------------------------------------------------------------
# 4b. The wallpaper and theme hazards that actually bit this install.
#
# These are not hypothetical. Each one shipped, each one was reported, and each
# one is invisible to the checks above -- none of them touch whether the bar is
# running, whether awww is up, or whether the layer is mapped. They are all
# "the wallpaper is quietly wrong" or "the wallpaper data was destroyed", which
# is exactly the class a doctor that only checks liveness will never see.
# ---------------------------------------------------------------------------
if [ "$HAVE_JQ" = true ]; then
    WPDIR_CFG=$(jq -r '.wallpaperDir // ""' "$FLAGS_FILE" 2>/dev/null || echo "")
else
    WPDIR_CFG=""
fi

# (a) A wallpaperDir inside current/theme. This is the data-loss one: omarchy
# installs a theme with rm -rf + mv, so everything downloaded there -- every
# wallhaven, alphacoders and wallwidgy pick -- is deleted by the next theme
# install. It is the natural setting, which is why it gets chosen.
if [ -n "$WPDIR_CFG" ]; then
    case "$WPDIR_CFG" in
        "$HOME/.local/state/omarchy/current/theme/backgrounds"|*"/.local/state/omarchy/current/theme/backgrounds"|"$HOME/.local/state/omarchy/current/theme/backgrounds/"|*"/.local/state/omarchy/current/theme/backgrounds/")
            record "wallpaper_dir" "PASS" "$WPDIR_CFG [active theme backgrounds]"
            ;;
        "$HOME/.local/state/omarchy/current/"*|*"/.local/state/omarchy/current/"*)
            record "wallpaper_dir" "FAIL" "$WPDIR_CFG is transient -- a theme install deletes every wallpaper in it"
            if [ "$DO_FIX" = true ] && [ "$HAVE_JQ" = true ]; then
                PERM="$HOME/Pictures/Wallpapers"
                mkdir -p "$PERM"
                # Move what is there out rather than deleting it: the wallpapers
                # in that folder are the user's, and the one they are looking at
                # is among them.
                for f in "$WPDIR_CFG"/*; do
                    [ -f "$f" ] || continue
                    cp -p -- "$f" "$PERM/" 2>/dev/null || true
                done
                jq --arg v "$PERM" '.wallpaperDir = $v' "$FLAGS_FILE" > "$FLAGS_FILE.tmp" 2>/dev/null \
                    && mv "$FLAGS_FILE.tmp" "$FLAGS_FILE"
                record "wallpaper_dir" "FIXED" "moved wallpapers to $PERM and repointed"
                FIXED=$((FIXED + 1))
            fi
            ;;
        *)
            record "wallpaper_dir" "PASS" "$WPDIR_CFG"
            ;;
    esac
else
    record "wallpaper_dir" "PASS" "autodetect"
fi

# (b) A theme gallery cache that is missing, or older than the themes it should
# describe. A stale cache is the black-tile bug: the picker paints from it, so a
# new custom theme's colours never arrive and its tile fills with the fallback.
GALLERY="$CACHE_DIR/better/themes.json"
if [ ! -s "$GALLERY" ]; then
    record "theme_gallery" "FAIL" "no gallery cache -- theme tiles will render from fallbacks"
    if [ "$DO_FIX" = true ]; then
        python3 "$INSTALL_DIR/scripts/themes.py" > "$GALLERY" 2>/dev/null \
            && record "theme_gallery" "FIXED" "gallery rebuilt" && FIXED=$((FIXED + 1))
    fi
else
    newest_theme=$(stat -c %Y "$HOME/.config/omarchy/themes" 2>/dev/null || echo 0)
    cache_age=$(stat -c %Y "$GALLERY" 2>/dev/null || echo 0)
    if [ "$newest_theme" -gt "$cache_age" ]; then
        record "theme_gallery" "FAIL" "gallery is older than the themes -- a newly installed theme will show a black tile"
        if [ "$DO_FIX" = true ]; then
            python3 "$INSTALL_DIR/scripts/themes.py" > "$GALLERY" 2>/dev/null \
                && record "theme_gallery" "FIXED" "gallery rebuilt" && FIXED=$((FIXED + 1))
        fi
    else
        record "theme_gallery" "PASS" "cache is current"
    fi
fi

# (c) A colour the gallery would paint black. A TOML value that kept its inline
# comment is not a colour, and QML reads an unparseable colour as opaque black --
# so the tile fills black with an invisible title. Parsing here, not trusting
# the cache, so a theme edited since the cache was built is caught too.
if [ -s "$GALLERY" ]; then
    bad_tiles=$(python3 - "$GALLERY" <<'PY' 2>/dev/null
import json, re, sys
d = json.load(open(sys.argv[1]))
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
bad = [t["name"] for t in d for k in ("bg", "accent", "fg")
       if not HEX.match(str(t.get(k, "")))]
print(",".join(bad[:3]))
PY
)
    if [ -n "$bad_tiles" ]; then
        record "theme_tiles" "FAIL" "these themes paint a black tile: $bad_tiles"
        if [ "$DO_FIX" = true ]; then
            python3 "$INSTALL_DIR/scripts/themes.py" > "$GALLERY" 2>/dev/null \
                && record "theme_tiles" "FIXED" "gallery rebuilt with a colour-validating parser" \
                && FIXED=$((FIXED + 1))
        fi
    else
        record "theme_tiles" "PASS" "every tile colour is a colour"
    fi
fi

# (d) A per-output map entry naming a symlink. -f follows symlinks, so every
# liveness check passes while the target is inside current/theme and that tree is
# about to be replaced -- so the entry names a file that will not exist, and
# restore_all paints the void. This is the black-screen wallpaper.
WPMAP="$STATE_DIR/better-wallpaper-map"
if [ -s "$WPMAP" ]; then
    symlinked=$(cut -f2 "$WPMAP" 2>/dev/null | while read -r p; do
        [ -n "$p" ] && [ -L "$p" ] && printf '%s ' "$p"
    done)
    if [ -n "$symlinked" ]; then
        record "wallpaper_map" "FAIL" "entries name a symlink, so a theme switch strands them: $symlinked"
        if [ "$DO_FIX" = true ]; then
            bash "$INSTALL_DIR/scripts/wallpaper.sh" init >/dev/null 2>&1 || true
            record "wallpaper_map" "FIXED" "re-resolved against the wallpaper script"
            FIXED=$((FIXED + 1))
        fi
    else
        record "wallpaper_map" "PASS" "every entry names a real file"
    fi
fi

# (e) Aww is painting a file that no longer exists. awww keeps reporting the last
# image it was asked for long after that file is deleted, so the desktop is
# blank with every check reporting success. The fix is a re-apply.
if have awww && [ "$HAVE_JQ" = true ]; then
    shown=$(awww query -j 2>/dev/null | jq -r '[.[]?[]?.displaying?.image? // empty] | .[0] // empty' 2>/dev/null)
    if [ -n "$shown" ] && [ ! -f "$shown" ]; then
        record "wallpaper_painted" "FAIL" "the wallpaper on screen is gone: $shown"
        if [ "$DO_FIX" = true ]; then
            bash "$INSTALL_DIR/scripts/wallpaper.sh" set "$shown" --force >/dev/null 2>&1 \
                || bash "$INSTALL_DIR/scripts/wallpaper.sh" init >/dev/null 2>&1 || true
            record "wallpaper_painted" "FIXED" "re-applied from the recorded wallpaper"
            FIXED=$((FIXED + 1))
        fi
    elif [ -z "$shown" ]; then
        record "wallpaper_painted" "WARN" "nothing reported on screen"
    else
        record "wallpaper_painted" "PASS" "$(basename "$shown")"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Screens: the monitor layout's own health. These are the two ways a layout
# breaks silently -- a duplicated output (the last matching block wins at boot,
# so an edit appears to do nothing) and an unparseable file (no layout at all) --
# plus a plain count of what Hyprland actually has right now.
# ---------------------------------------------------------------------------
if have hyprctl && [ "$HAVE_JQ" = true ]; then
    SCREEN_COUNT=$(hyprctl monitors -j 2>/dev/null | jq -r 'length' 2>/dev/null)
    if [ -n "$SCREEN_COUNT" ] && [ "$SCREEN_COUNT" != "0" ]; then
        record "screens_count" "PASS" "$SCREEN_COUNT screen(s) reported"
    else
        record "screens_count" "WARN" "hyprctl reported no screens"
    fi
else
    record "screens_count" "SKIP" "hyprctl or jq not available"
fi

MONITORS_LUA="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/monitors.lua"
if [ -f "$MONITORS_LUA" ]; then
    # An output named by two LIVE blocks is the one persisting bug worth
    # catching: at boot only the last one applies, so a save that appended
    # instead of rewriting leaves the user staring at the old layout with no
    # error anywhere. Only lines that actually create a monitor count -- the
    # stock file's commented-out examples all name DP-2, and flagging those
    # would fire on every unedited install.
    LIVE=$(grep -vE '^[[:space:]]*--' "$MONITORS_LUA")
    DUPES=$(printf '%s\n' "$LIVE" \
        | sed -n 's/.*output[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        | grep -v '^$' | sort | uniq -d | tr '\n' ' ')
    if [ -n "$DUPES" ]; then
        record "screens_monitor_blocks" "FAIL" "two hl.monitor blocks name the same output: $DUPES"
    elif ! printf '%s\n' "$LIVE" | grep -q 'hl\.monitor('; then
        record "screens_monitor_blocks" "FAIL" "no hl.monitor block at all: the layout will not apply"
    else
        record "screens_monitor_blocks" "PASS" "one block per output"
    fi
fi

fi

# ---------------------------------------------------------------------------
# 6. Settings that go nowhere. A flag can be written by a settings row, be
# referenced by a component, and STILL do nothing -- because the component that
# reads it ignores it on one code path. That is exactly how "Transparency mode"
# ended up as a switch that turned nothing on and nothing off: Flags.glass was
# read by LiquidGlass, but the pill's fill took the opaque theme-background branch
# and never consulted the flag. A "is it referenced?" sweep passes that, so the
# check here is the sweep, so at least a flag with NO consumer at all is caught.
# ---------------------------------------------------------------------------
WRITTEN=$(grep -rhoE 'Flags\.[a-zA-Z]+[[:space:]]*=[^=]' "$INSTALL_DIR/surfaces" 2>/dev/null \
    | grep -oE 'Flags\.[a-zA-Z]+' | sed 's/Flags\.//' | sort -u)
UNUSED=""
for f in $WRITTEN; do
    # Consumed by QML outside the settings surfaces, or by a script reading
    # flags.json directly (wallpaper fit, for one, is a script consumer).
    qml=$(grep -rlE "Flags\.$f\b" --include='*.qml' "$INSTALL_DIR" 2>/dev/null \
        | grep -vE '/surfaces/' | wc -l)
    scr=$(grep -rlE "\.$f\b" --include='*.sh' --include='*.py' "$INSTALL_DIR/scripts" "$INSTALL_DIR/lib" 2>/dev/null | wc -l)
    if [ "$qml" -eq 0 ] && [ "$scr" -eq 0 ]; then
        # A flag written AND read within the same surface is self-contained,
        # not dead -- e.g. Profile.qml writes and reads Flags.profileAvatar
        # to persist a custom avatar path across sessions.
        wrote_files=$(grep -rlE "Flags\.$f\s*=" "$INSTALL_DIR/surfaces/"*.qml 2>/dev/null)
        self_consumed=false
        for wf in $wrote_files; do
            if grep -qE "Flags\.$f\b" "$wf" 2>/dev/null; then
                self_consumed=true
                break
            fi
        done
        if [ "$self_consumed" = "false" ]; then
            UNUSED="$UNUSED $f"
        fi
    fi
done
if [ -n "$UNUSED" ]; then
    record "settings_dead_flags" "FAIL" "a settings row writes these and nothing reads them:$UNUSED"
else
    record "settings_dead_flags" "PASS" "$(printf '%s\n' $WRITTEN | grep -c .) settings flags all consumed"
fi

# ---------------------------------------------------------------------------
# 7. The flag schema. A key left in flags.json with no property behind it is a
# setting the user can see in the file and cannot change from the bar. The
# inverse is worse: a property that exists in the adapter but has NO Singleton
# alias reads as `undefined` at runtime, so every `if (Flags.x)` takes the
# false branch -- a switch that renders, animates and silently discards the
# write. The QML audit cannot see this (it counts the adapter's own property as
# a declaration), so it is checked here.
# ---------------------------------------------------------------------------
if [ -f "$INSTALL_DIR/Singletons/Flags.qml" ]; then
    ADAPTER_PROPS=$(awk '/JsonAdapter \{/{f=1} f{print} f && /^        \}/{exit}' "$INSTALL_DIR/Singletons/Flags.qml" 2>/dev/null \
        | grep -oE 'property [a-zA-Z]+ [a-zA-Z0-9_]+' | awk '{print $3}' | sort -u)
    ALIASED=$(grep -oE 'property alias [a-zA-Z0-9_]+' "$INSTALL_DIR/Singletons/Flags.qml" \
        | awk '{print $3}' | sort -u)
    UNALIASED=""
    for p in $ADAPTER_PROPS; do
        printf '%s\n' "$ALIASED" | grep -qx "$p" || UNALIASED="$UNALIASED $p"
    done
    if [ -n "$UNALIASED" ]; then
        record "flags_unaliased" "FAIL" "adapter properties with no Singleton alias (they read as undefined):$UNALIASED"
    else
        record "flags_unaliased" "PASS" "$(printf '%s\n' $ADAPTER_PROPS | grep -c .) flags all aliased onto the singleton"
    fi

    # Persisted keys that no longer exist anywhere in the tree.
    if [ -f "$FLAGS_FILE" ] && [ "$HAVE_JQ" = true ]; then
        STALE=$(jq -r 'keys[]' "$FLAGS_FILE" 2>/dev/null | while read -r k; do
            [ -n "$k" ] || continue
            grep -qE "(property alias $k:|property [a-zA-Z]+ $k[;:])" "$INSTALL_DIR/Singletons/Flags.qml" 2>/dev/null || printf '%s ' "$k"
        done)
        if [ -n "$STALE" ]; then
            record "flags_stale_keys" "WARN" "persisted in flags.json but no longer declared:$STALE"
        else
            record "flags_stale_keys" "PASS" "every persisted key still has a property"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 8. Install layout. There were three different answers to "where is Better Bar
# installed?" in the tree: launch.sh used its own directory, the doctor used its
# own, and scripts/better-launch hardcoded ~/.local/share/quickshell/better.
# On an Omarchy plugin install -- which is where this bar actually lives -- the
# hardcoded path does not exist, so the launcher pointed at nothing.
# ---------------------------------------------------------------------------
if [ "$INSTALL_DIR" = "$OMARCHY_PLUGIN_DIR" ]; then
    record "install_dir" "PASS" "Omarchy plugin install at $INSTALL_DIR"
elif [ "$INSTALL_DIR" = "$STANDALONE_DIR" ]; then
    record "install_dir" "PASS" "standalone Quickshell install at $INSTALL_DIR"
elif [ -d "$INSTALL_DIR/.git" ] || [ ! -f "$INSTALL_DIR/manifest.json" ]; then
    # A source checkout -- a clone, a CI runner, a worktree. Nothing is
    # installed here and nothing should be.
    record "install_dir" "PASS" "source checkout at $INSTALL_DIR"
else
    record "install_dir" "WARN" "unrecognised install location: $INSTALL_DIR"
fi

LAUNCHER="$INSTALL_DIR/scripts/better-launch"
if [ -f "$LAUNCHER" ]; then
    if grep -qE 'INSTALL_DIR="\$HOME/\.local/share/quickshell/better"' "$LAUNCHER" && [ "$INSTALL_DIR" != "$STANDALONE_DIR" ]; then
        record "launcher_path" "FAIL" "scripts/better-launch hardcodes $STANDALONE_DIR, but the bar is installed at $INSTALL_DIR"
        if [ "$DO_FIX" = true ]; then
            tmpf=$(mktemp)
            sed 's#^INSTALL_DIR="\$HOME/\.local/share/quickshell/better"$#INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." \&\& pwd)"#' \
                "$LAUNCHER" > "$tmpf" 2>/dev/null
            if [ -s "$tmpf" ] && grep -q 'BASH_SOURCE' "$tmpf"; then
                cp "$tmpf" "$LAUNCHER"
                rm -f "$tmpf"
                record "launcher_path" "FIXED" "scripts/better-launch now resolves its own install directory"
                FIXED=$((FIXED + 1))
            else
                rm -f "$tmpf"
                record "launcher_path" "FAIL" "could not rewrite scripts/better-launch safely"
            fi
        fi
    else
        record "launcher_path" "PASS" "launcher resolves the live install directory"
    fi
fi

# ---------------------------------------------------------------------------
# 9. qmldir registration drift. A QML file with `pragma Singleton` that is not
# declared in its module's qmldir is not exposed by `import "Singletons"` -- so
# every use of it is an unresolved identifier, and the ReferenceError only fires
# when that code path runs. A whole-tree audit that only looks at ids inside a
# file cannot see it, because the file itself is perfectly well-formed.
# ---------------------------------------------------------------------------
QMLDRIFT=""
for mod in Commons components surfaces Singletons Ui; do
    dir="$INSTALL_DIR/$mod"
    [ -d "$dir" ] || continue
    [ -f "$dir/qmldir" ] || continue
    declared=$(awk '{for(i=1;i<=NF;i++) if($i ~ /\.qml$/){print $i; break}}' "$dir/qmldir" | sort -u)
    present=$(cd "$dir" && ls *.qml 2>/dev/null | sort -u)
    missing=$(comm -23 <(printf '%s\n' "$present") <(printf '%s\n' "$declared") | tr '\n' ' ')
    absent=$(comm -13 <(printf '%s\n' "$present") <(printf '%s\n' "$declared") | tr '\n' ' ')
    [ -n "$missing" ] && QMLDRIFT="$QMLDRIFT $mod:undeclared($missing)"
    [ -n "$absent" ] && QMLDRIFT="$QMLDRIFT $mod:missing($absent)"
done
if [ -n "$QMLDRIFT" ]; then
    record "qmldir_drift" "FAIL" "module registration does not match the files on disk:$QMLDRIFT"
else
    record "qmldir_drift" "PASS" "every QML file is declared in its module's qmldir"
fi

# ---------------------------------------------------------------------------
# 10. Surface registry drift. Three places name the surfaces the bar can open:
# the IPC handler in shell.qml, the loaders map in Pill.qml, and the settings
# search index. They were edited independently, so they drifted -- the settings
# search could offer "Plymouth Unlock" for months after that surface was
# deleted, and clicking it did nothing at all.
# ---------------------------------------------------------------------------
LOADER_KEYS=$(sed -n '/readonly property var loaders: ({/,/})/p' "$INSTALL_DIR/Pill.qml" 2>/dev/null \
    | grep -oE '^[[:space:]]+[a-zA-Z][a-zA-Z0-9_]*:[[:space:]]*\(\)' | sed 's/[[:space:]:()]//g' | sort -u)
# A surface can also be named without a loader: the shell special-cases a few
# names itself ("dock" opens the dock's own panel), and a plugin may own a
# capability outright. Those are legitimate targets and must not be reported
# as dead.
SPECIAL_TARGETS=$(grep -oE 'surface === "[a-zA-Z]+"' "$INSTALL_DIR/shell.qml" 2>/dev/null \
    | grep -oE '"[a-zA-Z]+"' | tr -d '"' | sort -u)
CAPABILITY_TARGETS=$(sed -n '/readonly property var surfaceCapability: ({/,/})/p' "$INSTALL_DIR/Singletons/Plugins.qml" 2>/dev/null \
    | grep -oE '^[[:space:]]+[a-zA-Z][a-zA-Z0-9_]*:' | sed 's/[[:space:]:]//g' | sort -u)
VALID_TARGETS=$(printf '%s\n%s\n%s\n' "$LOADER_KEYS" "$SPECIAL_TARGETS" "$CAPABILITY_TARGETS" | grep -v '^$' | sort -u)
IPC_SURFACES=$(grep -oE 'toggleSurface\([a-zA-Z.]+,[[:space:]]*"[a-zA-Z]+"' "$INSTALL_DIR/shell.qml" 2>/dev/null \
    | grep -oE '"[a-zA-Z]+"' | tr -d '"' | sort -u)
UNKNOWN_IPC=""
for s in $IPC_SURFACES; do
    printf '%s\n' "$VALID_TARGETS" | grep -qx "$s" || UNKNOWN_IPC="$UNKNOWN_IPC $s"
done
if [ -n "$UNKNOWN_IPC" ]; then
    record "surface_registry" "FAIL" "the IPC handler opens surfaces with no loader:$UNKNOWN_IPC"
else
    record "surface_registry" "PASS" "$(printf '%s\n' $IPC_SURFACES | grep -c .) IPC surfaces all have a loader"
fi

SEARCH_TARGETS=""
if [ -f "$INSTALL_DIR/lib/settings-search.js" ]; then
    SEARCH_TARGETS=$(grep -oE 'to: "[a-zA-Z]+"' "$INSTALL_DIR/lib/settings-search.js" 2>/dev/null \
        | sed 's/to: "//; s/"//' | sort -u)
    DEAD=""
    for s in $SEARCH_TARGETS; do
        printf '%s\n' "$VALID_TARGETS" | grep -qx "$s" || DEAD="$DEAD $s"
    done
    if [ -n "$DEAD" ]; then
        record "settings_search_targets" "FAIL" "the settings search offers surfaces that do not exist:$DEAD"
    else
        record "settings_search_targets" "PASS" "$(printf '%s\n' $SEARCH_TARGETS | grep -c .) search targets all resolve"
    fi
fi

# ---------------------------------------------------------------------------
# 11. Script syntax. A shell script with a syntax error fails at the moment it
# is run -- which, for a script the bar runs from a menu row, is a menu row
# that does nothing. `bash -n` catches it before it ships.
# ---------------------------------------------------------------------------
SYNTAX_BAD=""
for s in "$INSTALL_DIR"/scripts/*.sh "$INSTALL_DIR"/launch.sh "$INSTALL_DIR"/uninstall.sh "$INSTALL_DIR"/scripts/better-launch; do
    [ -f "$s" ] || continue
    bash -n "$s" 2>/dev/null || SYNTAX_BAD="$SYNTAX_BAD $(basename "$s")"
done
if [ -n "$SYNTAX_BAD" ]; then
    record "shell_syntax" "FAIL" "these shell scripts do not parse:$SYNTAX_BAD"
else
    record "shell_syntax" "PASS" "every shell script parses"
fi

PY_BAD=""
if have python3; then
    for s in "$INSTALL_DIR"/scripts/*.py; do
        [ -f "$s" ] || continue
        python3 -m py_compile "$s" 2>/dev/null || PY_BAD="$PY_BAD $(basename "$s")"
    done
fi
if [ -n "$PY_BAD" ]; then
    record "python_syntax" "FAIL" "these python scripts do not compile:$PY_BAD"
elif have python3; then
    record "python_syntax" "PASS" "every python script compiles"
else
    record "python_syntax" "SKIP" "python3 not available"
fi

if have node; then
    JS_BAD=""
    JS_TMP=$(mktemp -d)
    for s in "$INSTALL_DIR"/lib/*.js "$INSTALL_DIR"/lib/*.mjs; do
        [ -f "$s" ] || continue
        # A .js file in this tree is a QML JavaScript library: it opens with
        # Qt's `.pragma library` directive, which is not JS, and it is loaded
        # by QML rather than by node. So the directive is stripped and the
        # rest is checked as a module -- otherwise every library in the tree
        # fails for a reason that has nothing to do with the code.
        sed '/^\.pragma/d' "$s" > "$JS_TMP/check.mjs"
        node --check "$JS_TMP/check.mjs" 2>/dev/null || JS_BAD="$JS_BAD $(basename "$s")"
    done
    rm -rf "$JS_TMP"
    if [ -n "$JS_BAD" ]; then
        record "js_syntax" "FAIL" "these scripts do not parse:$JS_BAD"
    else
        record "js_syntax" "PASS" "every JS module parses"
    fi
else
    record "js_syntax" "SKIP" "node not available"
fi

# ---------------------------------------------------------------------------
# 12. The QML integrity gate. The reviewed baseline lives in
# lib/qml-audit.test.sh, so it is read from there rather than duplicated here --
# one source of truth, and the doctor cannot drift away from the gate.
# ---------------------------------------------------------------------------
if have python3 && [ -f "$INSTALL_DIR/lib/qml-audit.py" ]; then
    # The audit's own --check mode compares against the reviewed baseline that
    # lives in lib/qml-audit.test.sh, so the doctor and the gate can never
    # disagree about what has been reviewed.
    AUDIT_OUT=$(python3 "$INSTALL_DIR/lib/qml-audit.py" --check "$INSTALL_DIR" 2>/dev/null)
    AUDIT_RC=$?
    if [ "$AUDIT_RC" -eq 0 ]; then
        record "qml_integrity" "PASS" "$(printf '%s' "$AUDIT_OUT" | head -1)"
    else
        record "qml_integrity" "FAIL" "$(printf '%s' "$AUDIT_OUT" | grep -E 'NEW' | head -5 | tr '\n' ';')"
    fi
else
    record "qml_integrity" "SKIP" "python3 or lib/qml-audit.py not available"
fi

# ---------------------------------------------------------------------------
# 12b. qmllint.
#
# The QML integrity gate knows about ids and tokens; qmllint knows the Qt API
# itself. It catches the failures that only fire when a user opens that one
# screen: an enum member that was renamed between Qt versions (Font.SemiBold
# became Font.DemiBold in Qt 6.9, and every one of the eight profile labels
# silently lost its weight), a property that does not exist on the type it is
# assigned to, and a parse error.
#
# Only ONE category gates, because only one is unambiguous. A `missing-property`
# warning is often qmllint without the full type context, and a `syntax` one is
# often a false positive on a Quickshell grouped property -- the stock
# Omarchy shell's own PopupCard.qml produces the identical warning. A
# `read-only-property` warning, though, is always a write that is silently
# dropped: the code believes it changed something and nothing changed. That is
# the class worth failing on; the rest is counted and shown.
# ---------------------------------------------------------------------------
QMLLINT=""
for cand in qmllint /usr/lib/qt6/bin/qmllint; do
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
        QMLLINT="$cand"
        break
    fi
done
if [ -z "$QMLLINT" ]; then
    record "qml_lint" "SKIP" "qmllint not installed"
elif [ "$DO_DEEP" != true ]; then
    record "qml_lint" "SKIP" "not run (qmllint over the whole tree takes a while) -- use --deep"
else
    LINT_OUT=""
    while IFS= read -r f; do
        LINT_OUT="$LINT_OUT$("$QMLLINT" -I "$INSTALL_DIR" -I "$INSTALL_DIR/Commons" -I "$INSTALL_DIR/components" \
            -I "$INSTALL_DIR/surfaces" -I "$INSTALL_DIR/Singletons" -I "$INSTALL_DIR/Ui" -I /usr/lib/qt6/qml "$f" 2>&1)
"
    done < <(find "$INSTALL_DIR" -name "*.qml" -not -path "*/node_modules/*" 2>/dev/null | sort)
    DROPPED=$(printf '%s\n' "$LINT_OUT" | grep -cE '\[read-only-property\]')
    if [ "$DROPPED" -gt 0 ]; then
        record "qml_lint" "FAIL" "$DROPPED write(s) to a read-only property are silently dropped"
    else
        record "qml_lint" "PASS" "no dropped writes ($(printf '%s\n' "$LINT_OUT" | grep -oE '\[[a-z-]+\]' | sort | uniq -c | tr '\n' ' '))"
    fi
fi

# ---------------------------------------------------------------------------
# 13. The project's own test suite. This is the check the old doctor did not
# have, and it is the one that matters: the doctor reported "All systems
# healthy" on a tree whose own suite was failing eight ways. Every suite in
# lib/ runs here, in parallel, and the failures are named.
# ---------------------------------------------------------------------------
run_suite() {
    local f="$1" base
    base="$(basename "$f")"
    case "$f" in
        *.test.mjs) node --test "$f" ;;
        *.test.py) python3 "$f" ;;
        *.test.sh)
            case "$base" in
                alphacoders.test.sh) bash "$f" "$INSTALL_DIR/scripts/wallpaper-search.sh" ;;
                omshell-load.test.sh)
                    SHELL_SRC="${SHELL_SRC:-/usr/share/omarchy/shell}" \
                    OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
                    bash "$f" "$INSTALL_DIR" ;;
                surface-smoke.test.sh)
                    # Opens every surface in turn and reads the shell's log for
                    # what QML complained about while each one was open. It is
                    # the check that proves the buttons work: a surface that
                    # throws only fails when somebody opens it.
                    SHELL_SRC="${SHELL_SRC:-/usr/share/omarchy/shell}" \
                    OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
                    bash "$f" "$INSTALL_DIR" ;;
                *) bash "$f" "$INSTALL_DIR" ;;
            esac
            ;;
    esac
}

check_suite() {
    local suites=() f base
    while IFS= read -r f; do
        base="$(basename "$f")"
        case "$base" in
            omshell-load.test.sh)
                # Needs a live Wayland session and a whole omarchy-shell; it is
                # the heavyweight end of the suite, so it is deep-mode only.
                [ "$DO_DEEP" = true ] && suites+=("$f")
                ;;
            surface-smoke.test.sh)
                # Same: it launches a shell and opens every surface.
                [ "$DO_DEEP" = true ] && suites+=("$f")
                ;;
            *) suites+=("$f") ;;
        esac
    done < <(find "$INSTALL_DIR/lib" -maxdepth 1 \( -name '*.test.sh' -o -name '*.test.mjs' -o -name '*.test.py' \) 2>/dev/null | sort)

    if [ "${#suites[@]}" -eq 0 ]; then
        record "test_suite" "SKIP" "no test suites found"
        return
    fi

    local tmp i=0
    tmp=$(mktemp -d)
    for f in "${suites[@]}"; do
        i=$((i + 1))
        ( run_suite "$f" >"$tmp/$i.log" 2>&1; echo $? >"$tmp/$i.rc" ) &
        while [ "$(jobs -rp 2>/dev/null | wc -l)" -ge 8 ]; do sleep 0.05; done
    done
    wait 2>/dev/null

    local failed=0 names=() j=0
    for f in "${suites[@]}"; do
        j=$((j + 1))
        rc=$(cat "$tmp/$j.rc" 2>/dev/null || echo 1)
        if [ "$rc" != "0" ]; then
            failed=$((failed + 1))
            names+=("$(basename "$f")")
        fi
    done
    rm -rf "$tmp"

    if [ "$failed" -eq 0 ]; then
        record "test_suite" "PASS" "${#suites[@]} suites, all green"
    else
        record "test_suite" "FAIL" "$failed of ${#suites[@]} suites failing:$(printf ' %s' "${names[@]}")"
    fi
}

if [ "$STATIC_ONLY" = false ] && have node; then
    check_suite
else
    record "test_suite" "SKIP" "not run in --static mode (CI runs every suite as its own step)"
fi

# ---------------------------------------------------------------------------
# 14. Output Format
# ---------------------------------------------------------------------------

# The JSON is built here rather than with printf, because a value containing a
# quote or a backslash -- a path, an error message, a flag name -- has to come
# out escaped. The old emitter interpolated values raw, so any such value
# produced a file that no JSON parser would accept.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

if [ "$DO_JSON" = true ]; then
    printf '{\n'
    printf '  "schemaVersion": 2,\n'
    printf '  "issues": %d,\n' "$ISSUES"
    printf '  "fixed": %d,\n' "$FIXED"
    printf '  "bar_instances": %d,\n' "$bar_count"
    printf '  "watcher_active": %s,\n' "$watcher_running"
    printf '  "awww_active": %s,\n' "$awww_running"
    printf '  "results": {\n'
    first=true
    for k in "${ORDER[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            printf ',\n'
        fi
        printf '    "%s": {"status": "%s", "detail": "%s"}' \
            "$k" "${STATUS[$k]}" "$(json_escape "${RESULTS[$k]}")"
    done
    printf '\n  }\n}\n'
    exit 0
fi

if [ "$DO_REPORT" = true ]; then
    echo "## Better Bar System Diagnostic Report"
    echo "- **Generated:** $(date -u +'%Y-%m-%d %H:%M:%SZ')"
    echo "- **Bar Instances:** $bar_count"
    echo "- **Watcher Active:** $watcher_running"
    echo "- **Awww Daemon:** $awww_running"
    echo "- **Issues:** $ISSUES"
    echo ""
    echo "### Subsystem Health"
    for k in "${ORDER[@]}"; do
        echo "- **$k** (${STATUS[$k]}): ${RESULTS[$k]}"
    done
    exit 0
fi

# Human CLI text
echo "=== Better Bar Doctor ==="
for k in "${ORDER[@]}"; do
    printf '  %-24s: %-6s %s\n' "$k" "${STATUS[$k]}" "${RESULTS[$k]}"
done
echo "-----------------------------------"
if [ "$ISSUES" -eq 0 ]; then
    echo "All systems healthy! (0 issues detected)"
    exit 0
elif [ "$FIXED" -gt 0 ] && [ "$FIXED" -ge "$ISSUES" ]; then
    echo "Auto-repair successful ($FIXED issue(s) fixed)"
    exit 0
else
    echo "Detected $ISSUES issue(s). Run with --fix to automatically repair."
    exit 1
fi
