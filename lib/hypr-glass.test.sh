#!/usr/bin/env bash
# Asserts the bar's glass follows the compositor instead of disagreeing with it.
#
# Why it exists: Better Bar drew its own glass, independent of Hyprland. The pill
# could be translucent and blurry while every window behind it was sharp and
# solid. That is not only inconsistent — on this box blur was switched off
# precisely to stop the whole screen diffusing over the bar, so a bar that blurs
# on its own is the failure the user already worked around.
#
# Following means agreeing on three things, not one: whether anything is glassy,
# how solid it is, and how round it is. Matching some of them and guessing the
# rest leaves the bar halfway between the desktop and itself, which is worse
# than either choice.
#
# The follow is read-only. A status bar pushing at the compositor is a surprise
# at best, so this asserts there is no writer anywhere near it.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SINGLETON="$ROOT/Singletons/HyprGlass.qml"
GLASS="$ROOT/components/LiquidGlass.qml"
SURFACE="$ROOT/surfaces/GlassSurface.qml"
QMLDIR="$ROOT/Singletons/qmldir"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$SINGLETON" ] || { echo "no Singletons/HyprGlass.qml" >&2; exit 1; }

# --- the singleton is reachable ------------------------------------------
ok "HyprGlass is registered as a singleton" \
    "$(grep -cE '^singleton[[:space:]]+HyprGlass[[:space:]]+HyprGlass\.qml$' "$QMLDIR")" "1"

# --- it reads the compositor, all of it at once --------------------------
ok "one read covers every value, because the combination is what matters" \
    "$(grep -c 'decoration:blur:enabled decoration:active_opacity' "$SINGLETON")" "1"
ok "it distinguishes 'blur is off' from 'we never managed to ask'" \
    "$(grep -c 'property bool usable' "$SINGLETON")" "1"
ok "an unread value falls back rather than being zeroed" \
    "$(grep -c 'if (act !== null && act >= 0 && act <= 1)' "$SINGLETON")" "1"
ok "it reads the value shapes hyprctl actually emits, not one assumed shape" \
    "$(grep -c 'obj.float !== undefined' "$SINGLETON")" "1"
ok "an unreadable answer does not masquerade as 'blur is off'" \
    "$(grep -c 'if (blur === null)' "$SINGLETON")" "1"
ok "nothing is read that the bar does not act on" \
    "$(grep -c 'blurSize\|inactiveOpacity\|pillRounding' "$SINGLETON")" "0"

# --- read-only, and provably so -----------------------------------------
# getoption cannot change anything, and the bug to guard is a bar that starts
# writing to the compositor's config because someone asked it to follow.
ok "the singleton runs only getoption, never setoption" \
    "$(grep -c 'setoption' "$SINGLETON")" "0"
ok "the singleton runs no hyprctl mutation at all" \
    "$(grep -ciE 'hyprctl.*(set|move|resize|dispatch)' "$SINGLETON")" "0"

# --- what following actually follows -------------------------------------
FLAGS="$ROOT/Singletons/Flags.qml"
ok "there is a flag for following the compositor" \
    "$(grep -c 'glassFollowHypr' "$FLAGS")" "1"

# The fill: HyprGlass.pillOpacity, which is the active value rather than the
# inactive one — matching the unfocused number would dim the bar below every
# window you are working in.
ok "the pill's opacity, when following, comes from Hyprland" \
    "$(grep -c 'HyprGlass.pillOpacity' "$GLASS")" "1"
ok "the follow picks the active value, not the unfocused one" \
    "$(grep -c 'root.activeOpacity : root.defaultOpacity' "$SINGLETON")" "1"
ok "following does not apply when Hyprland could not be read" \
    "$(grep -c 'Flags.glassFollowHypr && HyprGlass.usable' "$GLASS")" "1"

# Whether the glass material is drawn at all. This is the half that matters most
# here: with Hyprland's blur off, a glassy bar is the exact artifact the config
# was changed to avoid.
ok "the glassy material is gated on the compositor when following" \
    "$(grep -c 'glassFollowHypr' "$GLASS")" "3"
ok "the follow has an off switch, so it is a choice rather than a takeover" \
    "$(grep -c ': Flags.glass$' "$GLASS")" "1"

# --- the user can turn it off -------------------------------------------
ok "the Glass surface exposes the follow control" \
    "$(grep -c 'glassFollowHypr' "$SURFACE")" "3"
ok "the control writes the flag, so it can be switched back" \
    "$(grep -c 'Flags.glassFollowHypr = ' "$SURFACE")" "1"
# The manual control has to stand down while following, or it looks like it is
# setting an opacity that is silently overridden on the next read.
ok "the manual opacity row stands down while following" \
    "$(grep -A6 'id: bgRow' "$SURFACE" | grep -c 'enabled: !root.following')" "1"
ok "the surface reads whether following is live" \
    "$(grep -c 'Flags.glassFollowHypr && HyprGlass.usable\|(Flags.glassFollowHypr || false) && HyprGlass.usable' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'