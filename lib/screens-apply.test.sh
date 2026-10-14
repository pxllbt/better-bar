#!/usr/bin/env bash
# Asserts that scripts/screens.sh applies a layout through a single
# `hyprctl --batch` call and rescues from the last good one, refusing the
# apply before Hyprland is touched when it would leave no enabled screen.
#
# Why this exists: the Screens surface writes a layout JSON and pipes it to
# `screens.sh apply`, which must translate each screen into the right
# `keyword monitor` spec and ship them to the compositor in ONE hyprctl --batch
# round trip (one synchronous dispatch, not N), while never leaving a black
# desktop behind when a batch is rejected -- the failure must not blank the last
# good layout. This pins that contract so the surface and the model singleton
# can call it blindly.
#
# Optimisation note: every assertion here is also an optimisation gate. "Calls
# hyprctl --batch once" for two screens is the batch check -- if a future change
# regresses to one `hyprctl` per screen, this test turns it back into N calls.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT/scripts/screens.sh"

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
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$SCRIPT" ] || { echo "no scripts/screens.sh" >&2; exit 1; }

# A sandbox XDG state root so last-good lands here, not in the user's real
# ~/.local/state. The script reads XDG_STATE_HOME itself, so pointing it here
# is enough -- no path overrides needed inside the script.
STATE_DIR=$(mktemp -d)
# A stub hyprctl on PATH. Each call is bracketed by a `@@` sentinel so a call
# count is `grep -c '^@@$'`, and the raw argv is written verbatim between the
# sentinels. The batch argument from `hyprctl --batch "$batch"` contains
# newlines, so it spills across several log lines -- but a per-screen spec
# contains no newline, so `grep -F` for any one spec finds exactly the calls
# that mention it whether screens shared a batch or not. The stub always exits
# 0, matching a healthy compositor; the refuse path is asserted by the call
# simply never happening (no `@@`).
STUB_DIR=$(mktemp -d)
STUB_LOG="$STUB_DIR/hyprctl.log"
cat > "$STUB_DIR/hyprctl" <<'STUB'
#!/usr/bin/env bash
# Records each call so the test can count invocations and grep for specs.
# `hyprctl --batch "$batch"` passes all commands as ONE arg whose value spans
# newlines, so it spills across several log lines -- but `@@` brackets every
# call, so a call count is `grep -c '^@@$'` and any single spec (no newline in
# it) is found with `grep -F` regardless of how many screens shared the batch.
printf '@@\n' >> "$STUB_LOG"
printf '%s\n' "$@" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$STUB_DIR/hyprctl"

cleanup() { rm -rf "$STUB_DIR" "$STATE_DIR"; }
trap cleanup EXIT

# Run the script the way the surface will: empty environment except HOME (so
# `set -u` on the script can't read the host's vars) and the stubbed PATH with
# the stubbed hyprctl first.
# `env -i` wipes the environment, then we re-add only what the script and its
# tools need; "$@" forwards the command (bash, the script, args) INTO env so it
# actually runs instead of env just printing the environment and exiting.
# STUB_LOG is forwarded too, else the stubbed hyprctl (running under the cleared
# env) could not find the log file to append to.
stub_env() {
    env -i HOME="$STATE_DIR" XDG_STATE_HOME="$STATE_DIR" \
        STUB_LOG="$STUB_LOG" \
        PATH="$STUB_DIR:/usr/bin:/bin:/usr/local/bin" "$@"
}

run_apply() {
    printf '%s' "$1" | stub_env bash "$SCRIPT" apply
}
run_rescue() {
    stub_env bash "$SCRIPT" rescue
}

# Layouts under test. Schema (the plan's pinned contract):
# {version:1, screens:[{output, mode, position, scale, transform, mirror, enabled}]}
L1='{"version":1,"screens":[{"output":"desc:HKC OVERSEAS LIMITED S01","mode":"1920x1080@100","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true}]}'

L2='{"version":1,"screens":[{"output":"eDP-1","mode":"1920x1080@60","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true},{"output":"DP-1","mode":"1920x1080@60","position":"1920x0","scale":1,"transform":0,"mirror":"","enabled":false}]}'

L3='{"version":1,"screens":[{"output":"desc:HKC OVERSEAS LIMITED S01","mode":"1920x1080@100","position":"0x0","scale":1,"transform":0,"mirror":"eDP-1","enabled":true}]}'

L4='{"version":1,"screens":[{"output":"DP-1","mode":"1920x1080@60","position":"1920x0","scale":1,"transform":0,"mirror":"","enabled":false}]}'

L6='{"version":1,"screens":[{"output":"","mode":"1920x1080@60","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true},{"output":"eDP-1","mode":"1920x1080@60","position":"0x0","scale":1,"transform":0,"mirror":"","enabled":true}]}'

# 1. One enabled screen -> exactly one batched call carrying exactly the
#    comma spec the surface's model singleton builds: <out>,<mode>,<pos>,<scale>,transform,<n>.
: > "$STUB_LOG"
run_apply "$L1" >/dev/null 2>&1
ok "enabled screen: one batched hyprctl call for one screen" "$(grep -c '^@@$' "$STUB_LOG")" "1"
ok "enabled screen: the call is a single hyprctl --batch invocation" "$(grep -c '^--batch$' "$STUB_LOG")" "1"
ok "enabled screen: emits keyword monitor <out>,<mode>,<pos>,<scale>,transform,<n>" \
    "$(grep -F -c 'keyword monitor desc:HKC OVERSEAS LIMITED S01,1920x1080@100,0x0,1,transform,0' "$STUB_LOG")" "1"

# 2. enabled:false -> `keyword monitor <out>,disable`, and it is NOT counted as
#    an enabled screen, so the apply is allowed to proceed (one enabled sibling).
: > "$STUB_LOG"
run_apply "$L2" >/dev/null 2>&1
ok "mixed layout: still a single batched call (not one per screen)" "$(grep -c '^@@$' "$STUB_LOG")" "1"
ok "disabled screen: emits keyword monitor DP-1,disable" \
    "$(grep -F -c 'keyword monitor DP-1,disable' "$STUB_LOG")" "1"
ok "disabled screen: is not counted as enabled (the sibling was still applied)" \
    "$(grep -F -c 'keyword monitor eDP-1,1920x1080@60,0x0,1,transform,0' "$STUB_LOG")" "1"

# 3. mirror appends `,mirror,<target>` after the transform token.
: > "$STUB_LOG"
run_apply "$L3" >/dev/null 2>&1
ok "mirror: appends ,mirror,eDP-1 after transform" \
    "$(grep -F -c 'keyword monitor desc:HKC OVERSEAS LIMITED S01,1920x1080@100,0x0,1,transform,0,mirror,eDP-1' "$STUB_LOG")" "1"

# 4. Zero enabled screens -> refused, hyprctl never called, exit non-zero.
: > "$STUB_LOG"
run_apply "$L4" >/dev/null 2>&1; rc=$?
ok "zero-enabled layout: refused (exit non-zero)" "$rc" "1"
ok "zero-enabled layout: hyprctl never called" "$(grep -c '^@@$' "$STUB_LOG")" "0"

# 5. A successful apply persists last-good; rescue re-applies the same calls.
: > "$STUB_LOG"
run_apply "$L2" >/dev/null 2>&1
ok "good apply persists last-good" "$([ -f "$STATE_DIR/better/screens-last-good.json" ] && echo 1 || echo 0)" "1"
: > "$STUB_LOG"
run_rescue >/dev/null 2>&1; rc=$?
ok "rescue: exits 0 after a good apply" "$rc" "0"
ok "rescue: one batched re-apply call" "$(grep -c '^@@$' "$STUB_LOG")" "1"
ok "rescue: re-emits the enabled screen from last-good" \
    "$(grep -F -c 'keyword monitor eDP-1,1920x1080@60,0x0,1,transform,0' "$STUB_LOG")" "1"
ok "rescue: re-emits the disabled screen from last-good" \
    "$(grep -F -c 'keyword monitor DP-1,disable' "$STUB_LOG")" "1"

# 6. A screen with a missing/empty output is skipped without failing the run.
: > "$STUB_LOG"
run_apply "$L6" >/dev/null 2>&1; rc=$?
ok "empty-output screen: skipped without failing the run (exit 0)" "$rc" "0"
ok "empty-output screen: produced no spec (no leading comma)" \
    "$(grep -F -c 'keyword monitor ,1920x1080@60' "$STUB_LOG")" "0"
ok "empty-output screen: the valid sibling was still applied" \
    "$(grep -F -c 'keyword monitor eDP-1,1920x1080@60,0x0,1,transform,0' "$STUB_LOG")" "1"

# 7. No stdin -> exit non-zero, nothing applied.
: > "$STUB_LOG"
stub_env bash "$SCRIPT" apply </dev/null >/dev/null 2>&1; rc=$?
ok "apply with no stdin: exits non-zero" "$rc" "1"
ok "apply with no stdin: hyprctl never called" "$(grep -c '^@@$' "$STUB_LOG")" "0"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
