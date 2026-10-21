#!/usr/bin/env bash
# Guards the REMOVAL of the Plymouth unlock customisation.
#
# This file exists because CI has a step that runs it, and because the removal
# is exactly the kind of thing that comes back half-wired. The Plymouth
# surface was pruned; what was left behind was a settings-search entry that
# offered "Plymouth Unlock" and did nothing when it was clicked, and three
# flags in the settings file that no property read. A dead navigation target
# is invisible in a preview and in a screenshot -- it only shows up when
# somebody searches for it and presses the result.
#
# So this asserts the pruning is COMPLETE, rather than asserting the surface
# works. Nothing here is about Plymouth being present; it is about Plymouth
# being GONE, in every place that could still point at it.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$ROOT/manifest.json" ] || { echo "no manifest.json in $ROOT" >&2; exit 1; }

# 1. The surface and the singleton are gone.
ok "the Plymouth surface file is gone" \
    "$([ -f "$ROOT/surfaces/PlymouthSurface.qml" ] && echo present || echo absent)" "absent"
ok "the Plymouth singleton is gone" \
    "$([ -f "$ROOT/Singletons/Plymouth.qml" ] && echo present || echo absent)" "absent"

# 2. No module still declares them.
ok "no qmldir still declares a Plymouth type" \
    "$(grep -c -i plymouth "$ROOT/surfaces/qmldir" "$ROOT/Singletons/qmldir" 2>/dev/null | grep -v ':0$' | wc -l)" "0"

# 3. No flag survives it. The three that outlived the surface were read by
#    nothing, and a persisted key with no property behind it is a setting the
#    user can see in their own settings file and cannot change from the bar.
ok "no Plymouth flag survives" \
    "$(grep -c -i 'plymouth' "$ROOT/Singletons/Flags.qml" 2>/dev/null)" "0"

# 4. The settings search does not offer it. This is the one that bites: a
#    search result that opens nothing is a button that lies.
ok "the settings search does not route to a Plymouth surface" \
    "$(grep -c 'to: *"plymouth"' "$ROOT/lib/settings-search.js" 2>/dev/null)" "0"

# 5. Nothing in the tree still points at one.
ok "no QML file references a Plymouth surface" \
    "$(grep -rl -i 'plymouth' --include='*.qml' "$ROOT" 2>/dev/null | wc -l)" "0"

if [ "$failed" -eq 0 ]; then
    printf '\nall green\n'
    exit 0
fi
printf '\n%s failing\n' "$failed"
exit 1
