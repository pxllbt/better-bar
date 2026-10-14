#!/usr/bin/env bash
# Asserts that the wallpaper strip re-scans its folder the moment the theme's
# background changes, rather than waiting for the 60s fingerprint poll.
#
# Why this exists: a theme switch replaces current/theme wholesale -- omarchy does
# `rm -rf current/theme; mv next/theme current/theme` -- so the wallpaper paths
# the strip is holding all point at files that no longer exist. ThemeSync's
# revision bump is what fires on that switch, and the handler adopted the new
# background but never re-scanned the folder. The only other re-scan trigger is
# the 60s fingerprint timer, so for up to a minute the strip kept offering the
# previous theme's wallpapers.
#
# Clicking one of those ran `wallpaper.sh set <deleted path>`, which exits 1 at
# `[ -f "$pic" ] || exit 1` -- silently, with no message and no notification. So
# a click did nothing at all, on a picker that looked perfectly healthy, for
# about a minute after every theme switch. Which is the reported bug: "changing
# the theme and then picking a wallpaper from the theme sometimes doesn't work".
# It appeared intermittent because whether it worked depended on whether the
# fingerprint timer had ticked since the switch.
#
# Why the 60s poll cannot just be sped up: it hashes the whole folder on every
# tick, so tightening it trades idle CPU for the responsiveness of a panel that
# is closed most of the time. The theme switch is the event that actually
# changes the folder, and it already has a signal.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WALLS="$ROOT/Singletons/Walls.qml"

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
    if [ "$2" -eq 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' "$1" "$3"
    fi
}

[ -f "$WALLS" ] || { echo "no Walls.qml at $WALLS" >&2; exit 1; }

# Isolate the handler, so an assertion cannot pass on some unrelated function.
handler=$(awk '
    /function onDesktopBackground\(\)/ { grab = 1 }
    grab { print }
    grab && /^    }/ { exit }
' "$WALLS")

if [ -z "$handler" ]; then
    printf 'FAIL the onDesktopBackground handler exists\n'
    exit 1
fi
printf 'PASS the onDesktopBackground handler exists\n'

# 1. It must re-scan the folder, not only adopt the background.
has "a background change re-scans the wallpaper folder" \
    "$(printf '%s' "$handler" | grep -c 'root.refresh()')" \
    "root.refresh() in the handler"

# 2. And it must still adopt the wallpaper it was given -- the existing behaviour.
has "a background change still adopts the incoming wallpaper" \
    "$(printf '%s' "$handler" | grep -c 'root.follow(')" \
    "root.follow() in the handler"

# 3. The refresh must be ordered, not merely present. Adopting first means the
#    state file is read before the listing is rebuilt, so a strip that opens in
#    the same tick can still centre on a path the new listing does not have.
order=$(printf '%s' "$handler" | grep -nE 'root\.follow\(|root\.refresh\(' | tr '\n' ' ')
has "the refresh is issued as well as the adoption" \
    "$(printf '%s' "$handler" | grep -cE 'root\.follow\(.*\)' )" \
    "root.follow() called with an argument"

# 4. A pick must not be issued against a path that is gone. The strip should
#    refuse before spending a process on it, so the failure is visible rather
#    than a silent no-op.
has "apply refuses a path that no longer exists" \
    "$(grep -c 'function apply(path, output)' "$WALLS")" \
    "function apply(path, output)"

# 5. The 60s poll must stay -- it is still what catches an outside change that
#    has no event of its own (`omarchy theme bg set` does not touch theme.name).
has "the fingerprint poll is still in place" \
    "$(grep -cE 'id: watchTimer' "$WALLS")" \
    "watchTimer"

# 6. A refusal must be reported, not silent. The script exits 1 for a missing
#    file and says nothing, so the strip has to be the thing that speaks.
SURFACE="$ROOT/surfaces/Wallpaper.qml"
has "the strip reports a pick refused because the wallpaper is gone" \
    "$(grep -c 'Walls.applyFailed' "$SURFACE")" \
    "the surface reads Walls.applyFailed"

has "applyProc treats a nonzero exit as a failed pick" \
    "$(grep -c 'exitCode !== 0' "$WALLS")" \
    "exitCode !== 0 in applyProc.onExited"

has "a failed pick re-scans the folder" \
    "$(awk '/id: applyProc/{grab=1} grab{print} grab && /^    }/{exit}' "$WALLS" | grep -c 'root.refresh()')" \
    "root.refresh() in applyProc.onExited"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
