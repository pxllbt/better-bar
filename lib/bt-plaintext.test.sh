#!/usr/bin/env bash
# Device names must never reach a Text element that defaults to AutoText.
#
# The peer chooses its advertised name, so a nearby Bluetooth device controls
# the string. Qt's Text.textFormat defaults to AutoText, which sniffs the
# string for HTML and renders it as rich text; `QQuickText` then fetches any
# remote image referenced by an <img> tag before pairing, leaking the user's
# address and viewing time.
#
# The device-row label in BtSurface.qml is the site to pin down:
#   text: devItem.modelData ? (devItem.modelData.deviceName || ...) : "Unknown"
#
# The fix is textFormat: Text.PlainText at the display layer; the model keeps
# the raw name because the same string backs pair/connect/forget lookups.
#
# This test is repo-only and reads surfaces/BtSurface.qml directly.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
BT="$ROOT/surfaces/BtSurface.qml"

[ -f "$BT" ] || { echo "no BtSurface.qml at $BT" >&2; exit 1; }

failed=0

check_site() {
    local marker="$1" label="$2"
    local mark
    mark=$(grep -nF "$marker" "$BT" | head -1 | cut -d: -f1)
    if [ -z "$mark" ]; then
        failed=$((failed + 1))
        printf 'FAIL %s\n  marker not found: %s\n' "$label" "$marker"
        return
    fi

    local open
    open=$(awk -v m="$mark" '
        NR < m && /^[[:space:]]*Text[[:space:]]*\{/ { last = NR }
        END { print last }' "$BT")
    if [ -z "$open" ]; then
        failed=$((failed + 1))
        printf 'FAIL %s\n  no enclosing Text block for line %s\n' "$label" "$mark"
        return
    fi

    local block
    block=$(awk -v from="$open" '
        NR < from { next }
        { print
          n = gsub(/\{/, "{"); m = gsub(/\}/, "}")
          depth += n - m
          if (n > 0) opened = 1
          if (opened && depth <= 0) exit }' "$BT")

    if printf '%s\n' "$block" | grep -q 'textFormat: *Text\.PlainText'; then
        printf 'PASS %s\n' "$label"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  Text block at line %s (marker line %s) does not set textFormat: Text.PlainText\n' \
            "$label" "$open" "$mark"
    fi
}

check_site 'text: devItem.modelData ? (devItem.modelData.deviceName' \
    'the Bluetooth device-row label renders the device name as plain text'

if ! grep -q 'modelData.deviceName || devItem.modelData.name' "$BT"; then
    failed=$((failed + 1))
    printf 'FAIL the raw device name still feeds the label (not escaped at the source)\n'
else
    printf 'PASS the raw device name still feeds the label (not escaped at the source)\n'
fi

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
