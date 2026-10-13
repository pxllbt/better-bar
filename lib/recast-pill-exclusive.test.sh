#!/usr/bin/env bash
# The REC face must render exactly once, in whichever pill layout is active.
#
# THE BUG THIS EXISTS FOR: Pill.qml carries two recording faces.
#
#   stripRecordingBox  visible: pill.recastActive && pill.stripBar
#   the rest-row Item  visible: pill.recastActive
#
# The second was missing the `!pill.stripBar` half, so in strip mode -- the
# default -- both gates were true at once and the pill drew a second REC face
# on top of the first. Because the two faces size themselves independently from
# their own rows' implicitWidth, the duplicate is offset rather than coincident,
# which is what reads as a doubled, misaligned pill while recording (and is most
# obvious when a workspace switch re-lays-out the pill mid-recording).
#
# The invariant is mutual exclusion: exactly one of the two may be visible, for
# every combination of the two flags.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
PILL="$ROOT/Pill.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# Pull every recastActive gate out whole. Both legitimately mention stripBar --
# one requires it, one forbids it -- so they are told apart by the `!`, not by
# the presence of the name.
mapfile -t gates < <(grep -oE 'visible: pill\.recastActive *(&&) *!?[A-Za-z.]*' "$PILL")

[ "${#gates[@]}" -eq 2 ] || {
    echo "expected exactly 2 recastActive gates, found ${#gates[@]}" >&2
    printf '  %s\n' "${gates[@]}" >&2
    exit 1
}

strip_gate=""
rest_gate=""
for g in "${gates[@]}"; do
    if [[ "$g" == *"&& !pill.stripBar"* ]]; then
        rest_gate="$g"
    elif [[ "$g" == *"&& pill.stripBar"* ]]; then
        strip_gate="$g"
    fi
done

[ -n "$strip_gate" ] || { echo "no gate requiring stripBar" >&2; exit 1; }
[ -n "$rest_gate" ]  || { echo "no gate forbidding stripBar" >&2; exit 1; }

ok "the strip REC face is gated on stripBar" \
    "$(printf '%s' "$strip_gate" | grep -c '&& pill\.stripBar$')" "1"
ok "the rest-row REC face is gated on !stripBar" \
    "$(printf '%s' "$rest_gate" | grep -c '&& !pill\.stripBar$')" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'