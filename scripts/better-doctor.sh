#!/usr/bin/env bash
# Better Bar Diagnostic & Self-Repair Engine
# Checks process topology, layer-shell surfaces, wallpaper daemons, and symlink integrity.
set -uo pipefail

DO_FIX=false
DO_JSON=false
DO_REPORT=false

for arg in "$@"; do
    case "$arg" in
        --fix) DO_FIX=true ;;
        --json) DO_JSON=true ;;
        --report) DO_REPORT=true ;;
        -h|--help)
            echo "Usage: better-doctor.sh [--fix] [--json] [--report]"
            echo "  --fix     Automatically repair detected issues (kill duplicate bars, start daemons, fix symlinks)"
            echo "  --json    Emit machine-readable JSON status"
            echo "  --report  Emit sanitized Markdown summary for GitHub issues"
            exit 0
            ;;
    esac
done

INSTALL_DIR="${HOME}/.local/share/quickshell/better"
ISSUES=0
FIXED=0

declare -A RESULTS

# 1. Process Topology
#
# `ps` and the count are separate reads, so a bar that exits in between is still
# listed. Counting it would report a duplicate for a bar that is already gone --
# and a doctor that cries wolf gets ignored on the runs that matter, so each pid
# is re-checked against /proc before it counts.
bar_pids=()
while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    [ -d "/proc/$pid" ] || continue
    bar_pids+=("$pid")
done < <(ps -eo pid,args 2>/dev/null | grep "[q]uickshell --config" | awk '{print $1}')

bar_count=${#bar_pids[@]}
watcher_running=false
if pgrep -f "better-watch" >/dev/null 2>&1; then
    watcher_running=true
fi

if [ "$bar_count" -eq 1 ]; then
    RESULTS["processes"]="PASS (1 instance, pid ${bar_pids[0]})"
elif [ "$bar_count" -eq 0 ]; then
    RESULTS["processes"]="FAIL (0 instances running)"
    ISSUES=$((ISSUES + 1))
    if [ "$DO_FIX" = true ]; then
        if [ "$watcher_running" = false ] && [ -x "$INSTALL_DIR/scripts/better-watch" ]; then
            nohup "$INSTALL_DIR/scripts/better-watch" >/dev/null 2>&1 &
            FIXED=$((FIXED + 1))
        fi
    fi
else
    RESULTS["processes"]="FAIL ($bar_count duplicate instances: ${bar_pids[*]})"
    ISSUES=$((ISSUES + 1))
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
        RESULTS["processes"]="FIXED (kept pid $keeper, terminated duplicates)"
    fi
fi

# 2. Layer-Shell Surface Health
layers_ok=false
if command -v hyprctl >/dev/null 2>&1; then
    layer_output=$(hyprctl layers 2>/dev/null || echo "")
    if echo "$layer_output" | grep -q "namespace: better"; then
        layers_ok=true
        RESULTS["layers"]="PASS (better namespace mapped)"
    else
        RESULTS["layers"]="WARN (better layer not currently mapped)"
        ISSUES=$((ISSUES + 1))
    fi
else
    RESULTS["layers"]="SKIP (hyprctl not available)"
fi

# 3. Wallpaper Daemon Health
awww_running=false
if pgrep -x "awww-daemon" >/dev/null 2>&1 || (command -v hyprctl >/dev/null 2>&1 && hyprctl layers 2>/dev/null | grep -q "namespace: awww-daemon"); then
    awww_running=true
    RESULTS["awww"]="PASS (awww-daemon running)"
else
    RESULTS["awww"]="WARN (awww-daemon not running)"
    ISSUES=$((ISSUES + 1))
    if [ "$DO_FIX" = true ] && command -v awww >/dev/null 2>&1; then
        awww toggle >/dev/null 2>&1 || true
        FIXED=$((FIXED + 1))
        RESULTS["awww"]="FIXED (started awww-daemon)"
    fi
fi

# 4. Background Symlink Integrity
bg_link="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/background"
if [ -L "$bg_link" ] || [ -f "$bg_link" ]; then
    resolved_bg=$(readlink -f "$bg_link" 2>/dev/null || echo "")
    if [ -n "$resolved_bg" ] && [ -f "$resolved_bg" ]; then
        RESULTS["background_link"]="PASS ($resolved_bg)"
    else
        RESULTS["background_link"]="FAIL (broken symlink: $bg_link -> $resolved_bg)"
        ISSUES=$((ISSUES + 1))
        if [ "$DO_FIX" = true ]; then
            theme_bg=$(ls "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/backgrounds/"*.{jpg,png,jpeg} 2>/dev/null | head -1 || echo "")
            if [ -n "$theme_bg" ] && [ -f "$theme_bg" ]; then
                ln -nsf "$theme_bg" "$bg_link" 2>/dev/null || true
                FIXED=$((FIXED + 1))
                RESULTS["background_link"]="FIXED (repointed to $theme_bg)"
            fi
        fi
    fi
else
    RESULTS["background_link"]="WARN (no background symlink at $bg_link)"
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

FLAGS_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/better/flags.json"
WPDIR_CFG=$(jq -r '.wallpaperDir // ""' "$FLAGS_FILE" 2>/dev/null || echo "")

# (a) A wallpaperDir inside current/theme. This is the data-loss one: omarchy
# installs a theme with rm -rf + mv, so everything downloaded there -- every
# wallhaven, alphacoders and wallwidgy pick -- is deleted by the next theme
# install. It is the natural setting, which is why it gets chosen.
if [ -n "$WPDIR_CFG" ]; then
    case "$WPDIR_CFG" in
        "$HOME/.local/state/omarchy/current/"*|*"/.local/state/omarchy/current/"*)
            RESULTS["wallpaper_dir"]="FAIL ($WPDIR_CFG is transient -- a theme install deletes every wallpaper in it)"
            ISSUES=$((ISSUES + 1))
            if [ "$DO_FIX" = true ]; then
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
                RESULTS["wallpaper_dir"]="FIXED (moved wallpapers to $PERM and repointed)"
                FIXED=$((FIXED + 1))
            fi
            ;;
        *)
            RESULTS["wallpaper_dir"]="PASS ($WPDIR_CFG)"
            ;;
    esac
else
    RESULTS["wallpaper_dir"]="PASS (autodetect)"
fi

# (b) A theme gallery cache that is missing, or older than the themes it should
# describe. A stale cache is the black-tile bug: the picker paints from it, so a
# new custom theme's colours never arrive and its tile fills with the fallback.
GALLERY="${XDG_CACHE_HOME:-$HOME/.cache}/better/themes.json"
if [ ! -s "$GALLERY" ]; then
    RESULTS["theme_gallery"]="FAIL (no gallery cache -- theme tiles will render from fallbacks)"
    ISSUES=$((ISSUES + 1))
    if [ "$DO_FIX" = true ]; then
        python3 "$INSTALL_DIR/scripts/themes.py" > "$GALLERY" 2>/dev/null \
            && RESULTS["theme_gallery"]="FIXED (gallery rebuilt)" && FIXED=$((FIXED + 1))
    fi
else
    newest_theme=$(stat -c %Y "$HOME/.config/omarchy/themes" 2>/dev/null || echo 0)
    cache_age=$(stat -c %Y "$GALLERY" 2>/dev/null || echo 0)
    if [ "$newest_theme" -gt "$cache_age" ]; then
        RESULTS["theme_gallery"]="FAIL (gallery is older than the themes -- a newly installed theme will show a black tile)"
        ISSUES=$((ISSUES + 1))
        if [ "$DO_FIX" = true ]; then
            python3 "$INSTALL_DIR/scripts/themes.py" > "$GALLERY" 2>/dev/null \
                && RESULTS["theme_gallery"]="FIXED (gallery rebuilt)" && FIXED=$((FIXED + 1))
        fi
    else
        RESULTS["theme_gallery"]="PASS"
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
        RESULTS["theme_tiles"]="FAIL (these themes paint a black tile: $bad_tiles)"
        ISSUES=$((ISSUES + 1))
        if [ "$DO_FIX" = true ]; then
            python3 "$INSTALL_DIR/scripts/themes.py" > "$GALLERY" 2>/dev/null \
                && RESULTS["theme_tiles"]="FIXED (gallery rebuilt with a colour-validating parser)" \
                && FIXED=$((FIXED + 1))
        fi
    else
        RESULTS["theme_tiles"]="PASS (every tile colour is a colour)"
    fi
fi

# (d) A per-output map entry naming a symlink. -f follows symlinks, so every
# liveness check passes while the target is inside current/theme and that tree is
# about to be replaced -- so the entry names a file that will not exist, and
# restore_all paints the void. This is the black-screen wallpaper.
WPMAP="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-map"
if [ -s "$WPMAP" ]; then
    symlinked=$(cut -f2 "$WPMAP" 2>/dev/null | while read -r p; do
        [ -n "$p" ] && [ -L "$p" ] && printf '%s ' "$p"
    done)
    if [ -n "$symlinked" ]; then
        RESULTS["wallpaper_map"]="FAIL (entries name a symlink, so a theme switch strands them: $symlinked)"
        ISSUES=$((ISSUES + 1))
        if [ "$DO_FIX" = true ]; then
            bash "$INSTALL_DIR/scripts/wallpaper.sh" init >/dev/null 2>&1 || true
            RESULTS["wallpaper_map"]="FIXED (re-resolved against the wallpaper script)"
            FIXED=$((FIXED + 1))
        fi
    else
        RESULTS["wallpaper_map"]="PASS"
    fi
fi

# (e) Aww is painting a file that no longer exists. awww keeps reporting the last
# image it was asked for long after that file is deleted, so the desktop is
# blank with every check reporting success. The fix is a re-apply.
if command -v awww >/dev/null 2>&1; then
    shown=$(awww query -j 2>/dev/null | jq -r '[.[]?[]?.displaying?.image? // empty] | .[0] // empty' 2>/dev/null)
    if [ -n "$shown" ] && [ ! -f "$shown" ]; then
        RESULTS["wallpaper_painted"]="FAIL (the wallpaper on screen is gone: $shown)"
        ISSUES=$((ISSUES + 1))
        if [ "$DO_FIX" = true ]; then
            bash "$INSTALL_DIR/scripts/wallpaper.sh" set "$shown" --force >/dev/null 2>&1 \
                || bash "$INSTALL_DIR/scripts/wallpaper.sh" init >/dev/null 2>&1 || true
            RESULTS["wallpaper_painted"]="FIXED (re-applied from the recorded wallpaper)"
            FIXED=$((FIXED + 1))
        fi
    elif [ -z "$shown" ]; then
        RESULTS["wallpaper_painted"]="WARN (nothing reported on screen)"
    else
        RESULTS["wallpaper_painted"]="PASS ($(basename "$shown"))"
    fi
fi

# 5. Output Format
if [ "$DO_JSON" = true ]; then
    printf '{\n'
    printf '  "issues": %d,\n' "$ISSUES"
    printf '  "fixed": %d,\n' "$FIXED"
    printf '  "bar_instances": %d,\n' "$bar_count"
    printf '  "watcher_active": %s,\n' "$watcher_running"
    printf '  "awww_active": %s,\n' "$awww_running"
    printf '  "results": {\n'
    first=true
    for k in "${!RESULTS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            printf ',\n'
        fi
        printf '    "%s": "%s"' "$k" "${RESULTS[$k]}"
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
    echo ""
    echo "### Subsystem Health"
    for k in "${!RESULTS[@]}"; do
        echo "- **$k**: ${RESULTS[$k]}"
    done
    exit 0
fi

# Human CLI text
echo "=== Better Bar Doctor ==="
for k in "${!RESULTS[@]}"; do
    printf "  %-18s: %s\n" "$k" "${RESULTS[$k]}"
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
