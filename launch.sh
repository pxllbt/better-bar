#!/usr/bin/env bash
# Launch Better Bar with atomic single-instance mutex and jemalloc decay settings.
set -uo pipefail

export MALLOC_CONF="background_thread:true,dirty_decay_ms:100,muzzy_decay_ms:100"
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Single-instance mutex: prevent duplicate bars from ever running simultaneously.
# Checks atomic flock AND active layer-shell surface/PID before spawning.
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

exec 200>"$LOCKFILE"
existing=""
if ! flock -n 200 || existing=$(existing_pid); then
  pid_to_check="${existing:-$(cat "$LOCKFILE" 2>/dev/null || true)}"
  if [ -n "$pid_to_check" ] && kill -0 "$pid_to_check" 2>/dev/null; then
    echo "better: already running as pid $pid_to_check; not starting a duplicate bar" >&2
    if command -v quickshell >/dev/null 2>&1; then
      quickshell ipc call better reloadTheme >/dev/null 2>&1 || true
    fi
    exit 0
  fi
  # Lock held by an unreadable or exiting process, wait a brief beat
  flock -w 2 200 || exit 0
fi

# Store our active PID in the lockfile
echo "$$" > "$LOCKFILE"

if command -v quickshell >/dev/null 2>&1; then
  exec quickshell --config "$DIR" "$@"
elif command -v qs >/dev/null 2>&1; then
  exec qs -c "$DIR" "$@"
fi

echo "launch.sh: quickshell not found in PATH" >&2
exit 127
