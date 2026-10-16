#!/usr/bin/env bash
# The floating media island: the now-playing card hovers *above* a live strip
# instead of replacing it.
#
# This suite exists because of a specific, reproducible failure: in strip mode
# the card used to take over the pill's rect and input mask, which (a) made the
# bar's other cells unclickable while it was up, and (b) meant it could open
# once and never again — every re-show trigger lived on an element the card
# itself suppressed. Both symptoms were reported as separate bugs and are the
# same bug here.
set -u

ROOT="${1:-.}"
PILL="$ROOT/Pill.qml"
SHELL="$ROOT/shell.qml"
MEDIA="$ROOT/surfaces/Media.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

for f in "$PILL" "$SHELL" "$MEDIA"; do
    [ -r "$f" ] || { printf 'missing %s\n' "$f" >&2; exit 1; }
done

# --- the island exists, and only where it should -------------------------
ok "the island is gated on strip mode" \
    "$(grep -c 'mediaFloats: pill.stripBar' "$PILL")" "1"

# Game mode hands the whole bar to the game; an island hovering over it would be
# a target the game does not know about.
ok "the island declines while a plug-in surface is up" \
    "$(grep -A2 'mediaFloats: pill.stripBar' "$PILL" | grep -c '!pill.pluginSurfaceOpen')" "1"

ok "the island declines during a screen recast" \
    "$(grep -A2 'mediaFloats: pill.stripBar' "$PILL" | grep -c '!pill.recastActive')" "1"

# --- the pill must NOT shrink to the card while it floats -----------------
# The size thunk is the load-bearing line: if this returns the card size the
# strip collapses to a card-wide sliver and there is no bar left to float over.
SIZE_LINE=$(grep 'media:     {' "$PILL")
ok "the pill keeps its strip size while the island floats" \
    "$(printf '%s' "$SIZE_LINE" | grep -c 'mediaFloats ? restSize')" "1"

ok "the card size is still used when the island does not float" \
    "$(printf '%s' "$SIZE_LINE" | grep -c 'Qt.size(mediaW, mediaH)')" "1"

# --- the bar stays alive ------------------------------------------------
# Both strip rows, not just the main one: the special-view row is what the
# layout menu renders into, and hiding it would strand that menu too.
ok "the strip face stays visible under the island" \
    "$(grep -c '!pill.surfaceOpen || pill.pluginPopupOpen || pill.mediaFloats' "$PILL")" "2"

ok "the strip face still yields to game mode" \
    "$(grep -c 'pill.mediaFloats) && !Flags.gameMode' "$PILL")" "1"

# --- the resting face must not fade out under the island -----------------
# This is the bug that actually shipped, and it is worth its own assertion
# because the `visible` binding above was already correct while the strip still
# vanished. `rest` is the strip face's *parent*, and it faded the whole
# resting face to zero opacity whenever any surface opened — and because its own
# `visible` follows that opacity, the subtree went invisible rather than merely
# transparent. Keeping `stripFace.visible` true was not enough; the container
# above it had to be exempted too.
REST=$(sed -n '/id: rest$/,/Behavior on opacity/p' "$PILL")
ok "the resting face holds its opacity while the island floats" \
    "$(printf '%s\n' "$REST" | grep -c '!pill.pluginPopupOpen && !pill.mediaFloats')" "1"

ok "the resting face still fades for a real takeover" \
    "$(printf '%s\n' "$REST" | grep -c 'pill.expanded && !pill.pluginPopupOpen && !pill.mediaFloats')" "1"

# --- dismissal belongs to the bar, not the card --------------------------
# The card's own leave-guard would otherwise fire the moment the pointer glided
# from the island down onto the strip — which is the gesture for reaching the
# bar's cells, and would dismiss the island out from under it.
ok "the card's leave-guard stands down while floating" \
    "$(grep -c 'root.open && !root.floats && Flags.expandTo' "$MEDIA")" "1"

ok "the island is dismissed by leaving the bar" \
    "$(grep -c 'id: islandDismiss' "$PILL")" "1"

ok "leaving the bar arms that dismissal" \
    "$(grep -c 'if (pill.mediaFloats && !pinned && !hoverLatch' "$PILL")" "1"

ok "the dismissal declines while the pointer is still inside" \
    "$(sed -n '/id: islandDismiss/,/^    }/p' "$PILL" | grep -c '!pill.hovered')" "1"

ok "the dismissal declines in game mode" \
    "$(sed -n '/id: islandDismiss/,/^    }/p' "$PILL" | grep -c 'pill.mode !== "game"')" "1"

# Re-entering must cancel a pending dismissal, or stepping out and back strobes.
ok "re-entering the bar cancels a pending island dismissal" \
    "$(grep -c 'islandDismiss.stop()' "$PILL")" "1"

# --- the window's hover signal must survive the surface ------------------
# The original "opens once" mechanism: this handler was disabled while any
# surface was open, so the first open killed the only signal later opens needed.
ok "the window hover handler stays alive for the island" \
    "$(grep -c '!overlay.surfaceOpen || pill.mediaFloats' "$SHELL")" "1"

# --- the island needs its own input region -------------------------------
# Without one the island is drawn but not clickable, and the pointer cannot even
# reach it, so the leave-handler could never fire.
ok "the island has its own input region" \
    "$(grep -c 'width: pill.mediaFloats ? pill.islandW : 0' "$SHELL")" "1"

ok "that region spans the island's height" \
    "$(grep -c 'height: pill.mediaFloats ? pill.islandH : 0' "$SHELL")" "1"

ok "the region is mapped out of pill coordinates" \
    "$(grep -c 'x: pill.x + pill.islandX' "$SHELL")" "1"

# --- re-show must not depend on hover events -----------------------------
# Every hover signal available while the card is up belongs to an element the
# card suppresses, so the condition is polled instead of event-driven.
ok "the re-show condition is polled, not event-driven" \
    "$(grep -c 'id: mediaShowWatch' "$PILL")" "1"

ok "the watchdog repeats" \
    "$(grep -A2 'id: mediaShowWatch' "$PILL" | grep -c 'repeat: true')" "1"

ok "the watchdog only runs while the pointer is in the bar" \
    "$(grep -A3 'id: mediaShowWatch' "$PILL" | grep -c 'pill.hovered && pill.hasMedia')" "1"

ok "the watchdog re-checks through the one predicate" \
    "$(sed -n '/id: mediaShowWatch/,/^    }/p' "$PILL" | grep -c 'pill.checkMediaHover()')" "1"

# --- explicit dismissal must stick ---------------------------------------
# The latch is the only "no". Without it the watchdog would spring the card back
# under the very pointer that dismissed it, which is worse than never opening.
ok "the predicate respects the explicit-dismiss latch" \
    "$(sed -n '/function checkMediaHover/,/^    }/p' "$PILL" | grep -c '!surfaceDismissLatch')" "1"

ok "the latch is cleared when the pointer re-enters the bar" \
    "$(grep -c 'surfaceDismissLatch = false;' "$PILL")" "3"

ok "the latch is cleared on hover exit too" \
    "$(grep -A3 'onHoveredChanged: {' "$PILL" | grep -c 'surfaceDismissLatch = false')" "1"

# --- the island's own openness -------------------------------------------
# In strip mode the pill's morphCloseness never moves (the strip does not
# resize), so without a curve of its own the card snaps to fully drawn
# mid-slide.
ok "the island animates its own openness" \
    "$(grep -c 'Behavior on islandCloseness' "$PILL")" "1"

ok "that openness follows the float state" \
    "$(grep -c 'islandCloseness: pill.mediaFloats ? 1 : 0' "$PILL")" "1"

# The card squares its top corners to sit flush against the screen edge in
# strip mode. Floating, it hangs off that edge, so squaring it squares it
# against nothing.
ok "the card stops squaring its top while floating" \
    "$(grep -c 'topFlat: (pill.mode === "game") ? 1 : 0' "$PILL")" "1"

if [ "$failed" -eq 0 ]; then
    printf 'all green\n'
    exit 0
fi
printf '%d failing\n' "$failed"
exit 1