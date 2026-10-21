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

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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
no() {
    if [ "$2" = "0" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  found %s occurrence(s), expected none\n' "$1" "$2"
    fi
}

[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# Pull every recastActive gate out whole. Both legitimately mention stripBar --
# one requires it, one forbids it -- so they are told apart by the `!`, not by
# the presence of the name.
mapfile -t gates < <(grep -oE 'visible: pill\.recastFaceVisible *( *&& *!?[A-Za-z.]*)?' "$PILL")

# ONE chip for both faces. There used to be two -- a strip copy and a
# "mirror" for the classic pill -- and the mirror never rendered at all, so
# the classic pill showed an EMPTY capsule for the whole of a recording: no
# REC, no countdown, no elapsed count. One chip, gated once, cannot drift
# from itself.
[ "${#gates[@]}" -eq 1 ] || {
    echo "expected exactly 1 REC face gate, found ${#gates[@]} -- a face is bypassing recastFaceVisible" >&2
    printf '  %s\n' "${gates[@]}" >&2
    exit 1
}

ok "the one REC face is NOT gated on the bar's mode" \
    "$(printf '%s\n' "${gates[@]}" | grep -c 'stripBar')" "0"

# --- the REC face must yield the pill to whatever owns it ------------------
# Nine slots already gate on `!Recast.recording`. The chip had no reciprocal, so
# a workspace-switch OSD while recording drew both and the pill read as doubled.
# recastFaceVisible is where that reciprocity has to live, or the two faces can
# each grow their own condition again.
# Exactly the declaration and its one continuation line. A range-to-blank-line
# slice swallows the properties declared immediately after it, which double-counts
# every owner name and makes the test pass or fail for the wrong reason.
# The declaration plus any CONTINUATION lines -- a line that starts with `&&`.
# A fixed -A1 slice swallows the property declared immediately after it, which
# made the check read a neighbouring declaration and fail for the wrong reason.
face_pred="$(awk '/readonly property bool recastFaceVisible/{f=1; print; next} f && /^[[:space:]]*&&/{print; next} f{exit}' "$PILL")"
[ -n "$face_pred" ] || { echo "could not find recastFaceVisible" >&2; exit 1; }

# The REC face yields to the two TRANSIENT overlays -- the OSD flash and the
# toast -- because those are on top of the pill and have to be readable.
#
# It does NOT yield to the special view. The special view is a PERSISTENT
# state (the Minimized stash, the scratchpad), and the special word that
# stands for it already stands down for a recording (`!recastActive`). When
# the chip yielded to the special view as well, the two excluded each other
# and EVERY element of the resting row hid itself at once: the chip (special
# view), the date and the time and the badge (recording), and the special word
# (recording). The pill went blank for the whole take. A recording is the more
# important thing to say, so the chip does not yield.
# The REC face yields to NOTHING.
#
# The OSD and the toast are separate layer surfaces drawn ON TOP of the pill,
# and they are not opaque -- so yielding to them left the pill as an empty
# outline with a translucent notification floating over the hole, and a
# recording running with no REC, no countdown and no elapsed count. It also
# cost the OSD its job: the OSD is sized and placed to read as ONE pill, and
# that only works when the pill's own content is still there under it.
#
# The special view is the same argument from the other side: the special word
# already stands down for a recording (`!recastActive`), so the two used to
# exclude each other and EVERY element of the resting row hid at once.
for owner in osdActive toastActive specialView; do
    ok "the REC face does NOT yield to $owner" \
        "$(printf '%s' "$face_pred" | grep -c "$owner")" "0"
done

ok "recastFaceVisible still requires an active recording" \
    "$(printf '%s' "$face_pred" | grep -c 'recastActive')" "1"

# The faces must gate on the predicate, not re-derive recastActive themselves.
ok "the face gates on the shared predicate, not raw recastActive" \
    "$(grep -c 'visible: pill.recastFaceVisible' "$PILL")" "1"
no "no face bypasses the shared predicate" \
    "$(grep -c 'visible: pill.recastActive' "$PILL")"

# --- one pill during a recording AND an OSD flash --------------------------
# The OSD is its OWN layer surface (surfaces/OsdPopup.qml). Its anchor is
# IDENTICAL to the pill's -- same parent, same top, same horizontal centre --
# so the two only read as one pill when they are also the same SIZE.
#
# A recording holds the pill open through heldOpen, so it is expanded. A
# workspace-switch flash then rendered the OSD at rest size beside the expanded
# REC face: two coincident boxes, differently sized, animating independently.
# (Not recording, the pill is at rest size, so the popup coincides with it --
# which is why it only ever read as one when nothing was being recorded.)
#
# The fix is not to suppress the flash, which is what a first attempt did: the
# workspace indicator vanished entirely during recording. Instead the recording
# yields the pill back while a flash is up, so the pill returns to rest size and
# the OSD fills exactly that box. Both stay visible, as one surface.
SHELL="$ROOT/shell.qml"
osd_gate="$(sed -n '/id: osdPopup/,/^                }$/p' "$SHELL" | grep 'suppressed:')"
[ -n "$osd_gate" ] || { echo "could not locate the osdPopup suppressed gate" >&2; exit 1; }
ok "the osdPopup surface exists and is gated" \
    "$(printf '%s' "$osd_gate" | grep -c 'suppressed:')" "1"
ok "the osdPopup gate includes the existing suppressors" \
    "$(printf '%s' "$osd_gate" | grep -c 'overlay\.surfaceOpen')" "1"
ok "the osdPopup gate suppresses on held" \
    "$(printf '%s' "$osd_gate" | grep -c 'pill\.held')" "1"
# The OSD must NOT be suppressed for a recording -- that was the fix that cost
# the workspace indicator.
no "the osdPopup is not blanket-suppressed while recording" \
    "$(printf '%s' "$osd_gate" | grep -c 'pill\.recastActive')"

# The recording yields the pill while a flash is up.
held_block="$(sed -n '/readonly property bool heldOpen/,/^$/p' "$PILL")"
[ -n "$held_block" ] || { echo "could not locate heldOpen" >&2; exit 1; }
ok "the recording yields the pill while an OSD is up" \
    "$(printf '%s' "$held_block" | grep -c 'pill\.recastActive && !osdActive')" "1"
ok "the yield is conditional, not unconditional" \
    "$(printf '%s' "$held_block" | grep -c 'recastActive && !osdActive')" "1"
# ...and the REC face itself still steps aside for the flash, so the pill is not
# left showing an empty expanded shell next to the OSD.
ok "the REC face still yields to the flash" \
    "$(grep -c 'recastFaceVisible: recastActive' "$PILL")" "1"

# And the pill's own shell yields to the flash.
#
# The Pill declaration in shell.qml already carries an opacity that hides it for
# an OSD, but it had a `!recastActive` exception in that clause: the pill stayed
# visible during a flash precisely when recording -- the one case where a second
# box was visible. Sharing an anchor with the OSD is not enough; the two are
# different sizes, so both have to not draw at once.
pill_opacity="$(grep -A1 'id: pill' "$SHELL" >/dev/null; sed -n '/id: pill/,/Behavior on opacity/p' "$SHELL" | grep 'opacity:')"
[ -n "$pill_opacity" ] || { echo "could not locate the pill opacity" >&2; exit 1; }

ok "the pill yields to the OSD" \
    "$(printf '%s' "$pill_opacity" | grep -c 'osdPopup\.active ? 0 : 1')" "1"
no "the yield has no recording exception" \
    "$(printf '%s' "$pill_opacity" | grep -c 'osdPopup\.active && !pill\.recastActive')"
ok "exactly one opacity is set on the pill" \
    "$(printf '%s' "$pill_opacity" | grep -c 'opacity:')" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'