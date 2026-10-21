#!/usr/bin/env bash
# Drives EVERY surface the bar can open and asserts that none of them throws.
#
# Why this exists in the repo and not in /tmp: the first version of this script
# set only HOME. The live environment exports XDG_CONFIG_HOME, XDG_STATE_HOME,
# XDG_DATA_HOME and XDG_CACHE_HOME pointing at the real HOME, so setting HOME
# alone left every XDG location pointing at the real machine. Running it that
# way deleted the user's real ~/.local/state/better and ~/.cache/better. The
# preferences in those directories were not recoverable.
#
# The rule this encodes: a test that touches the filesystem has to redirect
# every root it might touch, not just the one it remembers.
#
# WHY A SURFACE CAN BE "GREEN" AND STILL BROKEN: the preview walks the rest
# face, so every surface behind a loader stays uncompiled until something opens
# it. A ReferenceError only fires when the interaction happens -- which is why
# this test opens every single one and then reads the shell's log for what
# QML complained about while it was open.
#
# Usage: surface-smoke.test.sh <checkout>
# Requires a running Wayland session and the omarchy-shell checkout at
# $SHELL_SRC (default /usr/share/omarchy/shell, so SHELL_SRC=/usr/share/omarchy/shell
# and OMARCHY_PATH=/usr/share/omarchy are the usual invocation on a live box).
set -uo pipefail

SRC="${1:?usage: surface-smoke.test.sh <path to a pix.bar checkout>}"
SHELL_SRC="${SHELL_SRC:-/usr/share/omarchy/shell}"
ROOT="${TEST_ROOT:-/tmp/opencode/surface-smoke}"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -d "$SHELL_SRC" ] || { echo "no omarchy-shell at $SHELL_SRC (set SHELL_SRC)" >&2; exit 1; }
[ -f "$SRC/manifest.json" ] || { echo "no manifest.json in $SRC" >&2; exit 1; }

rm -rf "$ROOT"
mkdir -p "$ROOT/.config/omarchy/plugins" "$ROOT/.local/state" "$ROOT/.local/share" "$ROOT/.cache" "$ROOT/run"
cp -r "$SRC" "$ROOT/.config/omarchy/plugins/pix.bar"
rm -rf "$ROOT/.config/omarchy/plugins/pix.bar/.git"
printf '{ "version": 1, "bar": { "id": "pix.bar" } }\n' > "$ROOT/.config/omarchy/shell.json"

# Sandbox every state root. This list is the whole point of the script.
CONN=(env -i
  PATH=/usr/bin:/bin
  HOME="$ROOT"
  XDG_CONFIG_HOME="$ROOT/.config"
  XDG_STATE_HOME="$ROOT/.local/state"
  XDG_DATA_HOME="$ROOT/.local/share"
  XDG_CACHE_HOME="$ROOT/.cache"
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
  HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-}"
  OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}")

LOG="$ROOT/shell.log"

cleanup() { [ -n "${SHELL_PID:-}" ] && kill "$SHELL_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

setsid "${CONN[@]}" quickshell -p "$SHELL_SRC" > "$LOG" 2>&1 &
sleep 12

# The IPC calls below must reach the instance this script just launched, not
# whichever one `qs` happens to pick. `qs -p <path>` selects by config path and
# resolves to the OLDEST match -- on a real desktop that is the user's own
# omarchy-shell, which has no `better` target at all, so every call came back
# "Target not found." and the test failed for a reason that had nothing to do
# with the bar. Pid selection names the process just started, whatever else is
# running, so it is exact.
SHELL_PID="$(pgrep -n -f "quickshell -p $SHELL_SRC" || true)"
if [ -z "$SHELL_PID" ]; then
    printf 'FAIL the launched shell is running\n  expected: a pid\n  got:      none\n'
    exit 1
fi
ok "the launched shell is running" "$(kill -0 "$SHELL_PID" 2>/dev/null && echo yes || echo no)" "yes"

ok "the bar's configuration loads" \
    "$(grep -c 'Configuration Loaded' "$LOG")" "1"
ok "the bar does not fall back to the stock one" \
    "$(grep -c 'failed to load' "$LOG")" "0"
ok "no type fails to resolve" \
    "$(grep -c 'is not a type' "$LOG")" "0"

# Every surface the pill can open. This list is the registry in Pill.qml --
# `readonly property var loaders`. A surface missing here is a surface the
# settings search can offer but nothing can open, and a surface that errors
# here is a button that throws when it is pressed.
SURFACES="calendar weather launcher clipboard wallpaper power media mixer link wifi bt battery sysmon screens appearance appcat display modules profile theme accent glass fontcolor fontpicker plugins update keybinds lockstyle"

ERRPAT="is not a type|ReferenceError|TypeError|Unable to assign|Cannot read property|is not defined|Binding loop detected|Cannot assign|Cannot create|Unable to create|Type '.*' cannot be"

for s in $SURFACES; do
    # The surface is opened by name, then closed again, so the next one starts
    # from a known state instead of inheriting the previous surface's teardown.
    #
    # The count is a DELTA, not a running total. A running total names every
    # later surface as the culprit once the first one has failed, which turns
    # one bug into a list of suspects and hides where it actually is.
    before=$(grep -cE "$ERRPAT" "$LOG")
    out=$(timeout 15 qs ipc --pid "$SHELL_PID" call better page "" "$s" 2>&1)
    sleep 0.6
    timeout 15 qs ipc --pid "$SHELL_PID" call better hide >/dev/null 2>&1
    sleep 0.4
    after=$(grep -cE "$ERRPAT" "$LOG")
    ok "opening the $s surface raises nothing" "$((after - before))" "0"
done

# The IPC handler itself: every function the README documents.
for fn in mixer calendar launcher power link notifications profile battery sysmon system screens screensrescue clipboard wallpaper media peek reloadTheme toggleRecast unloadAll; do
    out=$(timeout 15 qs ipc --pid "$SHELL_PID" call better "$fn" "" 2>&1)
    ok "ipc $fn answers without error" \
        "$(printf '%s' "$out" | grep -qiE 'no such|not found|unknown ipc|error' && echo errored || echo ok)" "ok"
done

# A menu route, which is the other way a surface is reached.
out=$(timeout 15 qs ipc --pid "$SHELL_PID" call better menu "" "setup" 2>&1)
ok "ipc menu answers without error" \
    "$(printf '%s' "$out" | grep -qiE 'no such|not found|unknown ipc|error' && echo errored || echo ok)" "ok"

# The whole log, once, for anything QML complained about that the per-surface
# greps would not have named.
fatal=$(grep -cE "ReferenceError|TypeError|Unable to assign|Cannot read property|Binding loop detected" "$LOG")
ok "the shell log holds no fatal QML error" "$fatal" "0"

if [ "$failed" -eq 0 ]; then
    printf '\nall green\n'
    exit 0
fi
printf '\n%s failing\n' "$failed"
exit 1
