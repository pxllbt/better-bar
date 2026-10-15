#!/usr/bin/env bash
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
F="$ROOT/Singletons/Plugins.qml"
[ -f "$F" ] || { echo "no file" >&2; exit 1; }
failed=0
ok() { if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else failed=$((failed + 1)); printf 'FAIL %s\n  exp: %s\n  got: %s\n' "$1" "$3" "$2"; fi; }
ok "auto-check boot timer exists"   "$(grep -c 'id: autoCheckBoot'     "$F")" "1"
ok "auto-check clock timer exists"  "$(grep -c 'id: autoCheckClock'    "$F")" "1"
ok "four-hour cadence in place"    "$(grep -cE '4 \* 60 \* 60 \* 1000' "$F")" "1"
ok "check is toggleable"            "$(grep -c 'property bool autoCheckEnabled' "$F")" "1"
ok "boot timer triggers the check" "$(grep -A4 'id: autoCheckBoot' "$F" | grep -c 'checkForUpdates()' )" "1"
[ "$failed" -gt 0 ] && { echo "${failed} failing"; exit 1; }
echo "all green"
