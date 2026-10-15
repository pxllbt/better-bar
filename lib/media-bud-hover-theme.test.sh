#!/usr/bin/env bash
# Asserts the media bud is reachable by hover, and that it is painted from the
# same theme material as the pill it sits on.
#
# Why this exists: the bud shipped as a click-only target that also drifted out
# of the bar's palette. Both were silent — a click still worked, and the pill
# alone looked fine in a screenshot — so neither was visible in review.
#
# Hover: the bud only grew on `containsMouse`. Opening the player took a click,
# which is the one interaction the pill's own hover-to-media path already
# bypasses everywhere else.
#
# Theme: its LiquidGlass had no `themeBackgroundFill` and no `veil`, and the
# disc face was a hardcoded near-black. So the bud was the only element in the
# pill that ignored the palette — obvious the moment the theme changed, and
# invisible in a picture of the bar by itself.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PILL="$ROOT/Pill.qml"
DISC="$ROOT/components/MediaDisc.qml"

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
[ -f "$DISC" ] || { echo "no MediaDisc.qml at $DISC" >&2; exit 1; }

BUD=$(sed -n '/id: bud$/,/id: body$/p' "$PILL")
[ -n "$BUD" ] || { echo "could not locate the media bud" >&2; exit 1; }

# --- hover reaches the player ---------------------------------------------
ok "the bud arms a hover-open timer" \
    "$(printf '%s\n' "$BUD" | grep -c 'id: budHoverOpen')" "1"

ok "entering the bud starts that timer" \
    "$(printf '%s\n' "$BUD" | grep -c 'onEntered: budHoverOpen.restart()')" "1"

ok "leaving the bud cancels it, so a sweep does not open the player" \
    "$(printf '%s\n' "$BUD" | grep -c 'onExited: budHoverOpen.stop()')" "1"

ok "the timer still opens the media surface" \
    "$(printf '%s\n' "$BUD" | grep -c 'pill.requestSurface("media")')" "2"

ok "the hover dwell is long enough to ignore a pass-through" \
    "$(printf '%s\n' "$BUD" | grep -c 'interval: 260')" "1"

# The dwell must decline in exactly the cases the pill's own hover path does,
# or the two entry points disagree about when the player appears.
ok "the hover dwell declines while a surface is already open" \
    "$(printf '%s\n' "$BUD" | grep -c 'pill.surfaceOpen')" "1"
ok "the hover dwell declines in game mode" \
    "$(printf '%s\n' "$BUD" | grep -c 'pill.mode === "game"')" "1"

# --- the bud is built from the pill's material ----------------------------
ok "the bud sits on the theme background like the body" \
    "$(printf '%s\n' "$BUD" | grep -c 'themeBackgroundFill: true')" "1"

ok "the bud carries the body's readability veil" \
    "$(printf '%s\n' "$BUD" | grep -c 'veil: 0.06')" "1"

# --- the disc reads as theme, not as fixed black --------------------------
ok "the disc face is a theme surface, not a hardcoded grey" \
    "$(grep -c 'color: Theme.tileBg' "$DISC")" "1"

ok "the disc no longer paints a fixed near-black face" \
    "$(grep -c 'Qt.rgba(0.07, 0.07, 0.08' "$DISC")" "0"

ok "the spindle hub is derived from the theme surface" \
    "$(grep -c 'Qt.darker(Theme.tileBg' "$DISC")" "1"

ok "the disc no longer paints a fixed black hub" \
    "$(grep -c 'Qt.rgba(0, 0, 0, 0.9)' "$DISC")" "0"

# --- the card dismisses itself when nothing is playing --------------------
# The auto-dismiss block runs from its banner to the end of the Players
# Connections that follows it (before the next top-level handler). A wider range
# pulls in the bud and the hover handler below, which each mention the same
# tokens and inflate every count.
START=$(grep -n 'MEDIA AUTO-DISMISS' "$PILL" | head -1 | cut -d: -f1)
END=$(awk -v s="$START" 'NR>s && /^    onHoveredChanged: \{/ {print NR-1; exit}' "$PILL")
PILLBODY=$(sed -n "${START},${END}p" "$PILL")
[ -n "$PILLBODY" ] || { echo "could not locate the media auto-dismiss" >&2; exit 1; }

ok "the media card arms an auto-dismiss timer" \
    "$(printf '%s\n' "$PILLBODY" | grep -c 'id: mediaAutoDismiss')" "1"

ok "the dismiss fires only when there is no player at all" \
    "$(printf '%s\n' "$PILLBODY" | grep -c '!Players.has')" "3"

ok "the dismiss never fires in game mode" \
    "$(printf '%s\n' "$PILLBODY" | grep -c 'pill.mode !== "game"')" "1"

ok "starting playback cancels the pending dismiss" \
    "$(printf '%s\n' "$PILLBODY" | grep -c 'mediaAutoDismiss.stop()')" "2"

ok "a paused track keeps the card, so it is not gated on playing" \
    "$(printf '%s\n' "$PILLBODY" | grep -c '!Players.playing')" "0"

ok "closing the card disarms the timer" \
    "$(grep -A3 'onMediaOpenChanged' "$PILL" | grep -c 'mediaAutoDismiss.stop()')" "1"

ok "a fresh open on silence arms it immediately" \
    "$(grep -A5 'onMediaOpenChanged' "$PILL" | grep -c 'mediaAutoDismiss.restart()')" "1"

ok "the bud is unaffected, so mediaAlways still keeps the entry" \
    "$(printf '%s\n' "$BUD" | grep -c 'Flags.mediaAlways')" "1"

# --- the bud is findable, not marooned at the far edge --------------------
ok "the bud moves next to the media title in strip mode" \
    "$(printf '%s\n' "$BUD" | grep -c 'pill.stripBar' )" "1"

ok "the bud placement maps the title into pill coordinates" \
    "$(printf '%s\n' "$BUD" | grep -c 'stripTitle.mapToItem(pill' )" "1"

ok "the bud still sits on the pill edge outside strip mode" \
    "$(printf '%s\n' "$BUD" | grep -c 'pill.width - budR')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
