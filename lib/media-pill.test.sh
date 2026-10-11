#!/usr/bin/env bash
set -uo pipefail

ROOT="${1:-$(dirname "$(dirname "$0")")}"
MEDIA="$ROOT/surfaces/Media.qml"
CAVA="$ROOT/Singletons/Cava.qml"
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

# 7. Pill handles desktop without battery in stripFixedW
has_bat_guard=$(grep -c 'Battery.present ? stripBat.implicitWidth : 0' "$PILL" || true)
ok "Pill stripFixedW guards Battery.present" "$has_bat_guard" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%d media-pill checks failed\n' "$failed" >&2
    exit 1
fi

echo ""
echo "all media-pill checks passed"
