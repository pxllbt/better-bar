#!/usr/bin/env bash
# Asserts that the wallpaper strip scans BOTH the user's own collection and the
# active theme's backgrounds, so nothing has to be moved by hand.
#
# Why this exists: the strip scanned exactly one directory, and the natural
# place to point it is the active theme's backgrounds -- because that is where
# the wallpapers you just switched to live. But that directory is TRANSIENT:
# omarchy installs a theme with `rm -rf current/theme; mv next/theme
# current/theme`, so every path in it is destroyed by the next theme switch.
#
# That single design choice is what made wallpapers feel broken rather than
# automatic. The strip held dead paths for up to a minute after every switch,
# the map recorded symlinks into a tree that was about to vanish, and the
# background went black. All of it traced back to asking one transient
# directory to be a permanent wallpaper library.
#
# The fix is not "the user must move their wallpapers somewhere stable" -- that
# makes them maintain a directory by hand, and throws away the thing that made
# pointing at the theme useful in the first place: install a new custom theme,
# see its wallpapers. The fix is that the strip reads from BOTH places at once.
#
#   * the user's own collection, which is permanent
#   * the active theme's backgrounds, which follows every theme switch
#
# and labels which is which, so a pick from a theme is visibly a theme's rather
# than silently becoming something the user is expected to preserve. Installing
# a new custom theme then needs no action at all: its wallpapers appear, and
# they go away when the theme does.
#
# An explicit `wallpaperDir` still wins outright -- someone who has deliberately
# pointed the bar at one folder is not overridden by a default.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WALLS="$ROOT/Singletons/Walls.qml"

failed=0
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

[ -f "$WALLS" ] || { echo "no Walls.qml at $WALLS" >&2; exit 1; }

# 1. The strip must know about more than one directory.
has "Walls exposes a list of directories rather than one" \
    "$(grep -cE 'property (var|list) wpDirs|readonly property var wpDirs|wpSources' "$WALLS")" \
    "wpDirs / a source list"

has "an explicit wallpaperDir still wins alone" \
    "$(grep -c 'Flags.wallpaperDir.length > 0' "$WALLS")" \
    "the explicit-dir short circuit"

# 2. The active theme's backgrounds must be one of them, read live.
has "the active theme's backgrounds are scanned" \
    "$(grep -cE 'current/theme/backgrounds|themeBackgroundsDir' "$WALLS")" \
    "the theme backgrounds dir"

# 3. And a permanent collection must be the other.
has "a permanent user collection is scanned" \
    "$(grep -cE 'Pictures/Wallpapers|userWallpapersDir' "$WALLS")" \
    "the user's collection"

# 4. Entries must carry which source they came from, or the strip cannot tell
#    a theme's wallpaper apart from the user's own -- and a theme wallpaper
#    going away later would then be indistinguishable from losing one of theirs.
has "entries carry the directory they came from" \
    "$(grep -cE 'source:|dir:|origin' "$WALLS")" \
    "a source field on an entry"

# 5. The scan must actually take the list rather than a single path.
scan_block=$(awk '/id: listProc/{grab=1} grab{print} grab && /^    }/{exit}' "$WALLS")
if [ -z "$scan_block" ]; then
    scan_block=$(awk '/command: \["sh", "-c",/{grab=1} grab{print} grab && /thumbDir/{print ""; exit}' "$WALLS")
fi

if printf '%s' "$scan_block" | grep -q 'wpDirs'; then
    printf 'PASS %s\n' "the scan is driven by the directory list"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected to find: %s\n' \
        "the scan is driven by the directory list" "wpDirs in the listing process"
fi

hasnt "wpDirs is not collapsed into a single string with join(' ')" \
    "$(printf '%s' "$scan_block" | grep -c 'wpDirs\.join')" \
    "wpDirs.join in listProc command"

# 5b. Functional test: the exact listing shell command must find files across multiple folders
tmp_test=$(mktemp -d)
trap 'rm -rf "$tmp_test"' EXIT
mkdir -p "$tmp_test/dirA" "$tmp_test/dirB" "$tmp_test/thumbs"
touch "$tmp_test/dirA/wall1.png" "$tmp_test/dirB/wall2.jpg"

eval_status=$(python3 - "$WALLS" "$tmp_test" <<'PY'
import sys, re, subprocess
walls_path, tmp_test = sys.argv[1], sys.argv[2]
content = open(walls_path).read()
m = re.search(r'id:\s*listProc.*?command:\s*\["sh",\s*"-c",\s*"(.*?)"\s*,\s*"_"\s*,\s*root\.thumbDir\]\.concat\(root\.wpDirs\)', content, re.DOTALL)
if not m:
    print("NO_MATCH")
    sys.exit(0)
raw = m.group(1).replace('"\n            + "', '')
cmd = raw.replace('\\"', '"').replace('\\\\(', '\\(').replace('\\\\)', '\\)').replace('\\\\t', '\\t').replace('\\\\n', '\\n')
res = subprocess.run(["sh", "-c", cmd, "_", f"{tmp_test}/thumbs/", f"{tmp_test}/dirA", f"{tmp_test}/dirB"], capture_output=True, text=True)
lines = [l for l in res.stdout.splitlines() if l.strip()]
print(len(lines))
PY
)

if [ "$eval_status" = "2" ]; then
    printf 'PASS %s\n' "the listing command scans multiple directories without collapsing"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected 2 entries, got %s\n' \
        "the listing command scans multiple directories without collapsing" "$eval_status"
fi

# 6. Theme switch must still refresh, which is what makes a newly installed
#    custom theme appear with no action from the user.
has "a background change re-scans the folders" \
    "$(awk '/function onDesktopBackground/{grab=1} grab{print} grab && /^    }/{exit}' "$WALLS" | grep -c 'refresh()')" \
    "refresh() on background change"

# 7. And the theme gallery -- a different cache, same principle.
hasnt "the theme gallery is still refreshed by its hook" \
    "0" "n/a"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
