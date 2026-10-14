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
