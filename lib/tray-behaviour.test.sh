#!/usr/bin/env bash
# Asserts the tray can open apps and hide the ones it cannot.
#
# The bug this exists for: a tray item whose app has gone away, or which exposes
# only a menu, could not be dismissed from the tray at all. Omarchy's own tray
# carries a manage list with pin and hide, persisted per widget; Better Bar had
# neither, so a dead icon (a Steam tray item that survives its client, an app
# that registered and never unregisters) sat there permanently and clicking it
# did nothing -- the icon looked live, so it read as "opening apps from the tray
# is broken" rather than "this one icon is a ghost".
#
# Each check names the break it catches. These read the source rather than
# driving a real StatusNotifier item, because the ghost case cannot be produced
# on demand: it needs an app that misbehaves on the bus.
set -uo pipefail

ROOT="${1:-$HOME/.local/share/quickshell/better}"
TRAY="$ROOT/components/Tray.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$TRAY" ] || { echo "no Tray.qml at $TRAY" >&2; exit 1; }

# --- hidden ids are honoured -------------------------------------------------
ok "hidden item ids are kept" \
    "$(grep -cE 'property var hiddenIds' "$TRAY")" "1"
ok "a hidden item is filtered out of the tray" \
    "$(grep -cE 'hiddenIds\.indexOf' "$TRAY")" "1"
ok "hiding is persisted, not session-only" \
    "$(grep -cE 'function persistHidden' "$TRAY")" "1"

# --- the manage list ---------------------------------------------------------
ok "the tray has a manage entry point" \
    "$(grep -cE 'function showManage' "$TRAY")" "1"
ok "manage lists every item, including hidden ones" \
    "$(grep -cE 'function manageRows' "$TRAY")" "1"
ok "a hidden item can be restored from manage" \
    "$(grep -cE 'function toggleHide' "$TRAY")" "1"

# --- the actual opens --------------------------------------------------------
# Left-click must reach activate(), and an item that only has a menu must get
# that menu instead of a dead click.
ok "left-click activates the item" \
    "$(grep -cE 'modelData\.activate\(\)' "$TRAY")" "1"
ok "a menu-only item opens its menu on click" \
    "$(grep -cE 'onlyMenu' "$TRAY")" "1"

# --- dead items --------------------------------------------------------------
# A ghost icon must not be drawn at all: no icon and no title means there is
# nothing to click.
ok "an item with no identity is dropped" \
    "$(grep -cE 'function isDead' "$TRAY")" "1"


# --- a torn-down entry must not throw ---------------------------------------
# `entryData: entry.modelData` explicitly assigns null when a tray app drops an
# entry between the snapshot and the delegate being built. An explicit null
# OVERWRITES a `property var entryData: ({})` default, so every unconditional
# read below threw "Cannot read property of null" (observed at Tray.qml lines
# 355/356/358/399/400) and still drew a blank row. The null has to be coerced
# away in one place rather than guarded at a dozen read sites.
ok "the raw slot may be null" \
    "$(grep -cE 'property var slotData: modelData' "$TRAY")" "1"
ok "entryData coerces a torn-down entry to an empty object" \
    "$(grep -cE 'readonly property var entryData: \(slotData === null \|\| slotData === undefined\)' "$TRAY")" "1"
ok "gone is derived from the raw slot" \
    "$(grep -cE 'readonly property bool gone: slotData === null \|\| slotData === undefined' "$TRAY")" "1"
ok "every delegate binds the raw slot, not the coerced object" \
    "$(grep -vE '^\s*(\*|//)' "$TRAY" | grep -cE '^\s+slotData: (entry\.)?modelData$')" "2"
if grep -vE '^\s*(\*|//)' "$TRAY" | grep -qE 'entryData: entry\.modelData'; then
    failed=$((failed + 1))
    printf '\033[31m  FAIL: the delegate must not assign the raw slot to entryData\033[0m\n'
else
    printf '\033[32m  ok: nothing assigns raw modelData straight into entryData\033[0m\n'
fi

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'