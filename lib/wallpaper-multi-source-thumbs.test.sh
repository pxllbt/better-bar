#!/usr/bin/env bash
# Regression: wallpaper-thumbs.sh must thumbnail ALL the directories the strip
# scans, not only wallpaperDir -- in particular the active theme's backgrounds.
#
# That second directory is the whole reason the picker shows the theme's
# wallpapers at all. Before it was added to the generator, the strip listed the
# theme's wallpapers (its listing already scans both folders) but had no cached
# preview for any of them, so they drew as empty tiles. To the user that read
# as "there is no wallpaper" whenever a theme shipped wallpapers -- which is
# every default install and every newly installed custom theme.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
THUMBS="$ROOT/scripts/wallpaper-thumbs.sh"
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

STUBBIN="$TMP/stubbin"
write_stubs() {
    mkdir -p "$STUBBIN"
    cat >"$STUBBIN/magick" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        png:*) printf 'x' > "${a#png:}" ;;
    esac
done
exit 0
STUB
    chmod +x "$STUBBIN/magick"
    cat >"$STUBBIN/ffmpeg" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUBBIN/ffmpeg"
}

mkpng() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$1" <<'PYEOF' 2>/dev/null && return 0
import base64, sys
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"
    "/x8AAwMCAO+/6f8AAAAASUVORK5CYII=")
open(sys.argv[1], "wb").write(png)
PYEOF
    fi
    printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC' \
        | base64 -d > "$1" 2>/dev/null || : > "$1"
}

setup_theme() {
    rm -rf "$TMP/home" "$TMP/state" "$TMP/cache"
    mkdir -p "$TMP/home/Pictures/Wallpapers" "$TMP/state/omarchy/current/theme/backgrounds" "$TMP/cache/better/wp-thumbs" "$STUBBIN"
    write_stubs
    export HOME="$TMP/home"
    export XDG_STATE_HOME="$TMP/state"
    export XDG_CACHE_HOME="$TMP/cache"
    export PATH="$STUBBIN:$PATH"
}

setup_theme
printf 'my-custom-theme\n' > "$XDG_STATE_HOME/omarchy/current/theme.name"
theme_bg="$XDG_STATE_HOME/omarchy/current/theme/backgrounds"
own_bg="$HOME/Pictures/Wallpapers"
mkdir -p "$XDG_STATE_HOME/better"
printf '{"wallpaperDir":"%s"}\n' "$own_bg" > "$XDG_STATE_HOME/better/flags.json"

mkpng "$theme_bg/theme-a.png"
mkpng "$theme_bg/theme-b.png"
mkpng "$own_bg/own-a.png"

bash "$THUMBS"

key_t=$(printf '%s' "$theme_bg" | md5sum | cut -d' ' -f1)
key_o=$(printf '%s' "$own_bg" | md5sum | cut -d' ' -f1)

ok "theme cache subdir is created" \
    "$([ -d "$XDG_CACHE_HOME/better/wp-thumbs/$key_t" ] && echo yes || echo no)" yes
ok "own cache subdir is created" \
    "$([ -d "$XDG_CACHE_HOME/better/wp-thumbs/$key_o" ] && echo yes || echo no)" yes
ok "theme wallpaper gets a thumb" \
    "$([ -s "$XDG_CACHE_HOME/better/wp-thumbs/$key_t/theme-a.png.png" ] && echo yes || echo no)" yes
ok "own wallpaper gets a thumb" \
    "$([ -s "$XDG_CACHE_HOME/better/wp-thumbs/$key_o/own-a.png.png" ] && echo yes || echo no)" yes
ok ".srcdir records the theme folder" \
    "$(cat "$XDG_CACHE_HOME/better/wp-thumbs/$key_t/.srcdir")" "$theme_bg"

setup_theme
printf 'other-theme\n' > "$XDG_STATE_HOME/omarchy/current/theme.name"
mkpng "$theme_bg/theme-x.png"
mkdir -p "$XDG_STATE_HOME/better"
printf '{"wallpaperDir":"%s"}\n' "$own_bg" > "$XDG_STATE_HOME/better/flags.json"
dead="$TMP/dead-folder"; mkdir -p "$dead"; mkpng "$dead/ghost.png"
dk=$(printf '%s' "$dead" | md5sum | cut -d' ' -f1)
mkdir -p "$XDG_CACHE_HOME/better/wp-thumbs/$dk"
printf '%s' "$dead" > "$XDG_CACHE_HOME/better/wp-thumbs/$dk/.srcdir"
printf 'x' > "$XDG_CACHE_HOME/better/wp-thumbs/$dk/ghost.png"
bash "$THUMBS"
ok "orphan cache dir from a vanished folder is pruned" \
    "$([ -d "$XDG_CACHE_HOME/better/wp-thumbs/$dk" ] && echo yes || echo no)" no
ok "new theme wallpaper gets a thumb" \
    "$([ -s "$XDG_CACHE_HOME/better/wp-thumbs/$key_t/theme-x.png.png" ] && echo yes || echo no)" yes

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'