#!/usr/bin/env bash
# Launch Better Bar with atomic single-instance mutex and jemalloc decay settings.
set -uo pipefail

export MALLOC_CONF="background_thread:true,dirty_decay_ms:100,muzzy_decay_ms:100"
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Single-instance guard: prevent duplicate bars from ever running
# simultaneously, by asking what is already serving this config rather than by
# holding a lock.
LOCKFILE="${XDG_RUNTIME_DIR:-/tmp}/better-bar.lock"

existing_pid() {
  local pid surface
  if command -v hyprctl >/dev/null 2>&1; then
    surface=$(hyprctl layers 2>/dev/null | grep -o 'namespace: better, pid: [0-9]*' | grep -o '[0-9]*$' | head -1)
    if [ -n "$surface" ] && [ -d "/proc/$surface" ] && [ "$surface" != "$$" ]; then
      echo "$surface"
      return 0
    fi
  fi
  for pid in $(pgrep -x quickshell 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
      *"--config $DIR"*|*"-c $DIR"*) echo "$pid"; return 0 ;;
    esac
  done
  return 1
}

# Single-instance guard, held by PID rather than by a file descriptor.
#
# The descriptor version was wrong and had to go, because a descriptor CANNOT
# be scoped to this process here. Every way of opening one -- `exec 200>`,
# `exec {FD}>`, and `shopt -s varredir_close` -- leaves it inheritable: bash
# only marks a redirection close-on-exec in cases it does not cover these. So
# the bar's long-lived keep-awake helper (`systemd-inhibit ... sleep infinity`,
# which is built never to exit) inherited the lock descriptor. Killing the bar
# left the mutex held by that helper, every relaunch took the wait-then-refuse
# path, and better-watch spun forever relaunching a bar that never started --
# a desktop with no bar and no error anywhere.
#
# It hides while the helper is alive, because a live descriptor looks like a
# clean shutdown. Only a bar killed on its own exposes it, which is exactly
# what a crash does.
#
# A PID file cannot leak, because the number it names is the bar itself. The
# stale case is handled explicitly rather than inferred: a PID that is dead,
# or alive but no longer a bar, is taken over instead of trusted.
lock_owner() {
  local recorded
  recorded=$(cat "$LOCKFILE" 2>/dev/null | tr -cd '0-9') || return 1
  [ -n "$recorded" ] || return 1
  kill -0 "$recorded" 2>/dev/null || return 1
  printf '%s\n' "$recorded"
}

existing=$(existing_pid || true)
if [ -z "$existing" ]; then
  # No live bar on screen. Take the slot, unless the recorded PID is still a
  # bar we failed to see (a race between two launchers).
  if recorded=$(lock_owner); then
    case "$(tr '\0' ' ' < "/proc/$recorded/cmdline" 2>/dev/null)" in
      *quickshell*--config*"$DIR"*) existing="$recorded" ;;
    esac
  fi
fi

if [ -n "$existing" ]; then
  echo "better: already running as pid $existing; not starting a duplicate bar" >&2
  if command -v quickshell >/dev/null 2>&1; then
    quickshell ipc call better reloadTheme >/dev/null 2>&1 || true
  fi
  exit 0
fi

# Claim the slot. The write is atomic (a single small write to a fresh file)
# so two launchers racing here cannot both believe they won.
printf '%s\n' "$$" > "$LOCKFILE"

if command -v quickshell >/dev/null 2>&1; then
  exec quickshell --config "$DIR" "$@"
elif command -v qs >/dev/null 2>&1; then
  exec qs -c "$DIR" "$@"
fi

echo "launch.sh: quickshell not found in PATH" >&2
exit 127
