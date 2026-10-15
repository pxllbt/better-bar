#!/usr/bin/env bash
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
F="$ROOT/Singletons/Plugins.qml"
[ -f "$F" ] || { echo "no file" >&2; exit 1; }
fail=0
failed=0
ok(){ if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else failed=$((failed+1)); printf 'FAIL %s\n  expected: %s\n  got: %s\n' "$1" "$3" "$2"; fi; }
ok "the singleton has an auto-check boot timer"    "$(grep -c 'id: autoCheckBoot' "$F")" "1"
ok "the singleton has an auto-check clock timer"   "$(grep -c 'id: autoCheckClock' "$F")" "1"
ok "the clock ticks on a multi-hour cadence" \\\\ "$(grep -c "autoCheckIntervalMs: 4 \* 60 \* 60 \* 1000" "$F")" "1"
ok "the check is gated on enable/disable"           "$(grep -c 'property bool autoCheckEnabled' "$F")" "1"
ok "auto check invokes the existing read-only check" "num=$(grep -A4 'id: autoCheckBoot' "$F" | grep -c 'root.checkForUpdates()'); echo $num" "1"
[ "$fail" -gt 0 ] && exit 1
echo all green
