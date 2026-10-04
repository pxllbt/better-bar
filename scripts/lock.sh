#!/bin/sh
# Better session lock: hand the session to hyprlock.
#
# One entry point: the pill's power menu, the SUPER,L keybind and
# hypridle all call this. The lock's look is entirely hyprlock's —
# this repo ships no hyprlock.conf and generates none — so configure
# it the way you configure hyprlock everywhere else.
#
# Only one process can hold the Wayland session lock, so a second
# hyprlock can never improve on a first: it either fails to take the
# lock, or stacks an identical surface behind the live one where no
# dismiss can reach it. Either way it never exits, and each instance
# parks ~167 MiB of renderer for the rest of the session. The pid
# guard below makes a repeat request a no-op instead; a missing
# hyprlock is a hard error, never a silently unlocked session.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/better"
LOG="$CACHE_DIR/lock.log"
PIDFILE="$CACHE_DIR/hyprlock.pid"

mkdir -p "$CACHE_DIR" 2>/dev/null

note() {
    echo "$(date '+%F %T'): $*" >>"$LOG"
}

if ! command -v hyprlock >/dev/null 2>&1; then
    note "ERROR hyprlock is not installed — nothing to lock with"
    echo "lock.sh: hyprlock is not installed — cannot lock" >&2
    exit 1
fi

# A live recorded pid means the session is already locked and the
# request is a no-op; anything else is stale bookkeeping. The pid is
# confirmed to really be hyprlock so a recycled pid cannot read as
# "locked".
if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    case "$pid" in
        '' | *[!0-9]*) ;;
        *)
            if kill -0 "$pid" 2>/dev/null &&
               [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "hyprlock" ]; then
                note "hyprlock already running (pid $pid) -> session is already locked, not spawning another"
                exit 0
            fi
            ;;
    esac
fi

# Reap instances this script did not start. A stray that happens to
# hold the lock is replaced within the same request instead of being
# left to linger.
if command -v pkill >/dev/null 2>&1; then
    strays=$(pgrep -x hyprlock 2>/dev/null | wc -l)
    if [ "$strays" -gt 0 ]; then
        pkill -x hyprlock 2>/dev/null
        sleep 0.3
        note "reaped $strays stray hyprlock instance(s) from an earlier lock request"
    fi
fi

rm -f "$PIDFILE"
# `exec` preserves the pid, so writing $$ first names the exact
# process this script started.
echo $$ >"$PIDFILE"
exec hyprlock
