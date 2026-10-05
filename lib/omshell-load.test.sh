#!/usr/bin/env bash
# Loads a checkout's bar inside an isolated omarchy-shell and asserts it comes
# up, then answers all four documented IPC surfaces.
#
# Why this exists in the repo and not in /tmp: the first version of this script
# set only HOME. The live environment exports XDG_CONFIG_HOME, XDG_STATE_HOME,
# XDG_DATA_HOME and XDG_CACHE_HOME pointing at the real HOME, so setting HOME
# alone left every XDG location pointing at the real machine. Running it that
# way deleted the user's real ~/.local/state/better and ~/.cache/better. The
# preferences in those directories were not recoverable.
#
# The rule this encodes: a test that touches the filesystem has to redirect
# every root it might touch, not just the one it remembers. The same mistake is
# recorded in lib/alphacoders.test.sh, which needed both XDG roots redirected
# before its cache assertions told the truth.
#
# WAYLAND_DISPLAY and XDG_RUNTIME_DIR are passed through deliberately. They are
# the two variables that must reach the live session: without them quickshell
# cannot reach the compositor and "loaded: 0" means nothing was tested.
#
# Usage: omshell-load.test.sh <checkout>
# Requires a running Wayland session and the omarchy-shell checkout at
# $SHELL_SRC (default /tmp/opencode/fo2/shell).
set -uo pipefail

SRC="${1:?usage: omshell-load.test.sh <path to a pix.bar checkout>}"
SHELL_SRC="${SHELL_SRC:-/tmp/opencode/fo2/shell}"
ROOT="${TEST_ROOT:-/tmp/opencode/omshell-load}"

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
  OMARCHY_PATH="${OMARCHY_PATH:-/tmp/opencode/fo2}")

LOG="$ROOT/shell.log"

cleanup() { pkill -f "quickshell -p $SHELL_SRC" 2>/dev/null; }
trap cleanup EXIT

setsid "${CONN[@]}" quickshell -p "$SHELL_SRC" > "$LOG" 2>&1 &
sleep 12

ok "the bar's configuration loads" \
    "$(grep -c 'Configuration Loaded' "$LOG")" "1"
ok "the bar does not fall back to the stock one" \
    "$(grep -c 'failed to load' "$LOG")" "0"
# An unregistered or mis-spelled type is QML's version of a silent failure: the
# surface it belongs to just never appears.
ok "no type fails to resolve" \
    "$(grep -c 'is not a type' "$LOG")" "0"

# A successful `ipc call` prints nothing. Empty stdout is the success shape,
# so what has to be checked is the absence of an error string, not the presence
# of output. The old harness printed ${out:-ok}, which turned empty into "ok" by
# accident and would equally have passed a call that failed silently.
for fn in launcher wallpaper clipboard mixer; do
    out=$("${CONN[@]}" qs -p "$SHELL_SRC" ipc call better "$fn" "" 2>&1)
    ok "ipc $fn answers without error" \
        "$(printf '%s' "$out" | grep -qiE 'no such|not found|unknown ipc|error' && echo errored || echo ok)" "ok"
done

[ "$failed" -eq 0 ] && printf '\nall green\n' || printf '\n%s failing\n' "$failed"
exit $((failed > 0))