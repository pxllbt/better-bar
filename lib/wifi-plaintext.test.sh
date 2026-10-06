#!/usr/bin/env bash
# AP names must never reach a Text element that defaults to AutoText.
#
# The peer we rely on is broadcast by the access point itself, so an operator
# controls the string. Qt's Text.textFormat defaults to AutoText, which detects
# HTML in the string and renders it as rich text. `QQuickText` therefore loads
# remote images referenced by an <img> tag found in e.g. an SSID. Displaying the
# Wi-Fi list then makes a request to a URL the network operator chose before the
# user has ever connected, disclosing the user's address and viewing time.
#
# Two Text elements in WifiSurface.qml can carry such a name:
#   * the row label:    text: netItem.ssid.length ? netItem.ssid : "Hidden"
#   * the status label: text: "· " + root.statusText   (activeNet.name when up)
#
# The fix is to opt out of rich-text auto-detection at the display layer and
# keep the raw SSID in the model, because the same string feeds connection,
# forget, and known-profile lookups against nmcli where an escaped value would
# silently stop matching.
#
# The test copies are not supported: this file is repo-only and reads
# surfaces/WifiSurface.qml directly.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
WIFI="$ROOT/surfaces/WifiSurface.qml"

[ -f "$WIFI" ] || { echo "no WifiSurface.qml at $WIFI" >&2; exit 1; }

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

# For each marker line, walk back to the nearest opening `Text {` of the block
# that owns it and forward to the block's matching close, then require the block
# to opt out of rich text. A marker line the scan cannot locate in a block is a
# failure, not something to skip -- skips are how this test would go vacuous.
check_site() {
    local marker="$1" label="$2"
    local mark
    mark=$(grep -nF "$marker" "$WIFI" | head -1 | cut -d: -f1)
    if [ -z "$mark" ]; then
        failed=$((failed + 1))
        printf 'FAIL %s\n  marker not found: %s\n' "$label" "$marker"
        return
    fi

    local open
    open=$(awk -v m="$mark" '
        NR < m && /^[[:space:]]*Text[[:space:]]*\{/ { last = NR }
        END { print last }' "$WIFI")
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
          if (opened && depth <= 0) exit }' "$WIFI")

    if printf '%s\n' "$block" | grep -q 'textFormat: *Text\.PlainText'; then
        printf 'PASS %s\n' "$label"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  Text block at line %s (marker line %s) does not set textFormat: Text.PlainText\n' \
            "$label" "$open" "$mark"
    fi
}

check_site 'text: netItem.ssid.length ? netItem.ssid : "Hidden"' \
    'the Wi-Fi list row label renders the SSID as plain text'

check_site 'text: "· " + root.statusText' \
    'the status label renders the active network name as plain text'

# The raw SSID still has to reach nmcli: escaping it for display would silently
# break connect/forget/known lookups. Guard that the model feed is untouched.
ok "the network model key stays the raw name (not escaped at the source)" \
    "$(grep -c 'objectProp: "name"' "$WIFI")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'