#!/usr/bin/env bash
# A truncated state.json must never blank a live recording chip.
#
# THE BUG THIS EXISTS FOR. pix.recast writes its state file with
# `atomicWrites: false` (Service.qml flushState) precisely so its inotify
# watchers see the change -- which means the file is briefly truncated while it
# is rewritten. Two readers were treating that window as "the recording
# stopped":
#
#   - applyState()'s empty-string branch assigned recording = false and reset
#     every field
#   - the FileView's onLoadFailed did the same
#
# So a poll landing in that window made recastActive flicker false for a frame.
# That is worse than a stale chip: stripSpecialFace is gated on
# `!pill.recastActive`, so the accent-bordered special face appeared in the
# same frame the REC face vanished. The pill swapped faces mid-take and read as
# two overlapping pills.
#
# Measured off a screen recording of the bug: the REC face's red pixel count
# went 165 -> 0 -> 31 across the take, with the accent pixel count jumping on
# the frame the REC face disappeared.
#
# The contract: an unreadable or empty read is not evidence that anything
# changed. Keep the last good state; the next successful read carries the truth,
# including a real `idle` when a session really ends.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
RECAST="$ROOT/Singletons/Recast.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$RECAST" ] || { echo "no Recast.qml at $RECAST" >&2; exit 1; }

apply_block="$(sed -n '/function applyState(raw)/,/^        try {/p' "$RECAST")"
[ -n "$apply_block" ] || { echo "could not locate the empty-read branch" >&2; exit 1; }

# The empty read must return without touching any state field.
ok "the empty-read branch returns early" \
    "$(printf '%s' "$apply_block" | grep -c 'return;')" "1"

for field in recording paused serviceElapsed serviceElapsedAtMs _lastShownElapsed countdownPending; do
    n="$(printf '%s' "$apply_block" | grep -c "root\.$field *=")"
    if [ "$n" = "0" ]; then
        printf 'PASS empty read does not clear %s\n' "$field"
    else
        failed=$((failed + 1))
        printf 'FAIL empty read clears %s (%s assignment(s))\n' "$field" "$n"
    fi
done

# onLoadFailed must go through the same retention path, not reset behind it.
failed_block="$(sed -n '/onLoadFailed/,/^        }$/p' "$RECAST")"
[ -n "$failed_block" ] || { echo "could not locate onLoadFailed" >&2; exit 1; }

ok "onLoadFailed delegates to the same guarded path" \
    "$(printf '%s' "$failed_block" | grep -c 'root\.updateState()')" "1"

for field in recording paused serviceElapsed; do
    n="$(printf '%s' "$failed_block" | grep -c "root\.$field *=")"
    if [ "$n" = "0" ]; then
        printf 'PASS onLoadFailed does not clear %s\n' "$field"
    else
        failed=$((failed + 1))
        printf 'FAIL onLoadFailed clears %s (%s assignment(s))\n' "$field" "$n"
    fi
done

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'