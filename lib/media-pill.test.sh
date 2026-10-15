#!/usr/bin/env bash
set -uo pipefail

ROOT="${1:-$(dirname "$(dirname "$0")")}"
MEDIA="$ROOT/surfaces/Media.qml"
CAVA="$ROOT/Singletons/Cava.qml"
PILL="$ROOT/Pill.qml"
STRIP_LAYOUT_FILE="$ROOT/Singletons/StripLayout.qml"
LINK_FILE="$ROOT/surfaces/Link.qml"
TOAST_FILE="$ROOT/surfaces/Toast.qml"
NOTIFS_FILE="$ROOT/Singletons/Notifs.qml"
FLAGS="$ROOT/Singletons/Flags.qml"
MB="$ROOT/components/MusicBars.qml"
DSURFACE="$ROOT/surfaces/DisplaySurface.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$MEDIA" ] || { echo "no Media.qml at $MEDIA" >&2; exit 1; }
[ -f "$CAVA" ] || { echo "no Cava.qml at $CAVA" >&2; exit 1; }
[ -f "$PILL" ] || { echo "no Pill.qml at $PILL" >&2; exit 1; }

# 1. expandCtl inside infoCol does not use parent.height (avoids Column infinite polish loop)
loop_height=$(grep -A5 'id: expandCtl' "$MEDIA" | grep -c 'height: parent\.height' || true)
ok "expandCtl does not use parent.height (no Column polish loop)" "$loop_height" "0"

# 2. expandCtl inside Column does not anchor to parent
loop_anchor=$(grep -A5 'id: expandCtl' "$MEDIA" | grep -c 'anchors\.left: parent\.left' || true)
ok "expandCtl does not anchor to parent inside Column" "$loop_anchor" "0"

# 3. expandCtl has an explicit scaled height
has_height=$(grep -A5 'id: expandCtl' "$MEDIA" | grep -c 'height: 15 \* root\.s' || true)
ok "expandCtl has explicit scaled height" "$has_height" "1"

# 4. leaveGuard does not close immediately without prior hover
has_was_hovered=$(grep -c 'property bool wasHovered' "$MEDIA" || true)
ok "leaveGuard tracks wasHovered to prevent instant dismissal" "$has_was_hovered" "1"

# 5. bool properties are guarded against undefined
undefined_seek=$(grep -A5 'id: seekArea' "$MEDIA" | grep -c 'enabled: Boolean(root.hasPlayer' || true)
ok "seekArea.enabled is guarded with Boolean(...)" "$undefined_seek" "1"

# 6. Cava does not set moved = flat (avoids 30Hz levels churn on silence)
cava_silence_bug=$(grep -c 'let moved = flat;' "$CAVA" || true)
ok "Cava levels update does not have silence churn bug" "$cava_silence_bug" "0"

# 6a. Strip face has hover handler for workspace pulse
has_strip_hover=$(grep -c 'id: stripFaceMouse' "$PILL" || true)
ok "Strip face has hover handler for workspace pulse" "$has_strip_hover" "1"

# 6b. Workspaces has pulseMode for clock-hover effect
WS_FILE="$ROOT/components/Workspaces.qml"
has_pulse_mode=$(grep -c 'pulseMode' "$WS_FILE" || true)
ok "Workspaces supports pulseMode for strip-hover effect" "$has_pulse_mode" "4"

# 6c. Battery bolt has charging pulse animation
has_charge_pulse=$(grep -A20 'id: stripBat' "$PILL" | grep -c 'SequentialAnimation on scale' || true)
ok "Battery charging icon pulses with infinite animation" "$has_charge_pulse" "1"

# 6d. Strip clock elements scale on hover
has_strip_scale=$(grep -c 'scale: pill.stripHover' "$PILL" || true)
ok "Strip clock elements scale on strip hover" "$has_strip_scale" "2"

# 7. Pill handles desktop without battery in stripFixedW
has_bat_guard=$(grep -c 'Battery.present ? stripBat.implicitWidth : 0' "$PILL" || true)
ok "Pill stripFixedW guards Battery.present" "$has_bat_guard" "1"

# 8. Pill has surfaceDismissLatch to prevent immediate re-trigger on dismiss
has_dismiss_latch=$(grep -c 'property bool surfaceDismissLatch' "$PILL" || true)
ok "Pill declares surfaceDismissLatch" "$has_dismiss_latch" "1"

# 9. Pill onHoveredChanged checks !pill.stripBar and !surfaceDismissLatch
has_hover_guard=$(grep -A5 'onHoveredChanged:' "$PILL" | grep -c '!surfaceDismissLatch' || true)
ok "Pill onHoveredChanged respects surfaceDismissLatch" "$has_hover_guard" "1"

has_strip_guard=$(grep -A5 'onHoveredChanged:' "$PILL" | grep -c '!pill.stripBar' || true)
ok "Pill onHoveredChanged ignores stripBar mode from auto-opening media" "$has_strip_guard" "1"

# 10. Strip media art and title are clickable to open media
strip_art_click=$(grep -A20 'id: stripArtMouse\b' "$PILL" | grep -c 'pill\.requestSurface("media")' || true)
ok "stripArt is clickable to request media surface" "$strip_art_click" "1"

strip_title_click=$(grep -A20 'id: stripTitleMouse\b' "$PILL" | grep -c 'pill\.requestSurface("media")' || true)
ok "stripTitle is clickable to request media surface" "$strip_title_click" "1"

# 11. Media quick controls (middle click play/pause and wheel volume)
has_middle_play=$(grep -A20 'id: stripArtMouse\b' "$PILL" | grep -c 'togglePlaying' || true)
ok "stripArtMouse handles middle click togglePlaying" "$has_middle_play" "1"

has_wheel_vol=$(grep -A20 'id: stripTitleMouse\b' "$PILL" | grep -c 'onWheel:' || true)
ok "stripTitleMouse handles wheel volume adjustment" "$has_wheel_vol" "1"

# 12. Workspace wheel navigation
[ -f "$WS_FILE" ] || { echo "no Workspaces.qml at $WS_FILE" >&2; exit 1; }
has_ws_wheel=$(grep -A10 'onWheel:' "$WS_FILE" | grep -c 'workspace e+1' || true)
ok "Workspaces handles wheel to cycle workspaces" "$has_ws_wheel" "1"

# 13. Keyboard layout badge cycle action
KB_FILE="$ROOT/components/KbLayout.qml"
[ -f "$KB_FILE" ] || { echo "no KbLayout.qml at $KB_FILE" >&2; exit 1; }
has_kb_cycle=$(grep -A5 'function cycle()' "$KB_FILE" | grep -c 'switchxkblayout' || true)
ok "KbLayout provides cycle function" "$has_kb_cycle" "1"

has_strip_lay_click=$(grep -A15 'id: stripLayMouse\b' "$PILL" | grep -c 'kbLayout\.cycle()' || true)
ok "stripLay connects to kbLayout.cycle()" "$has_strip_lay_click" "1"

# 14. Notification snooze feature
has_snooze_fn=$(grep -c 'function snoozeNotification' "$NOTIFS_FILE" || true)
ok "Notifs provides snoozeNotification function" "$has_snooze_fn" "1"

has_unsnooze_fn=$(grep -c 'function unsnooze' "$NOTIFS_FILE" || true)
ok "Notifs provides unsnooze function" "$has_unsnooze_fn" "1"

has_snoozed_prop=$(grep -c 'property var snoozed:' "$NOTIFS_FILE" || true)
ok "Notifs tracks snoozed notifications" "$has_snoozed_prop" "1"

has_snoozed_prop_live=$(grep -c 'readonly property var snoozedNotifications' "$NOTIFS_FILE" || true)
ok "Notifs exposes live snoozed notifications list" "$has_snoozed_prop_live" "1"

# 15. Toast surface has snooze controls
has_toast_snooze=$(grep -c 'Notifs.snoozeNotification' "$TOAST_FILE" || true)
ok "Toast surface triggers snooze on click" "$has_toast_snooze" "1"

# 16. Link surface shows snoozed section
has_link_snoozed=$(grep -c 'SNOOZED' "$LINK_FILE" || true)
ok "Link surface displays snoozed notifications section" "$has_link_snoozed" "1"

has_link_unsnooze=$(grep -c 'Notifs.unsnooze' "$LINK_FILE" || true)
ok "Link surface can unsnooze notifications" "$has_link_unsnooze" "1"

# 17. Ghost strip shows disabled plugins
has_disabled_prop=$(grep -c 'disabledBarWidgets' "$STRIP_LAYOUT_FILE" || true)
ok "StripLayout exposes disabled plugin list for ghost strip" "$has_disabled_prop" "1"

has_ghost_strip=$(grep -c 'ghostStripHover' "$PILL" || true)
ok "Pill renders ghost strip for disabled plugins" "$has_ghost_strip" "3"

has_ghost_click=$(grep -c 'Plugins.openOrEnable.*modelData' "$PILL" || true)
ok "Ghost strip icons enable plugins on click" "$has_ghost_click" "1"

# 18. Plugin health indicator for broken/uninstalled plugins
has_health_prop=$(grep -c 'property var health' "$ROOT/Singletons/Plugins.qml" || true)
ok "Plugins tracks per-plugin health status" "$has_health_prop" "1"

has_mark_health=$(grep -c 'function markHealth' "$ROOT/Singletons/Plugins.qml" || true)
ok "Plugins provides markHealth for broken plugin tracking" "$has_mark_health" "1"

has_reload=$(grep -c 'function reloadPlugin' "$ROOT/Singletons/Plugins.qml" || true)
ok "Plugins provides reloadPlugin for retry" "$has_reload" "1"

has_broken_ghost=$(grep -c 'brokenPlugins' "$PILL" || true)
ok "Pill shows broken plugins in ghost strip with retry" "$has_broken_ghost" "1"

has_load_status=$(grep -c 'onStatusChanged' "$ROOT/components/PluginButton.qml" || true)
ok "PluginButton reports loader status as plugin health" "$has_load_status" "1"

# 19. Strip keeps a centered visualizer while music plays, even with no media budget
has_float_viz=$(grep -c 'id: stripVizFloat$' "$PILL" || true)
ok "Strip has a floating centered visualizer" "$has_float_viz" "1"

float_center=$(grep -A8 'id: stripVizFloat' "$PILL" | grep -c 'anchors.centerIn: stripFace' || true)
ok "Floating visualizer is centered over the strip face" "$float_center" "1"

float_cond=$(grep -A8 'id: stripVizFloat' "$PILL" | grep -c 'Cava.active && Flags.musicViz && !pill.stripMedia' || true)
ok "Floating visualizer only appears while audio is active" "$float_cond" "1"

# 20. Visualizer style flag + wave style render path + settings row
has_style_flag=$(grep -c 'property alias musicStyle' "$FLAGS" || true)
ok "Visualizer style flag is persisted" "$has_style_flag" "1"

has_wave_style=$(grep -c 'visible: root.style === "wave"' "$MB" || true)
ok "MusicBars supports a waveform style" "$has_wave_style" "1"

has_style_row=$(grep -c 'id: vizStyleRow' "$DSURFACE" || true)
ok "Display surface exposes a visualizer style row" "$has_style_row" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%d media-pill checks failed\n' "$failed" >&2
    exit 1
fi

echo ""
echo "all media-pill checks passed"
