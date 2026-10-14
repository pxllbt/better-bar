#!/usr/bin/env bash
# Asserts that launch.sh's single-instance guard does not hold anything that a
# child of the bar can keep alive after the bar itself is gone.
#
# Why this exists: the guard was an flock on a file descriptor. The bar starts
# at least one long-lived helper -- `systemd-inhibit ... sleep infinity`, the
# keep-awake helper -- and that child INHERITED the lock descriptor. Killing
# the bar left the mutex held by a process designed never to exit, so every
# subsequent launch waited, saw a live process, refused and exited:
# better-watch spun forever relaunching a bar that never started, and the
# desktop had no bar at all with no error anywhere.
#
# It hides while the helper lives, because a live descriptor looks like a
# clean shutdown. Only a bar killed on its own exposes it, which is exactly
# what a crash does.
#
# The replacement asks what is already serving this config rather than holding
# a lock, so there is no descriptor to inherit at all. These assertions pin
# that, because "tidy this back into an flock" is a change that looks harmless
# and reintroduces a desktop with no bar.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LAUNCH="$ROOT/launch.sh"

failed=0
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}
hasnt() {
    if [ "$2" -gt 0 ]; then
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' "$1" "$3"
    else
        printf 'PASS %s\n' "$1"
    fi
}

[ -f "$LAUNCH" ] || { echo "no launch.sh at $LAUNCH" >&2; exit 1; }

# 1. No descriptor-based lock at all. Each of these was tried and each leaks:
#    a numbered exec 200>, the brace form, and shopt -s varredir_close.
hasnt "launch.sh takes no flock" \
    "$(grep -cE '(^|[^_[:alnum:]])flock' "$LAUNCH")" "flock"

hasnt "launch.sh holds no numbered lock descriptor" \
    "$(grep -cE '^\s*exec 200>' "$LAUNCH")" "exec 200>"

# Comments may still discuss it -- the file explains why it does not work -- but
# no executable line may use it.
hasnt "launch.sh does not enable varredir_close" \
    "$(grep -vE '^\s*#' "$LAUNCH" | grep -cE 'varredir_close')" \
    "varredir_close outside comments"

# 2. The guard is a PID, and the PID is validated rather than trusted.
has "launch.sh records its own pid to claim the slot" \
    "$(grep -cF 'printf '"'"'%s\n'"'"' "$$" > "$LOCKFILE"' "$LAUNCH")" \
    "printf '%s\n' \"\$\$\" > \"\$LOCKFILE\""

has "launch.sh reads the recorded pid back" \
    "$(grep -c 'cat "$LOCKFILE"' "$LAUNCH")" 'cat "$LOCKFILE"'

# 3. A stale record must be taken over, never obeyed. This is the whole point:
#    a dead PID is the normal state after any crash.
has "a recorded pid is checked for liveness" \
    "$(grep -c 'kill -0 "\$recorded"' "$LAUNCH")" 'kill -0 "$recorded"'

has "a live-but-not-a-bar pid is not trusted as the bar" \
    "$(grep -c 'proc/\$recorded/cmdline' "$LAUNCH")" \
    '/proc/$recorded/cmdline re-check'

has "the liveness check tolerates a vanished pid" \
    "$(grep -cE 'kill -0 .* 2>/dev/null \|\| return 1' "$LAUNCH")" \
    'kill -0 ... || return 1'

# 4. The live check that actually decides remains in place.
has "launch.sh still checks the layer-shell surface" \
    "$(grep -c 'hyprctl layers' "$LAUNCH")" "hyprctl layers"

has "launch.sh still refuses to start a duplicate" \
    "$(grep -c 'not starting a duplicate bar' "$LAUNCH")" \
    "not starting a duplicate bar"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
