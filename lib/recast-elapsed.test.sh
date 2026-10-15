#!/usr/bin/env bash
# Asserts the recast chip's elapsed count cannot rewind, and that computing it
# does not bind a property to a write of its own dependencies.
#
# The bug this exists for: `recordingElapsed` was published in state.json with
# no indication of when it had been measured, so this file had to guess. It
# guessed "now" -- every re-anchor stamped `Date.now()` against whatever count
# the read happened to return. The service rewrites the file once a second while
# this singleton polls every 5s, so a read that landed one second behind the
# live count re-anchored that stale value as if it were current and the chip
# snapped backwards a second, then carried on counting from the rewound base:
# the reported "freezes for a second, then it keeps counting" stutter.
#
# The guard that was supposed to prevent this compared the incoming count
# against the last *read* count (`readElapsed < root.serviceElapsed`) rather
# than against what is actually on screen, so it never saw the rewind -- the
# display had already moved past the stale value via the local clock.
#
# The fix anchors on the service's own stamp (`recordingElapsedAtMs`, published
# by pix.recast beside the count) and ratchets through `_lastShownElapsed`, so a
# late or out-of-order snapshot can no longer move the chip backwards.
#
# The second bug, found live in the session log: the ratchet was assigned
# *inside* `elapsed`'s own binding, which also read `_lastShownElapsed`. A
# binding that writes a property it reads re-runs itself on every write, so
# Quickshell logged "Binding loop detected for property "elapsed"". The ratchet
# now lives in an explicit slot and `elapsed` is a pure read of it.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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
no() {
    if [ "$2" = "0" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  found %s occurrence(s), expected none\n' "$1" "$2"
    fi
}
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$RECAST" ] || { echo "no Recast.qml at $RECAST" >&2; exit 1; }

# `elapsed` is a one-line pure read, so the block is the line itself and not a
# brace range -- a range would swallow the handlers that follow it and the
# "assigns nothing" check below would read their writes as the binding's.
elapsed_block="$(sed -n '/readonly property int elapsed/p' "$RECAST")"
[ -n "$elapsed_block" ] || { echo "could not locate the elapsed binding" >&2; exit 1; }
ratchet_block="$(sed -n '/function refreshElapsed()/,/^    }$/p' "$RECAST")"
[ -n "$ratchet_block" ] || { echo "could not locate the refreshElapsed function" >&2; exit 1; }
apply_block="$(sed -n '/function applyState(raw)/,/^    }$/p' "$RECAST")"
[ -n "$apply_block" ] || { echo "could not locate applyState" >&2; exit 1; }

# --- the loop itself ---------------------------------------------------------
# The one that matters: a readonly binding must not assign anything. If someone
# moves the ratchet back inside the binding, this fails and the live log's
# "Binding loop detected for property "elapsed"" comes back with it.
no "the elapsed binding assigns nothing" \
    "$(printf '%s' "$elapsed_block" | grep -cE '=\s|=[^=]')"
ok "the elapsed binding is a pure read of the ratchet" \
    "$(printf '%s' "$elapsed_block" | grep -c '_lastShownElapsed')" "1"

# --- the anchor --------------------------------------------------------------
# The anchor must come from the file's stamp, not from this process's clock.
has "the service's measurement stamp is read" \
    "$(grep -c 'data\.recordingElapsedAtMs' "$RECAST")" "data.recordingElapsedAtMs"

# A file from an older plugin has no stamp; it must degrade to "now" rather than
# to 0, which would extrapolate from the epoch and render an absurd count.
ok "a missing stamp falls back to now" \
    "$(grep -c 'data\.recordingElapsedAtMs > 0' "$RECAST")" "1"

# --- the ratchet -------------------------------------------------------------
# The display is ratcheted: it shows the running maximum rather than the raw
# projection, so no late snapshot can rewind it. Exactly one write advances it.
ok "the ratchet advances in exactly one place" \
    "$(printf '%s' "$ratchet_block" | grep -c '_lastShownElapsed =')" "1"

ok "the ratchet field is declared" \
    "$(grep -c 'property int _lastShownElapsed: 0' "$RECAST")" "1"

# The ratchet must be cleared wherever the session ends, or the next take would
# inherit the previous one's count.
# Two mechanisms, not one magic count. The field has been named both ways and
# the reset sites have moved between them, so each is asserted directly.
#   -- applyState's idle branch, for a session that ends on a real read
#   -- refreshElapsed's `projected === 0` branch, for the change handler
# Note an empty/truncated read must reset NOTHING: see recast-truncated-state.
ok "applyState clears the ratchet on the idle branch" \
    "$(sed -n '/function applyState(raw)/,/^    }$/p' "$RECAST" | grep -cE '_(elapsedFloor\.v|lastShownElapsed) = 0')" "1"

ok "refreshElapsed clears the ratchet when the session is over" \
    "$(printf '%s' "$ratchet_block" | grep -c 'projected === 0')" "1"

# A finished session must reset rather than hold: `projected === 0` is the reset
# branch, and without it the next take opens on the previous take's count.
ok "an exhausted session resets the ratchet" \
    "$(printf '%s' "$ratchet_block" | grep -c 'projected === 0')" "1"

# The old broken comparison must be gone: anchoring a stale read against the
# last read is what let the rewind through in the first place.
no "the last-read comparison is gone" \
    "$(grep -c 'readElapsed < root\.serviceElapsed' "$RECAST")"

# Paused sessions show a count too, and used to fall through to a bare
# `serviceElapsed`, which froze the chip for the whole pause.
has "a paused session keeps the projected count" \
    "$(printf '%s' "$(sed -n '/function projectedElapsed()/,/^    }$/p' "$RECAST")" \
        | grep -c 'root\.recording || root\.paused')" "root.recording || root.paused"

# The ratchet slot has to be driven: a timer that only bumps a counter leaves
# the displayed value frozen at whatever the last state read produced.
ok "the ratchet slot is driven from every path that can change it" \
    "$(grep -c 'root\.refreshElapsed()' "$RECAST")" "5"

# And the state path: a poll landing on a new count must show it without
# waiting for the next whole-second tick.
has "a state change advances the ratchet" \
    "$(grep -c 'onServiceElapsedChanged: root\.refreshElapsed()' "$RECAST")" "onServiceElapsedChanged"

# --- the epoch guard ---------------------------------------------------------
# THE BUG THIS SECTION EXISTS FOR.
#
# `projectedElapsed()` projected drift as
# `serviceElapsed + (Date.now() - serviceElapsedAtMs) / 1000`. That is correct
# only when the anchor is non-zero. While it is 0 -- which is exactly its value
# from startup until the first stamped snapshot -- the drift term is
# `Date.now() / 1000`, i.e. ~1.79e9 seconds. formattedTime() then rendered that
# as "497743:59:21" on the chip, which is the epoch in h:m:s.
#
# It was reachable because applyState assigned `recording` 22 lines BEFORE the
# `serviceElapsed`/`serviceElapsedAtMs` pair. That assignment fires
# `onRecordingChanged` -> `refreshElapsed()` synchronously, so the projection
# ran against the stale zero anchor.
#
# Two independent guards, because one is not enough:
#   1. projectedElapsed() refuses to project from a zero anchor.
#   2. applyState sets the pair before it flips `recording`, so the change
#      handler never observes an unset anchor.
# A third, `_maxPlausibleElapsed`, bounds the damage if a future change manages
# to produce a nonsense anchor some other way: a take is measured in minutes to
# hours, never in centuries.
proj_block="$(sed -n '/function projectedElapsed()/,/^    }$/p' "$RECAST")"
ok "projection refuses to run against a zero anchor" \
    "$(printf '%s' "$proj_block" | grep -cE 'serviceElapsedAtMs (<=|>|===|!==) 0|!\(root\.serviceElapsedAtMs > 0\)')" "1"

# Twice by design: the zero-anchor path returns the raw count, and so does the
# over-the-ceiling path. Neither may ever return a projected value.
ok "a zero anchor projects to the raw count, not the epoch" \
    "$(printf '%s' "$proj_block" | grep -c 'return root\.serviceElapsed;')" "2"

ok "there is a plausibility ceiling on the projection" \
    "$(grep -c '_maxPlausibleElapsed' "$RECAST")" "3"

# The ordering guard: the pair must be written before `recording` flips, or the
# synchronous change handler reads the previous anchor again.
ok "the anchor is assigned before recording flips" \
    "$(printf '%s' "$apply_block" \
        | awk '/root\.serviceElapsedAtMs = /{seen=1} /root\.recording = \(st/{exit} END{print (seen?"ok":"no")}' \
        | grep -c '^ok$')" "1"

# --- the countdown -----------------------------------------------------------
# Pre-roll counts down off the service's own stamp too, so it is smooth between
# polls. It must re-anchor on a fresh value rather than drift against a stale
# one, or a restart of the countdown leaves the old anchor in place.
has "the countdown re-anchors on a fresh value" \
    "$(grep -c 'serviceCountdownAtMs = Date.now()' "$RECAST")" "serviceCountdownAtMs = Date.now()"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
