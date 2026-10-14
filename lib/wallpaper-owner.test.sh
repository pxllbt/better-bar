#!/usr/bin/env bash
# Tests for wallpaper.sh's wallpaper-ownership guard.
#
# The guard is the answer to "may this wallpaper replace the one on screen?".
# It exists because omarchy-theme-set repoints current/background at a theme
# wallpaper on every theme switch, which used to silently overwrite a wallpaper
# the user had picked. Ownership is what tells those two cases apart: a theme's
# own backgrounds are the theme's to choose, anything else was the user's pick
# and is not theirs to discard.
#
# Every case runs the real script against a fake HOME and XDG_STATE_HOME, so
# what is exercised is the shipped code path and not a reimplementation of it.

set -uo pipefail

# Defaults to this checkout's script, like the rest of the lib tests, so a bare
# `bash lib/wallpaper-owner.test.sh` works. An explicit path still wins.
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WALLSH="$ROOT/scripts/wallpaper.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

# A throwaway home with one theme installed and a user collection beside it.
setup() {
    rm -rf "$TMP/home" "$TMP/state"
    export HOME="$TMP/home"
    export XDG_STATE_HOME="$TMP/state"
    mkdir -p "$HOME/.local/state/omarchy/current/theme/backgrounds"
    mkdir -p "$HOME/.config/omarchy/backgrounds/sync"
    mkdir -p "$HOME/Downloads/Wallpaper"
    # wallpaper.sh reads and writes its state under XDG_STATE_HOME, and the
    # tests assert on that file, so the directory has to exist before any
    # script run rather than being created as a side effect of one.
    mkdir -p "$XDG_STATE_HOME"
    printf 'sync\n' > "$HOME/.local/state/omarchy/current/theme.name"

    THEME_BG="$HOME/.local/state/omarchy/current/theme/backgrounds/grid.png"
    USER_BG="$HOME/.config/omarchy/backgrounds/sync/mine.png"
    COLLECTION_BG="$HOME/Downloads/Wallpaper/picked.jpg"

    # Real images, not empty files. wallpaper.sh ends in awww img and a
    # palette derivation, and both reject a zero-byte file, so an empty
    # fixture would fail the run before it ever recorded a wallpaper --
    # which reads as "the wallpaper never changed" rather than as a decode
    # error, and quietly makes the assertions below prove nothing.
    # A fixture has to be a DECODABLE image, not merely a non-empty file. The
    # fallback that used to live here wrote an eight-byte PNG header, which is
    # not a valid PNG: vips is not installed in CI, so that is what every
    # fixture was there, and every case that drove `wallpaper.sh set` failed at
    # the awww/palette step instead. The two cases at the end then reported each
    # other's answer, which reads as a broken guard rather than a broken image.
    #
    # python3 is a given in CI (the workflow provisions it), so that is the
    # primary path; vips still wins when present; the base64 PNG below is the
    # last resort and is a real, complete, decodable image.
    for f in "$THEME_BG" "$USER_BG" "$COLLECTION_BG"; do
        if command -v vips >/dev/null 2>&1; then
            vips black "$f" 64 64 2>/dev/null && continue
        fi
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$f" <<'PYEOF' 2>/dev/null && continue
import base64, sys
# 1x1 opaque black PNG.
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"
    "/x8AAwMCAO+/6f8AAAAASUVORK5CYII=")
open(sys.argv[1], "wb").write(png)
PYEOF
        fi
        printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC' \
            | base64 -d > "$f" 2>/dev/null || : > "$f"
    done
}

owner() { bash "$WALLSH" owner "$1" 2>/dev/null | tail -1; }
may_apply() { bash "$WALLSH" should-apply "$@" >/dev/null 2>&1 && printf yes || printf no; }

# --- ownership -------------------------------------------------------------
setup
ok "owner: the theme's own backgrounds folder is the theme's" \
    "$(owner "$THEME_BG")" "theme"
ok "owner: a wallpaper dropped in the theme's user folder is the theme's" \
    "$(owner "$USER_BG")" "theme"
ok "owner: a wallpaper from the user's collection is the user's" \
    "$(owner "$COLLECTION_BG")" "user"

setup
ok "owner: a path reached through a symlink resolves to its real location" \
    "$(bash "$WALLSH" owner "$HOME/.local/state/omarchy/current/background" 2>/dev/null | tail -1)" "none"

ln -sf "$COLLECTION_BG" "$HOME/.local/state/omarchy/current/background"
ok "owner: the background symlink resolves through to the user's file" \
    "$(owner "$HOME/.local/state/omarchy/current/background")" "user"

setup
ln -sf "$THEME_BG" "$HOME/.local/state/omarchy/current/background"
ok "owner: a symlink into the theme folder resolves to the theme's" \
    "$(owner "$HOME/.local/state/omarchy/current/background")" "theme"

# --- the guard -------------------------------------------------------------
# state_on_disk <path> records a wallpaper as the one currently on screen,
# which is what the guard compares an incoming wallpaper against.
state_on_disk() { printf '%s\n' "$1" > "$XDG_STATE_HOME/better-wallpaper"; }

setup
state_on_disk "$COLLECTION_BG"
ok "guard: a theme wallpaper does not replace a wallpaper the user picked" \
    "$(may_apply "$THEME_BG")" "no"

setup
state_on_disk "$USER_BG"
ok "guard: a theme wallpaper replaces another theme wallpaper" \
    "$(may_apply "$THEME_BG")" "yes"

setup
state_on_disk "$COLLECTION_BG"
ok "guard: the user's own wallpaper always applies" \
    "$(may_apply "$COLLECTION_BG")" "yes"

setup
state_on_disk "$COLLECTION_BG"
ok "guard: a wallpaper from elsewhere in the user's files applies" \
    "$(may_apply "$HOME/Pictures/other.png")" "yes"

setup
ok "guard: a theme wallpaper applies when nothing is on record yet" \
    "$(may_apply "$THEME_BG")" "yes"

setup
state_on_disk "$COLLECTION_BG"
rm -f "$COLLECTION_BG"
ok "guard: a theme wallpaper applies once the picked file is gone" \
    "$(may_apply "$THEME_BG")" "yes"

setup
state_on_disk "$COLLECTION_BG"
ok "guard: --force applies a theme wallpaper over a picked one" \
    "$(may_apply "$THEME_BG" --force)" "yes"

setup
state_on_disk ""
ok "guard: an empty state file does not pin anything" \
    "$(may_apply "$THEME_BG")" "yes"

# --- a pick inside the theme's own folder is still the user's -------------
# sync_theme.py points the bar's picker at current/theme/backgrounds, so a
# pick lands inside the theme folder. Its path therefore looks theme-owned, and
# a path test alone would let the very next theme switch take it over -- which
# is the wallpaper disappearing again, just slower.
setup
pick_in_theme="$THEME_BG"
printf '%s\n' "$pick_in_theme" > "$XDG_STATE_HOME/better-wallpaper"
bash "$WALLSH" mark-pick "$pick_in_theme" >/dev/null 2>&1
ok "guard: a pick inside the theme's folder is protected" \
    "$(may_apply "$USER_BG")" "no"

setup
other_theme_bg="$HOME/.local/state/omarchy/current/theme/backgrounds/horizon.png"
cp "$THEME_BG" "$other_theme_bg" 2>/dev/null || vips black "$other_theme_bg" 64 64 2>/dev/null
bash "$WALLSH" mark-pick "$THEME_BG" >/dev/null 2>&1
printf '%s\n' "$THEME_BG" > "$XDG_STATE_HOME/better-wallpaper"
ok "guard: a different wallpaper in the theme's folder is still refused" \
    "$(may_apply "$other_theme_bg")" "no"

setup
bash "$WALLSH" mark-pick "$THEME_BG" >/dev/null 2>&1
printf '%s\n' "$THEME_BG" > "$XDG_STATE_HOME/better-wallpaper"
rm -f "$THEME_BG"
ok "guard: a pick that has been deleted stops protecting anything" \
    "$(may_apply "$USER_BG")" "yes"

setup
# A wallpaper the user set by path (`omarchy theme bg set`) is a deliberate
# choice even with no pick marker, so it must be protected as well. The marker
# is only needed to cover picks that land in the theme's own folder.
printf '%s\n' "$THEME_BG" > "$XDG_STATE_HOME/better-wallpaper"
ok "owner: a marked pick inside the theme folder reads as the user's" \
    "$(bash "$WALLSH" mark-pick "$THEME_BG" >/dev/null 2>&1; bash "$WALLSH" owner "$THEME_BG" | tail -1)" "user"

# --- the picked wallpaper must survive the swap ---------------------------
#
# The cases below drive `wallpaper.sh set`, which short-circuits at
# `ensure_daemon || exit 0` long before the guard or either symlink repoint
# runs. Without a compositor to paint to, a `set` here is a no-op by design, so
# asserting on its effects would be asserting that the script did something it
# deliberately did not. Skip them and say why, rather than letting them fail in
# an environment that cannot run them.
#
# A REAL awww daemon is worse than none. These cases deliberately run with a
# sandboxed HOME, so every wallpaper they paint is a path inside $TMP -- and the
# sandbox is deleted on exit. `awww` talks to the daemon over a socket that
# ignores HOME, so `set` reaches straight past the sandbox and repaints the
# user's actual desktop with a temp file. The test then deletes that file and
# exits, leaving awww displaying a path that no longer exists: a black
# wallpaper, no error anywhere, and a daemon left pointing into /tmp. So the
# daemon is stubbed and the stub records calls to disk instead of painting.
if ! command -v awww >/dev/null 2>&1; then
    printf 'SKIP the swap cases: no awww binary, so `set` cannot paint\n'
    printf '\nall green (swap cases skipped)\n'
    exit 0
fi

STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/awww" <<'STUB'
#!/usr/bin/env bash
# Records what it was asked to paint; paints nothing. `query` answers with an
# empty set so `ensure_daemon` sees a healthy daemon and the script proceeds
# through the code under test.
case "${1:-}" in
    query)
        printf '{"eDP-1":{"displaying":{"image":"/stub/painted.png"}}}'
        ;;
    *)
        printf '%s\n' "$*" >>"${AWWW_STUB_LOG:-/dev/null}"
        ;;
esac
exit 0
STUB
chmod +x "$STUBBIN/awww"
export AWWW_STUB_LOG="$TMP/awww-calls.log"
: > "$AWWW_STUB_LOG"
export PATH="$STUBBIN:$PATH"

# The refusal is only useful if the wallpaper stays painted and the wallpaper
# symlink stops advertising the theme's. Both are observable from outside.
setup
state_on_disk "$COLLECTION_BG"
ln -sf "$THEME_BG" "$HOME/.local/state/omarchy/current/background"
bash "$WALLSH" set "$THEME_BG" >/dev/null 2>&1
ok "refusal: the wallpaper on record is left alone" \
    "$(cat "$XDG_STATE_HOME/better-wallpaper")" "$COLLECTION_BG"

setup
state_on_disk "$COLLECTION_BG"
ln -sf "$THEME_BG" "$HOME/.local/state/omarchy/current/background"
bash "$WALLSH" set "$THEME_BG" >/dev/null 2>&1
ok "refusal: the background symlink points back at the user's wallpaper" \
    "$(readlink -f "$HOME/.local/state/omarchy/current/background")" "$COLLECTION_BG"

setup
state_on_disk "$COLLECTION_BG"
ln -sf "$THEME_BG" "$HOME/.local/state/omarchy/current/background"
bash "$WALLSH" set "$THEME_BG" --force >/dev/null 2>&1
ok "force: --force really does let the theme wallpaper through" \
    "$(cat "$XDG_STATE_HOME/better-wallpaper")" "$HOME/Pictures/Wallpapers/sync-grid.png"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'