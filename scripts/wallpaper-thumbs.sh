#!/bin/sh
# Wallpaper thumbnail pipeline. Mirrors Walls.qml's `wpDirs`: it generates
# previews for the user's collection AND the active theme's backgrounds, because
# the strip lists both and a wallpaper with no cached preview renders as an
# empty tile -- which reads as "there is no wallpaper" when there are dozens.
#
# The theme folder is what makes this zero-maintenance. Install a new custom
# theme and its wallpapers appear thumbnailed in the picker with nothing to
# configure; switch away from it and its cache subdir is dropped here so stale
# thumbs never linger.
#
# Each source dir gets its own cache subdir keyed by md5(path), matching the
# listing's hash exactly so thumb paths line up with entries. Files sharing a
# basename across folders therefore never clobber each other.
MAGICK_CONFIGURE_PATH="$(dirname "$0")/magick-policy"
export MAGICK_CONFIGURE_PATH

STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
flags="$STATE/better/flags.json"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/better/wp-thumbs"
mkdir -p "$cache"

# --- Build the active directory set (same chain Walls.qml uses) -------------
raw=$(jq -r '.wallpaperDir // ""' "$flags" 2>/dev/null || echo "")
[ -n "$raw" ] || raw=$(cat "$STATE/better-wallpaper-dir" 2>/dev/null || true)
[ -n "$raw" ] || raw="$HOME/Pictures/Wallpapers"
# Drop any trailing slash so flags/state drift does not spawn a second subdir
# (the listing hashes the same normalized path the generator does).
own=$(printf '%s' "$raw" | sed 's#/*$##')

# Active theme backgrounds, included only when a theme is installed AND its
# backgrounds folder actually exists. Reading theme.name here -- not hardcoding
# the path -- keeps the set correct across a swap: omarchy replaces
# current/theme wholesale, so a cached path would name a tree that no longer
# exists after the next theme install.
theme_dir=""
theme_name=$(cat "$STATE/omarchy/current/theme.name" 2>/dev/null | tr -d '\n')
if [ -n "$theme_name" ]; then
    td="$STATE/omarchy/current/theme/backgrounds"
    [ -d "$td" ] && theme_dir=$(printf '%s' "$td" | sed 's#/*$##')
fi

# own first, theme second -- same order the strip lists in, so cache and
# listing stay in lockstep. Dedupe so a pointed-to theme folder is not thrice
# scanned (the listing dedupes on name; the generator avoids duplicate work).
dirs=$(printf '%s\n%s\n' "$own" "$theme_dir" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++')

# --- Helpers -----------------------------------------------------------------
sources() {  # $1 = source folder; basenames of its wallpapers, sorted, unique
    find "$1" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.gif' \
        -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' \
        -o -iname '*.mkv' -o -iname '*.mov' \) -printf '%f\n' | sort -u
}

thumbs() {  # $1 = cache subdir; thumb basenames sans .png, sorted, unique
    find "$1" -maxdepth 1 -type f -name '*.png' -printf '%f\n' \
        | sed 's/\.png$//' | sort -u
}

prune_dir() {  # $1 = thumb dir, $2 = source folder
    s=$(mktemp); h=$(mktemp)
    sources "$2" > "$s"
    thumbs "$1" > "$h"
    # thumbs with no corresponding source -- gone/rename -- are removed.
    comm -23 "$h" "$s" | while IFS= read -r base; do
        rm -f "$1/$base.png"
    done
    rm -f "$s" "$h"
}

is_active() {  # $1 = a normalized source path; exit 0 when in the active set
    [ "$1" = "$own" ] && return 0
    [ -n "$theme_dir" ] && [ "$1" = "$theme_dir" ]
}

gen_dir() {  # $1 = wpdir
    wpdir="$1"
    [ -d "$wpdir" ] || return 0
    key=$(printf '%s' "$wpdir" | md5sum | cut -d' ' -f1)
    dir="$cache/$key"
    mkdir -p "$dir"
    printf '%s' "$wpdir" > "$dir/.srcdir"
    prune_dir "$dir" "$wpdir"
    find "$wpdir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.gif' \
        -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' \
        -o -iname '*.mkv' -o -iname '*.mov' \) | while IFS= read -r src; do
        thumb="$dir/$(basename "$src").png"
        if [ ! -s "$thumb" ] || [ "$src" -nt "$thumb" ]; then
            case "$src" in
                *.[Mm][Pp]4|*.[Ww][Ee][Bb][Mm]|*.[Mm][Kk][Vv]|*.[Mm][Oo][Vv])
                    ffmpeg -y -loglevel quiet -i "$src" -frames:v 1 -vf 'scale=512:-2' -f image2 -c:v png "$thumb.tmp" 2>/dev/null
                    ;;
                *)
                    magick "${src}[0]" -strip -resize 512x "png:$thumb.tmp" 2>/dev/null
                    ;;
            esac
            if [ -s "$thumb.tmp" ]; then
                mv "$thumb.tmp" "$thumb"
            else
                rm -f "$thumb.tmp"
            fi
        fi
    done
}

# --- Active directories: prune + regenerate ----------------------------------
printf '%s\n' "$dirs" | while IFS= read -r wpdir; do
    gen_dir "$wpdir"
done

# --- Sweep: drop cache subdirs whose source is no longer active --------------
# Survivors: a subdir whose .srcdir is in the active set and still exists; it
# is pruned (no regeneration) and kept if it still holds thumbs. Everything
# else -- a switched-away theme, a dir that moved, or a marker-less stray -- is
# removed whole, so the cache never holds thumbs the strip cannot offer.
for d in "$cache"/*/; do
    [ -d "$d" ] || continue
    if [ -f "$d/.srcdir" ]; then
        src=$(cat "$d/.srcdir" 2>/dev/null | sed 's#/*$##')
    else
        # Legacy subdir (pre-marker): attribute by hashing the raw path values
        # we know, any of which may have carried a trailing slash.
        src=""
        for r in "$raw" "$(cat "$STATE/better-wallpaper-dir" 2>/dev/null || true)"; do
            [ -z "$r" ] && continue
            r=$(printf '%s' "$r" | sed 's#/*$##')
            [ "$(printf '%s' "$r" | md5sum | cut -d' ' -f1)" = "$(basename "$d")" ] && { src="$r"; break; }
        done
    fi
    if [ -n "$src" ] && [ -d "$src" ]; then
        # normalize for the membership test
        srcn=$(printf '%s' "$src" | sed 's#/*$##')
        if is_active "$srcn"; then
            prune_dir "$d" "$src"
            if [ -z "$(find "$d" -maxdepth 1 -type f -name '*.png' -print -quit)" ]; then
                rm -rf "$d"
            fi
        else
            rm -rf "$d"
        fi
    else
        rm -rf "$d"
    fi
done 2>/dev/null || true
