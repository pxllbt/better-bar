#!/usr/bin/env bash
# Asserts that a wallpaper recorded in the per-output map is a real file, not a
# symlink, and that a dangling map entry is repaired rather than painted.
#
# Why this exists: omarchy's theme-set hook hands wallpaper.sh the path
# `current/background`, which IS a symlink. `set` resolved that path only to
# repoint the link, and never assigned the resolved value back, so the path
# went into the per-output map unresolved.
#
# A symlink is the worst thing to store there. `-f` follows symlinks, so every
# liveness check in the script passes while the link is dangling: the target
# lives inside `current/theme/backgrounds`, and a theme switch `rm -rf`s that
# tree and `mv`s a new one in. So the map kept naming a path that resolved to
# nothing, restore_all found it "existing", repainted it, and the desktop went
# black -- with every check along the way reporting success.
#
# The same is true of the bare `current/background` link even when it resolves:
# storing a link means the recorded wallpaper silently changes meaning the next
# time omarchy repoints that link, which is every theme switch.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT/scripts/wallpaper.sh"

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

[ -f "$SCRIPT" ] || { echo "no wallpaper.sh at $SCRIPT" >&2; exit 1; }

# 1. A resolve helper exists and rejects what does not resolve.
has "wallpaper.sh defines a resolve helper" \
    "$(grep -c 'resolve_pic()' "$SCRIPT")" "resolve_pic()"

has "the resolve helper rejects a path that resolves to nothing" \
    "$(grep -cE '\[ -f "\$resolved" \] \|\| return 1' "$SCRIPT")" \
    '[ -f "$resolved" ] || return 1'

# 2. Neither writer may store a link.
has "map_put stores the resolved file" \
    "$(grep -cE 'resolved=\$\(resolve_pic "\$2"\)' "$SCRIPT")" \
    'resolve_pic "$2" in map_put'

has "map_put_all stores the resolved file" \
    "$(grep -cE 'resolved=\$\(resolve_pic "\$1"\)' "$SCRIPT")" \
    'resolve_pic "$1" in map_put_all'

# 3. set reassigns pic to a real file, so the value reaching the map is a file.
# Normally that is the preserved copy -- see wallpaper-preserve-pick -- which
# `preserved_path` resolves internally with readlink -f and an existence test,
# so it cannot hand back a link. The plain resolve is the fallback when there is
# nothing to preserve.
has "set reassigns pic to the preserved file" \
    "$(grep -cE 'if kept=\$\(preserved_path "\$pic"\); then' "$SCRIPT")" \
    'if kept=$(preserved_path "$pic"); then'

has "the reassignment is guarded, so a failed preserve keeps the original" \
    "$(grep -cE 'pic="\$kept"' "$SCRIPT")" \
    'pic="$kept"'

# 4. A recorded entry that no longer resolves must not be painted.
restore_block=$(awk '
    /^restore_all\(\)/ { grab = 1 }
    grab { print }
    grab && /^}/ { exit }
' "$SCRIPT")

if [ -z "$restore_block" ]; then
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' "restore_all exists" "restore_all()"
elif printf '%s' "$restore_block" | grep -q 'resolve_pic'; then
    printf 'PASS %s\n' "restore_all resolves every candidate before painting"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "restore_all resolves every candidate before painting" \
        "resolve_pic in restore_all"
fi

# 5. Every reader that paints from the map must resolve too. silent_reapply was
# the one missed on the first pass -- it repaints with no transition, so it is
# the one a user is most likely to be staring at when it hands awww a dangling
# path. Enumerated rather than assumed, so a new reader cannot skip this.
painters="restore_all silent_reapply"
for fn in $painters; do
    block=$(awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\)" { grab = 1 }
        grab { print }
        grab && /^}/ { exit }
    ' "$SCRIPT")
    if [ -z "$block" ]; then
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$fn exists" "$fn()"
    elif printf '%s' "$block" | grep -q 'resolve_pic'; then
        printf 'PASS %s\n' "$fn resolves before painting"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$fn resolves before painting" "resolve_pic in $fn"
    fi
done

# No painter may reach awww with a bare `-f` test as its only existence gate:
# that is the exact check that passes on a dangling symlink.
for fn in $painters; do
    block=$(awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\)" { grab = 1 }
        grab { print }
        grab && /^}/ { exit }
    ' "$SCRIPT")
    if printf '%s' "$block" | grep -qE '\[ -f "\$pic" \]'; then
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' \
            "$fn has no symlink-following existence gate" '[ -f "$pic" ]'
    else
        printf 'PASS %s\n' "$fn has no symlink-following existence gate"
    fi
done

# 6. The health check must distinguish "a path is set" from "an image is on
# screen". This is the half that actually reports the black desktop: awww keeps
# naming the last image it was asked for long after that file is deleted, so a
# check that only looks for a non-empty path reports a healthy desktop over a
# blank one, and init then skips the restore that would have repaired it.
painted=$(awk '/^daemon_painted\(\)/{grab=1} grab{print} grab && /^}/{exit}' "$SCRIPT")

if printf '%s' "$painted" | grep -qE '\[ -f "\$shown" \]|\[ ! -f "\$shown" \]'; then
    printf 'PASS %s\n' "the painted-wallpaper check requires the file to still exist"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the painted-wallpaper check requires the file to still exist" \
        'an existence test on the reported path'
fi

# And it must extract that path at all, rather than only counting entries.
if printf '%s' "$painted" | grep -qE '\.\[0\] // empty|sed -n .*image'; then
    printf 'PASS %s\n' "the painted-wallpaper check reads back the reported path"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the painted-wallpaper check reads back the reported path" \
        'extract the path awww reports'
fi

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
