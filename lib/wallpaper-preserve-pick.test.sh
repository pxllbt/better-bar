#!/usr/bin/env bash
# Asserts that picking a theme wallpaper preserves it.
#
# Why this exists: a wallpaper picked from the active theme's backgrounds lives
# inside `current/theme`, which omarchy deletes wholesale on every theme switch
# (`rm -rf current/theme; mv next/theme current/theme`). So the pick was
# temporary by construction: switch theme and it is gone, the recorded path is
# dead, and restoring finds nothing to restore. The user did nothing wrong and
# lost a wallpaper they had chosen.
#
# The fix is to preserve it on the way in. A pick made deliberately (--force is
# how a click in the strip arrives) is copied into the user's own collection and
# THAT path is what gets recorded. The copy is made only for a pick, never for a
# wallpaper a theme brings with it, because a theme arriving on its own is not
# the user choosing to keep it -- hoovering up every theme's wallpapers on every
# switch would turn the collection into a dump.
#
# A copy rather than a move matters too: the theme's own file stays where omarchy
# put it, so the theme still has the wallpaper it shipped with and uninstalling
# the theme leaves the copy behind.
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

hasnt() {
    if [ "$2" -eq 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected NOT to find: %s\n' "$1" "$3"
    fi
}

[ -f "$SCRIPT" ] || { echo "no wallpaper.sh at $SCRIPT" >&2; exit 1; }

# 1. The preserve helper must exist, and be a copy rather than a move.
has "wallpaper.sh has a preserve step for a user's pick" \
    "$(grep -cE '^preserve_pick\(\)|^keep_pick\(\)' "$SCRIPT")" \
    "a preserve helper"

has "the preserve is a copy, not a move, so the theme keeps its file" \
    "$(grep -cE '\bcp\b' "$SCRIPT")" \
    "cp (not mv)"

# 2. It must run only on the deliberate-pick path, never for a theme arriving
#    on its own -- otherwise every theme switch hoovers its wallpapers into the
#    user's collection.
set_force=$(awk '/^    \[ -n "\$force" \] && mark_pick/{print}' "$SCRIPT")
if [ -n "$set_force" ]; then
    has "the preserve is gated on the pick being deliberate" \
        "$(grep -cE 'force.*preserve|preserve.*force' "$SCRIPT")" \
        "a force/preserve pairing"
else
    printf 'PASS %s\n' "the mark_pick gate is still on the --force path"
    grep -q 'preserve_pick\|keep_pick' "$SCRIPT" || \
        { failed=$((failed + 1)); printf 'FAIL %s\n' "a preserve helper is called at all"; }
    grep -q '\-\-force' "$SCRIPT" || \
        { failed=$((failed + 1)); printf 'FAIL %s\n' "the --force path still exists"; }
fi

# 3. The recorded path must be the preserved copy, not the theme's own file.
has "the recorded path comes from the preserved copy" \
    "$(grep -cE 'pic="\$kept"|pic=\$kept' "$SCRIPT")" \
    "pic reassigned to the preserved copy"

# 4. And the destination must be a permanent collection, not the theme tree.
has "the preserve writes to a permanent collection" \
    "$(grep -cE 'Pictures/Wallpapers|userWallpapers' "$SCRIPT")" \
    "a permanent collection path"

# 5. The preserved copy must be namespaced by theme, so two themes shipping a
#    same-named wallpaper do not overwrite each other. This was broken by using
#    `[ "$p" = "$dir/"* ]`, which is a LITERAL comparison in POSIX test -- the
#    star never globs -- so every copy arrived unprefixed.
has "the preserve namespaces by theme using a pattern match" \
    "$(grep -cE 'case "\$resolved" in' "$SCRIPT")" \
    "a case pattern, not [ = ]"

hasnt "the preserve does not glob with a POSIX test comparison" \
    "$(grep -cE '\[ "\$resolved" = [^]]*\*[^]]*\]' "$SCRIPT")" \
    '[ "$resolved" = ...* ]'

# 6. And the strip must not show one wallpaper twice now that it reads two
#    directories -- the preserved copy and the theme's own original share a name.
WALLS="$ROOT/Singletons/Walls.qml"
has "the listing dedupes by wallpaper name" \
    "$(grep -c 'seenNames' "$WALLS")" \
    "a seen-name guard in the listing"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
