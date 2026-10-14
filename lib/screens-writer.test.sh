#!/usr/bin/env bash
# Asserts that `scripts/screens.sh persist` rewrites each output's own
# hl.monitor({...}) block in monitors.lua in place, matches the lib/monitors.js
# oracle byte-for-byte, and writes safely (atomic mv, timestamped backup,
# restore-on-failure).
#
# Why this exists: monitors.lua is parsed by Hyprland at every boot, so a
# half-written or malformed persist would brick the next login. Two things are
# pinned: (a) the rewrite is byte-identical to lib/monitors.js
# setMonitor/appendMonitor -- the test-only reference the plan names "the
# behaviour oracle" -- outside the three changed fields; and (b) the write can
# never leave a broken file behind.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT/scripts/screens.sh"
FIXTURE="$ROOT/lib/fixtures/monitors.lua"
MONITORS_JS="$ROOT/lib/monitors.js"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find at least one match\n' "$1"
    fi
}

[ -f "$SCRIPT" ] || { echo "no scripts/screens.sh" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "no fixtures/monitors.lua" >&2; exit 1; }
[ -f "$MONITORS_JS" ] || { echo "no lib/monitors.js oracle" >&2; exit 1; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Fresh fixture copy per scenario so one persist can't poison the next.
fresh() { cp "$FIXTURE" "$SANDBOX/monitors.lua"; }

# Apply lib/monitors.js setMonitor per screen (mode/position/scale only) to the
# original fixture and print the resulting text. This is the oracle; the bash
# writer must reproduce it byte-for-byte.
expected_after() {
    node -e '
      const {setMonitor}=require(process.argv[1]);
      const fs=require("fs");
      let t=fs.readFileSync(process.argv[2],"utf8");
      const screens=JSON.parse(process.argv[3]).screens||[];
      for (const s of screens) {
        if (!s.output) continue;
        const r=setMonitor(t, s.output, s.mode, s.position, Number(s.scale));
        if (r.ok) t=r.text;
      }
      process.stdout.write(t);
    ' "$MONITORS_JS" "$FIXTURE" "$1"
}

run_persist() {
    printf '%s' "$1" | env MONITORS_LUA="$SANDBOX/monitors.lua" bash "$SCRIPT" persist
}

# Layouts. transform/mirror are default here: the writer follows the oracle and
# persists only mode/position/scale (transform/mirror stay live-only; see report).
L_desc='{"version":1,"screens":[{"output":"desc:HKC OVERSEAS LIMITED S01","mode":"1920x1080@60","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true}]}'
L_new='{"version":1,"screens":[{"output":"HDMI-A-1","mode":"2560x1440@144","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true}]}'
L_both='{"version":1,"screens":[{"output":"desc:HKC OVERSEAS LIMITED S01","mode":"1920x1080@60","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true},{"output":"HDMI-A-1","mode":"2560x1440@144","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true}]}'

# 1. Rewriting the desc output changes only its mode/position/scale; the header
#    comment, omarchy_gdk_scale, the GDK_SCALE line, the desc rationale comment,
#    the commented DP-2 examples and the catch-all fallback stay byte-identical
#    to the oracle.
fresh
run_persist "$L_desc" >/dev/null 2>&1; rc=$?
ok "persist exits 0 on a real write" "$rc" "0"
exp=$(expected_after "$L_desc")
act=$(cat "$SANDBOX/monitors.lua")
ok "desc rewrite is byte-identical to the monitors.js oracle" "$act" "$exp"
ok "desc mode was rewritten to the new value" "$(grep -c 'mode = "1920x1080@60"' "$SANDBOX/monitors.lua")" "1"
ok "desc old mode is gone" "$(grep -c 'mode = "1920x1080@100"' "$SANDBOX/monitors.lua")" "0"
ok "header comment preserved" "$(grep -c 'List current monitors and supported resolutions' "$SANDBOX/monitors.lua")" "1"
ok "catch-all fallback preserved" "$(grep -c 'Fallback for any monitor' "$SANDBOX/monitors.lua")" "1"
ok "commented DP-2 examples preserved" "$(grep -c 'hl.monitor({ output = "DP-2"' "$SANDBOX/monitors.lua")" "2"

# 2. An output with no block gets one appended in the installer's field layout.
fresh
run_persist "$L_new" >/dev/null 2>&1; rc=$?
ok "persist exits 0 when appending" "$rc" "0"
exp=$(expected_after "$L_new")
act=$(cat "$SANDBOX/monitors.lua")
ok "new output is appended byte-identical to the oracle" "$act" "$exp"
has "an hl.monitor block naming HDMI-A-1 now exists" "$(grep -c 'output *= "HDMI-A-1"' "$SANDBOX/monitors.lua")"

# 3. After persisting desc + new, exactly one block per output.
fresh
run_persist "$L_both" >/dev/null 2>&1
exp=$(expected_after "$L_both")
act=$(cat "$SANDBOX/monitors.lua")
ok "both outputs persisted byte-identical to the oracle" "$act" "$exp"
ok "exactly one block for the desc output" "$(grep -c 'output = "desc:HKC OVERSEAS LIMITED S01"' "$SANDBOX/monitors.lua")" "1"
ok "exactly one block for HDMI-A-1" "$(grep -c 'output *= "HDMI-A-1"' "$SANDBOX/monitors.lua")" "1"

# 4. Idempotent: a second persist changes nothing.
fresh
run_persist "$L_desc" >/dev/null 2>&1; first=$(cat "$SANDBOX/monitors.lua")
run_persist "$L_desc" >/dev/null 2>&1; second=$(cat "$SANDBOX/monitors.lua")
exp=$(expected_after "$L_desc")
ok "idempotent: second pass matches the oracle" "$second" "$exp"
ok "idempotent: second pass changed nothing" "$second" "$first"

# 5. Read-only dir: original untouched, exit non-zero, no .tmp behind.
fresh
chmod a-w "$SANDBOX"
run_persist "$L_desc" >/dev/null 2>&1; rc=$?
ok "read-only dir: persist exits non-zero" "$rc" "1"
ok "read-only dir: original file untouched" "$([ "$(cat "$SANDBOX/monitors.lua")" = "$(cat "$FIXTURE")" ] && echo yes || echo no)" "yes"
ok "read-only dir: no .tmp behind" "$(ls "$SANDBOX"/monitors.lua.tmp* 2>/dev/null | wc -l | tr -d ' ')" "0"
chmod u+w "$SANDBOX"

# 6. A timestamped backup is created on a real write and equals the original.
fresh
run_persist "$L_desc" >/dev/null 2>&1
bak=$(ls "$SANDBOX"/monitors.lua.bak.* 2>/dev/null | head -1)
ok "a timestamped backup is created on write" "$([ -n "$bak" ] && echo yes || echo no)" "yes"
ok "the backup equals the original fixture" "$([ -n "$bak" ] && [ "$(cat "$bak")" = "$(cat "$FIXTURE")" ] && echo yes || echo no)" "yes"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
