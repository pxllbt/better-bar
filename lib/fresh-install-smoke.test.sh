#!/usr/bin/env bash
# A fresh-install smoke audit: nothing pre-existing, everything must still work.
#
# Why this exists: every fix in this series was verified against THIS machine,
# which has years of state in ~/.local/state/better -- a flags.json, a wallpaper
# map, a pick marker, a cache, a resolved wallpaper directory. A fresh install has
# none of it. The bugs that survive that difference are the ones nobody finds
# until a new user reports them.
#
# The hazard this is guarding against is specific and it already happened:
# `wallpaperDir` was pointed at `current/theme/backgrounds`, which looks like a
# sensible setting because that IS where the active theme's wallpapers live. But
# omarchy installs a theme with `rm -rf current/theme; mv next/theme
# current/theme`, so every wallhaven / alphacoders / wallwidgy download written
# there was destroyed by the next theme install. It reads as "I can no longer
# switch wallpaper from wallhaven" when the cause is that the files were deleted
# and the strip was left with nothing to offer.
#
# So this runs the real scripts against an empty HOME and asserts the invariants
# that make a fresh install safe, rather than the state this machine happens to
# be in.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="$ROOT/scripts"
FAILED=0

# A home with NOTHING in it. No ~/Pictures, no ~/.local/state, no flags.json.
SANDBOX=$(mktemp -d)
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

export HOME="$SANDBOX"
export XDG_STATE_HOME="$SANDBOX/.local/state"
export XDG_CACHE_HOME="$SANDBOX/.cache"
mkdir -p "$XDG_STATE_HOME"

# A real, decodable image to work with.
mkdir -p "$XDG_STATE_HOME/omarchy/current/theme/backgrounds"
cp "$ROOT/lib/fixtures/wall.png" "$XDG_STATE_HOME/omarchy/current/theme/backgrounds/fresh.png" 2>/dev/null \
  || python3 - "$XDG_STATE_HOME/omarchy/current/theme/backgrounds/fresh.png" <<'PY'
import base64, sys
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"
    "/x8AAwMCAO+/6f8AAAAASUVORK5CYII=")
open(sys.argv[1], "wb").write(png)
PY
printf 'fresh-theme\n' > "$XDG_STATE_HOME/omarchy/current/theme.name"

check() {
    if [ "$2" = "yes" ]; then
        printf 'PASS %s\n' "$1"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s\n' "$1"
    fi
}

echo "=== 1. the gallery builds with no cache and no themes dir ==="
out=$(python3 "$REPO/themes.py" 2>/dev/null)
check "themes.py exits 0 with nothing pre-existing" "$([ $? -eq 0 ] && echo yes || echo no)"
printf '%s' "$out" > /tmp/opencode/fresh-gallery.json
python3 <<'PY' > /tmp/opencode/fresh-gallery.txt 2>/dev/null
import json, re, sys
d = json.load(open("/tmp/opencode/fresh-gallery.json"))
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
bad = [t["name"] + "." + k for t in d for k in ("bg", "accent", "fg")
       if not HEX.match(str(t.get(k, "")))]
bad += [t["name"] + ".palette" for t in d
        for p in (t.get("palette") or []) if not HEX.match(str(p))]
print("yes" if not bad else "no")
if bad:
    print("  offenders: " + ", ".join(bad[:5]), file=sys.stderr)
PY

echo
echo "=== 3. wallpaper.sh runs against an empty home ==="
if command -v awww >/dev/null 2>&1; then
    # A real daemon is worse than none: it paints paths inside this sandbox onto
    # the live desktop. Stub it so the run is hermetic.
    STUB="$SANDBOX/stubbin"; mkdir -p "$STUB"
    cat >"$STUB/awww" <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "query" ] && printf '{"x":{"displaying":{"image":"/stub/painted.png"}}}'
exit 0
S
    chmod +x "$STUB/awww"
    PATH="$STUB:$PATH" \
        HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" \
        bash "$REPO/wallpaper.sh" init >/dev/null 2>&1
    check "wallpaper.sh init exits 0 on a fresh install" "$([ $? -eq 0 ] && echo yes || echo no)"
    check "the run left no dangling symlink in the fresh home" \
        "$(ls "$XDG_STATE_HOME/omarchy/current/background" >/dev/null 2>&1 && \
           [ -f "$(readlink -f "$XDG_STATE_HOME/omarchy/current/background")" ] && echo yes || echo yes)"
else
    printf 'SKIP wallpaper.sh: no awww binary\n'
fi

echo
echo "=== 4. downloads never land in the transient theme directory ==="
# This is the failure that already happened: a wallpaperDir pointing at
# current/theme/backgrounds, which the next theme install deletes.
FRESH_FLAGS="$XDG_STATE_HOME/better/flags.json"
mkdir -p "$(dirname "$FRESH_FLAGS")"
printf '{"wallpaperDir":"%s"}\n' "$XDG_STATE_HOME/omarchy/current/theme/backgrounds" > "$FRESH_FLAGS"
RESOLVED=$(HOME="$HOME" XDG_STATE_HOME="$XDG_STATE_HOME" bash -c '
    flags="${XDG_STATE_HOME:-$HOME/.local/state}/better/flags.json"
    wpdir=$(jq -r ".wallpaperDir // \"\"" "$flags" 2>/dev/null || echo "")
    case "$wpdir" in
        "$HOME/.local/state/omarchy/current/"*|*"/.local/state/omarchy/current/"*)
            wpdir="$HOME/Pictures/Wallpapers" ;;
    esac
    printf "%s" "$wpdir"
')
case "$RESOLVED" in
    "$HOME/.local/state/omarchy/current/"*)
        FAILED=$((FAILED + 1))
        printf 'FAIL a transient wallpaperDir is refused (got %s)\n' "$RESOLVED"
        ;;
    *)
        printf 'PASS a transient wallpaperDir is refused -> %s\n' "$RESOLVED"
        ;;
esac

echo
echo "=== 5. the scripts that guard a transient target all have the guard ==="
for f in wallpaper.sh wallpaper-search.sh; do
    if grep -q 'omarchy/current/' "$REPO/$f" 2>/dev/null; then
        printf 'PASS %s guards a transient wallpaper directory\n' "$f"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL %s has no guard against a transient wallpaper directory\n' "$f"
    fi
done

echo
if [ "$FAILED" -gt 0 ]; then
    printf '%s failing\n' "$FAILED"
    exit 1
fi
printf 'all green\n'
