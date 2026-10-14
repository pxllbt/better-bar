#!/usr/bin/env bash
set -euo pipefail

flags_file="${XDG_STATE_HOME:-$HOME/.local/state}/better/flags.json"
WPDIR=$(jq -r '.wallpaperDir // ""' "$flags_file" 2>/dev/null || echo "")
FIT=$(jq -r '.wallpaperFit // "crop"' "$flags_file" 2>/dev/null || echo crop)
case "$FIT" in no|crop|fit|stretch) ;; *) FIT=crop ;; esac
# How long a wallpaper change takes to land, in seconds. awww's own default is
# 3, and leaving it unset is what made every pick feel like the desktop hung --
# see apply_visual. Overridable from the same flags file so a user who wants a
# slow, obvious sweep can ask for one.
TRANSITION_SECONDS=$(jq -r '.wallpaperTransitionSeconds // 0.5' "$flags_file" 2>/dev/null || echo 0.5)
case "$TRANSITION_SECONDS" in
    ''|*[!0-9.]*) TRANSITION_SECONDS=0.5 ;;
esac
if [ -z "$WPDIR" ]; then
    # No explicit folder set: adopt an existing collection in the usual spots.
    # Two or more images counts as a collection, a single stray file does not,
    # so an incidental picture never hijacks the default.
    for cand in "$HOME/Pictures/Wallpapers" "$HOME/Pictures/wallpapers" "$HOME/Wallpapers" "$HOME/wallpapers"; do
        [ -d "$cand" ] || continue
        n=$(find "$cand" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' \) | awk 'NR<=2' | wc -l)
        if [ "$n" -ge 2 ]; then WPDIR="$cand"; break; fi
    done
    [ -n "$WPDIR" ] || WPDIR="$HOME/Pictures/Wallpapers"
fi
RESOLVED="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-dir"
printf '%s\n' "$WPDIR" > "$RESOLVED"
# No-op mode for the QML side: re-resolve the folder and exit before touching any daemon state.
[ "${1:-}" = "resolve" ] && exit 0
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper"
# Wallpapers the user has picked, one per line. Read by wallpaper_owner so a
# pick that landed inside a theme's own backgrounds folder still counts as the
# user's -- see the note there.
PICK_MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-picks"
MAP="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-map"
BAG="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-bag"
STILL="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-still.png"
FIT_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-fit"
WLOG="${XDG_STATE_HOME:-$HOME/.local/state}/better/wallcolors.log"

is_video() {
    case "${1##*.}" in
        [Mm][Pp]4|[Ww][Ee][Bb][Mm]|[Mm][Kk][Vv]|[Mm][Oo][Vv]) return 0 ;;
        *) return 1 ;;
    esac
}

# mpvpaper keeps its real process name only when it runs as a bare ELF; distro
# wrappers (NixOS private env, FHS shims...) run it under a different comm, so
# exact-name matches silently miss it and a video lingers on after switching
# back to a still. Match the command line instead, with the [m] bracket so the
# pattern never matches the pgrep/pkill call itself.
MPV_PAT='[m]pvpaper'
mpv_running() { pgrep -f "$MPV_PAT" >/dev/null 2>&1; }
mpv_list() { pgrep -af "$MPV_PAT" || true; }
mpv_kill() { pkill -f "$MPV_PAT" 2>/dev/null || true; }

# Soft-kill first so mpv can flush its quit bookkeeping, then escalate to
# SIGKILL. A decoder wedged on the frame queue otherwise lingers with its full
# buffer pool while the next video spawns on top, so a rapid video-to-video
# switch ratchets the footprint up instead of swapping one player for another.
stop_mpv() {
    mpv_running || return 0
    mpv_kill
    for _ in $(seq 1 10); do
        mpv_running || return 0
        sleep 0.1
    done
    pkill -9 -f "$MPV_PAT" 2>/dev/null || true
    for _ in $(seq 1 10); do
        mpv_running || return 0
        sleep 0.1
    done
}

# Fit intent mapped to mpv flags (videos have no awww --resize): cover zooms
# with panscan, contain letterboxes, stretch distorts, center stays native, all
# mirroring what aww's --resize does for stills.
opts_for_fit() {
    case "$FIT" in
        no)      printf '%s' "no-audio loop-file=inf hwdec=auto video-unscaled=yes panscan=0" ;;
        fit)     printf '%s' "no-audio loop-file=inf hwdec=auto panscan=0" ;;
        stretch) printf '%s' "no-audio loop-file=inf hwdec=auto keepaspect=no panscan=0" ;;
        *)       printf '%s' "no-audio loop-file=inf hwdec=auto panscan=1.0" ;;
    esac
}

ensure_daemon() {
    awww query >/dev/null 2>&1 && return 0
    # Give a daemon the session started itself a moment to answer before
    # concluding there is none. The install docs put `exec-once = awww-daemon`
    # next to the shell's own exec-once, so both are spawned at compositor
    # start: if the daemon is still binding its socket when the shell first asks,
    # spawning our own races it for the same socket, and awww-daemon aborts on a
    # failed connect rather than declining politely. Waiting costs a second only
    # when nothing is running at all, which is the case that has to start one.
    local i
    for i in $(seq 1 5); do
        sleep 0.2
        awww query >/dev/null 2>&1 && return 0
    done
    local attempt
    for attempt in 1 2 3 4 5; do
        awww-daemon >/dev/null 2>&1 &
        for i in $(seq 1 15); do
            awww query >/dev/null 2>&1 && return 0
            sleep 0.2
        done
    done
    return 1
}

list_pics() {
    find "$WPDIR" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' \)
}

refill_bag() {
    local current="" shuffled
    [ -r "$STATE" ] && current=$(cat "$STATE")
    shuffled=$(list_pics | shuf)
    [ -n "$shuffled" ] || return 0
    if [ "$(printf '%s\n' "$shuffled" | head -n1)" = "$current" ] && [ "$(printf '%s\n' "$shuffled" | wc -l)" -gt 1 ]; then
        shuffled=$(printf '%s\n' "$shuffled" | tail -n +2; printf '%s\n' "$current")
    fi
    mkdir -p "$(dirname "$BAG")"
    printf '%s\n' "$shuffled" > "$BAG"
}

pop_bag() {
    local line refilled=false
    mkdir -p "$(dirname "$BAG")"
    (
        flock 9
        while :; do
            if [ ! -s "$BAG" ]; then
                [ "$refilled" = true ] && exit 1
                refill_bag
                refilled=true
                [ -s "$BAG" ] || exit 1
            fi
            line=$(head -n1 "$BAG")
            tail -n +2 "$BAG" > "$BAG.tmp" && mv "$BAG.tmp" "$BAG"
            if [ -f "$line" ]; then
                printf '%s\n' "$line"
                exit 0
            fi
        done
    ) 9>"$BAG.lock"
}

# True when the daemon is up AND already painting something. init needs this to
# tell a healthy screen apart from an empty one: both answer `awww query`
# successfully, so the old daemon_was_running test could not. A fresh login is
# the case that matters — Hyprland starts awww-daemon at session start with no
# image set, so the daemon is up, the desktop is black, and "restore" was being
# skipped as unnecessary. jq answers it precisely; the grep fallback keeps it
# right on a box without jq.
daemon_painted() {
    local js shown
    js=$(awww query -j 2>/dev/null) || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$js" \
            | jq -e '[ .[]?[]?.displaying?.image? | select(type == "string" and length > 0) ] | length > 0' \
            >/dev/null 2>&1 || return 1
        # Up is not painted. awww keeps reporting the last image it was asked
        # for even after that file is deleted -- a theme switch rm -rf's
        # current/theme, a temp dir gets cleaned up -- so a path it still names
        # is no evidence that anything is on screen. Check the file is still
        # there, or this reports a healthy desktop over a black one and init
        # skips the restore that would have fixed it.
        shown=$(printf '%s' "$js" \
            | jq -r '[ .[]?[]?.displaying?.image? | select(type == "string" and length > 0) ] | .[0] // empty' \
            2>/dev/null)
    else
        printf '%s' "$js" | grep -qE '"image"[[:space:]]*:[[:space:]]*"[^"]+"' || return 1
        shown=$(printf '%s' "$js" | sed -n 's/.*"image"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    [ -n "$shown" ] || return 1
    if [ ! -f "$shown" ]; then
        echo "better: the wallpaper on screen is gone ($shown)" >&2
        return 1
    fi
    return 0
}

outputs() {
    hyprctl monitors -j 2>/dev/null | jq -r '.[].name'
}

focused_output() {
    hyprctl monitors -j 2>/dev/null | jq -r '[.[] | select(.focused)] | first.name // empty'
}

cursor_output() {
    local pos cx cy hit
    pos=$(hyprctl cursorpos 2>/dev/null) || { focused_output; return; }
    cx=${pos%%,*}
    cy=${pos##*, }
    hit=$(hyprctl monitors -j 2>/dev/null | jq -r --argjson cx "$cx" --argjson cy "$cy" \
        'map(select(
            $cx >= .x and $cx < .x + ((if (.transform % 2) == 1 then .height else .width end) / .scale) and
            $cy >= .y and $cy < .y + ((if (.transform % 2) == 1 then .width else .height end) / .scale)
        )) | first.name // empty')
    [ -n "$hit" ] && printf '%s\n' "$hit" || focused_output
}

map_get() {
    awk -F'\t' -v o="$1" '$1 == o { print $2; exit }' "$MAP" 2>/dev/null || true
}

# The real file behind a wallpaper path, or empty if there isn't one.
#
# Everything that RECORDS or REPAINTS a wallpaper goes through here, because a
# wallpaper path is routinely a symlink and storing one loses in two ways.
#
# It can dangle: omarchy's theme-set hook passes `current/background`, and that
# link's target lives inside `current/theme/backgrounds`, which a theme switch
# `rm -rf`s and replaces. `-f` follows symlinks, so every liveness check passed
# while the link pointed at nothing -- restore_all believed the entry existed,
# repainted it, and the desktop went black with no check reporting failure.
#
# And it can silently change meaning even when it resolves: `current/background`
# is rewritten on every theme switch, so a map entry naming it starts pointing
# at a different image without the map changing at all.
#
# Resolving at the point of recording fixes both: the map names a file, and the
# file keeps meaning what it meant. Deliberately resolved on every read as well
# as every write, so an entry written by an older version heals itself.
resolve_pic() {
    local p="${1:-}" resolved
    [ -n "$p" ] || return 1
    resolved=$(readlink -f -- "$p" 2>/dev/null) || return 1
    [ -n "$resolved" ] && [ -f "$resolved" ] || return 1
    printf '%s\n' "$resolved"
}

map_put() {
    # Store the file, never the link. See resolve_pic.
    local resolved
    resolved=$(resolve_pic "$2") || return 0
    mkdir -p "$(dirname "$MAP")"
    { awk -F'\t' -v o="$1" '$1 != o' "$MAP" 2>/dev/null || true; printf '%s\t%s\n' "$1" "$resolved"; } > "$MAP.tmp"
    mv "$MAP.tmp" "$MAP"
}

map_put_all() {
    local o
    # Store the file, never the link. See resolve_pic: a symlink in the map is
    # both dangle-prone and liable to silently change meaning.
    local resolved
    resolved=$(resolve_pic "$1") || return 0
    mkdir -p "$(dirname "$MAP")"
    : > "$MAP.tmp"
    for o in $(outputs); do
        printf '%s\t%s\n' "$o" "$resolved" >> "$MAP.tmp"
    done
    mv "$MAP.tmp" "$MAP"
}

make_still() {
    ffmpeg -y -loglevel error -i "$1" -frames:v 1 -f image2 -c:v png "$2.tmp" && mv "$2.tmp" "$2"
}

# Animated picks wave in over their own first frame, then swap to the live
# source with no transition: the frames are identical, so the gif restart and
# the mpvpaper spawn stop reading as a flicker at the end of the wave.
apply_visual() {
    local pic="$1" out="${2:-}" show="$1" st
    local -a oflag=()
    [ -n "$out" ] && oflag=(--outputs "$out")
    case "${pic##*.}" in
        [Mm][Pp]4|[Ww][Ee][Bb][Mm]|[Mm][Kk][Vv]|[Mm][Oo][Vv]|[Gg][Ii][Ff])
            st="$STILL"
            [ -n "$out" ] && st="${STILL%.png}-$out.png"
            make_still "$pic" "$st" && show="$st"
            ;;
    esac
    # One pass, and a frame rate a wallpaper can justify.
    #
    # 60fps for a background transition is the most expensive setting available
    # and buys nothing here: the frame is a full-screen composite of a 4K image,
    # so halving the frame rate halves the work the compositor does during the
    # second or so the change takes, and the difference is not visible on a
    # surface that is not the thing being watched.
    #
    # --transition-duration is the one that actually sets how long the change
    # takes, and it defaults to THREE seconds. It was never passed, so every
    # wallpaper pick -- and every wallpaper a theme switch or the poll brings in
    # -- animated for three full seconds, which is what read as the desktop
    # being laggy rather than as an animation. --transition-step and
    # --transition-fps shape the sweep but do not shorten it, so raising those
    # alone changed nothing.
    #
    # Half a second keeps the wave legible as a wave -- the direction still
    # sweeps, so the change still reads as deliberate -- while landing well
    # inside the time it takes to reach for the next wallpaper. Longer than
    # this and picking through a set of wallpapers means waiting on each one.
    #
    # The second `awww img` that used to follow is gone. It could never run:
    # `show` differs from `pic` only for a video still, and `! is_video "$pic"`
    # excluded exactly those, so the branch was unreachable while still paying
    # for a read of it on every change.
    awww img ${oflag[@]+"${oflag[@]}"} "$show" \
        --resize "$FIT" \
        --transition-type wave \
        --transition-angle 30 \
        --transition-wave "60,30" \
        --transition-duration "$TRANSITION_SECONDS" \
        --transition-fps 30 \
        --transition-step 90
}

# The desired video set comes from the map, collapsed to one '*' instance when
# every output plays the same file so a shared video decodes once. The running
# instances are compared first and the kill/respawn skipped on a match, so
# changing one monitor's still never restarts the other monitor's video. The mpv
# scaling follows the fit flag: a fit change keeps the same pics, but the stored
# fit diverging from the running one forces the respawn so the videos re-arm
# under the new options.
sync_videos() {
    local desired="" actual="" o pic outs n_out n_vid VOPTS
    outs=$(outputs)
    for o in $outs; do
        pic=$(map_get "$o")
        [ -n "$pic" ] && [ -f "$pic" ] && is_video "$pic" || continue
        desired+="$o"$'\t'"$pic"$'\n'
    done
    n_out=$(printf '%s\n' "$outs" | sed '/^$/d' | wc -l)
    n_vid=$(printf '%s' "$desired" | sed '/^$/d' | wc -l)
    if [ "$n_vid" -gt 0 ] && [ "$n_vid" = "$n_out" ] && [ "$(printf '%s' "$desired" | cut -f2 | sort -u | wc -l)" = 1 ]; then
        desired="*"$'\t'"$(printf '%s' "$desired" | head -n1 | cut -f2)"$'\n'
    fi
    desired=$(printf '%s' "$desired" | sort)
    # Running set keyed by the output, keeping the whole trailing path so a file
    # name with spaces can never read as a different video and force a kill-and-
    # respawn loop (each cycle re-decodes the clip and re-grows the buffer pools).
    actual=$(for o in $outs; do
        mpv_list | awk -v o="$o" '
            { n = 0; for (i = 1; i <= NF; i++) if ($i == o || $i == "*") n = i }
            n { for (j = 1; j <= n; j++) $j = ""; sub(/^ +/, ""); print o "\t" $0 }'
    done | sort -u)
    # When the desired set is the collapsed shared instance ('*'), fold the
    # running set to the same shape whenever every running video is that same
    # file: mpvpaper only reports real output names, so without this a shared
    # video would restart on every sync even though nothing changed.
    if [ "$(printf '%s' "$desired" | head -n1 | cut -f1)" = "*" ] \
        && [ "$(printf '%s' "$actual" | cut -f2 | sort -u | wc -l)" = 1 ] \
        && [ -n "$(printf '%s' "$actual" | cut -f2 | head -n1)" ]; then
        actual="*"$'\t'"$(printf '%s' "$actual" | cut -f2 | sort -u)"
    fi
    VOPTS=$(opts_for_fit)
    if [ "$(cat "$FIT_STATE" 2>/dev/null || true)" != "$VOPTS" ]; then
        if mpv_running; then
            stop_mpv
            actual=""
        fi
    fi
    mkdir -p "$(dirname "$FIT_STATE")"
    printf '%s\n' "$VOPTS" > "$FIT_STATE.tmp" && mv "$FIT_STATE.tmp" "$FIT_STATE"
    [ "$desired" = "$actual" ] && return 0
    if mpv_running; then
        stop_mpv
    fi
    [ -n "$desired" ] || return 0
    sleep 0.8
    while IFS=$'\t' read -r o pic; do
        [ -n "$o" ] || continue
        setsid -f mpvpaper -p -o "$VOPTS" "$o" "$pic" >/dev/null 2>&1
    done <<< "$desired"
}

# The palette follows the focused monitor: whatever hangs there drives matugen,
# the global state file and the global still, so the Settings dynamic re-run
# and the strip's current marker stay coherent with what the user looks at.
palette_update() {
    local pmode focused pic show mh md
    focused=$(focused_output)
    pic=""
    [ -n "$focused" ] && pic=$(map_get "$focused")
    [ -n "$pic" ] || pic=$(cat "$STATE" 2>/dev/null || true)
    [ -n "$pic" ] && [ -f "$pic" ] || return 0
    show="$pic"
    if is_video "$pic"; then
        make_still "$pic" "$STILL" && show="$STILL" || return 0
    fi
    mkdir -p "$(dirname "$STATE")"
    printf '%s\n' "$pic" > "$STATE"
    pmode=$(jq -r '.paletteMode // "static"' "$flags_file" 2>/dev/null || echo static)
    mkdir -p "$(dirname "$WLOG")"
    # Always refresh the shared wallpaper palette (colors.json) so both dynamic
    # modes (pill and dock) track the wallpaper. In manual mode the rice side
    # effects on top follow the pill's hue through --hue, which no longer
    # rewrites colors.json.
    python3 "$(dirname "$0")/wallcolors.py" "$show" >>"$WLOG" 2>&1 || true
    if [ "$pmode" = "manual" ]; then
        mh=$(jq -r '.manualHue // 30' "$flags_file" 2>/dev/null || echo 30)
        md=$(jq -r 'if .manualDark == false then "light" else "dark" end' "$flags_file" 2>/dev/null || echo dark)
        ms=$(jq -r '.manualSat // 0.5' "$flags_file" 2>/dev/null || echo 0.5)
        python3 "$(dirname "$0")/wallcolors.py" --hue "$mh" "$md" "$ms" >>"$WLOG" 2>&1 || true
    fi
    hyprctl reload >/dev/null 2>&1 || true
    busctl --user call com.mitchellh.ghostty /com/mitchellh/ghostty org.gtk.Actions \
        Activate "sava{sv}" reload-config 0 0 >/dev/null 2>&1 || true
    # kitty: remote-control reload (needs allow_remote_control in kitty.conf);
    # silently skipped when kitty is missing, not running, or IPC is disabled.
    # The call can hang forever when kitty is installed but no instance is up, so
    # it is walled in a timeout. The -k is what makes the wall real: plain
    # `timeout` only sends SIGTERM and then waits indefinitely for the target to
    # die, so a kitty client that ignores it left this script (and the QML
    # Process that spawned it) sitting in the process list forever.
    command -v kitty >/dev/null 2>&1 \
        && timeout -k 1 5 kitty @ set-colors "${XDG_CACHE_HOME:-$HOME/.cache}/better/kitty-colors" >/dev/null 2>&1 || true
}

map_has_video() {
    local o pic
    for o in $(outputs); do
        pic=$(map_get "$o")
        if [ -n "$pic" ] && [ -f "$pic" ] && is_video "$pic"; then
            return 0
        fi
    done
    return 1
}

# Refit without re-animating: unlike apply_visual's wave, a fit-mode change
# re-images the current stills with --transition-type none so toggling the
# strip's fit control rescales the screen in place. Videos briefly show their
# first frame again, then sync_videos restarts them under the new mpv scaling.
silent_reapply() {
    local o pic st candidate resolved
    for o in $(outputs); do
        # Resolved like every other reader: a map entry naming a symlink passes
        # `-f` while pointing at nothing, and handing that to awww is a black
        # screen. See resolve_pic.
        pic=""
        for candidate in "$(map_get "$o")" "$(cat "$STATE" 2>/dev/null || true)"; do
            if pic=$(resolve_pic "$candidate"); then
                break
            fi
            pic=""
        done
        [ -n "$pic" ] || continue
        # And write the healed value back, so a map entry written by an older
        # version is repaired the first time it is read rather than on every
        # read from now on.
        map_put "$o" "$pic"
        if is_video "$pic"; then
            st="$STILL"
            [ -n "$o" ] && st="${STILL%.png}-$o.png"
            make_still "$pic" "$st" && pic="$st"
        fi
        awww img --outputs "$o" --resize "$FIT" --transition-type none "$pic" >/dev/null 2>&1 || true
    done
}

restore_all() {
    local o pic any=false
    for o in $(outputs); do
        # Every candidate is resolved, so a dangling symlink left by an older
        # version -- or by a theme switch that removed the tree it pointed into
        # -- is rejected here instead of being handed to awww as if it were an
        # image. That is what painted a black screen: `-f` followed the link,
        # saw a file-shaped answer for a path that resolved to nothing, and
        # repainted the void.
        pic=""
        local candidate
        for candidate in "$(map_get "$o")" "$(cat "$STATE" 2>/dev/null || true)"; do
            if pic=$(resolve_pic "$candidate"); then
                break
            fi
            pic=""
        done
        [ -n "$pic" ] || pic=$(pop_bag) || continue
        pic=$(resolve_pic "$pic") || continue
        map_put "$o" "$pic"
        apply_visual "$pic" "$o"
        any=true
    done
    [ "$any" = true ] || exit 0
    sync_videos
    palette_update
    exit 0
}

cmd="${1:-}"
target=""

# ---------------------------------------------------------------------------
# wallpaper ownership
# ---------------------------------------------------------------------------
#
# Who a wallpaper belongs to, which is what decides whether an incoming
# wallpaper is allowed to replace the one on screen.
#
# The reason this exists: omarchy-theme-set repoints
# current/background at one of the new theme's own backgrounds on every theme
# switch, and both the wallpaper poll in ThemeSync and the theme-set hook feed
# that path straight into `set`. So a wallpaper the user had picked was
# replaced by the theme's every time a theme changed, with nothing on either
# side able to tell a theme switch from a deliberate choice. The bar kept
# painting, so it looked like the wallpaper had quietly reverted.
#
# Ownership separates the two cases. A path inside a theme's own backgrounds
# folder is the theme's to choose, so it may take over freely -- that is how
# switching themes is supposed to change the wallpaper. Anything else is a file
# the user put there, so a theme wallpaper does not get to discard it.
#
# Both theme locations count as the theme's. current/theme/backgrounds is the
# stock set; ~/.config/omarchy/backgrounds/<theme> is where omarchy-theme-set
# also looks (omarchy-theme-set:79), so a wallpaper a user drops there to
# customise a theme is still that theme's to switch between. Reading only one
# of the two would let a theme wallpaper overwrite the other one's pick.
#
# Prints "theme", "user", or "none" for a path that resolves to nothing --
# a wallpaper that has been deleted, or was never a file. Callers treat "none"
# as "nothing worth protecting", which is what lets a theme wallpaper through
# once the file it would replace is gone.
wallpaper_owner() {
    local path="$1" resolved theme_name

    # -f follows symlinks, so current/background resolves to the real file
    # rather than reporting on the link itself.
    resolved=$(readlink -f -- "$path" 2>/dev/null) || resolved=""
    [ -n "$resolved" ] && [ -f "$resolved" ] || { printf 'none\n'; return 0; }

    # A recorded pick is the user's whatever folder it landed in. Checked
    # before the path test, because the common case is a pick that landed in
    # the theme's own backgrounds folder: sync_theme.py points the bar's picker
    # there so the chooser shows the theme's set, which means most picks are
    # theme-owned by path and a path test alone would let the next theme switch
    # take them over -- the wallpaper disappearing again, one theme later.
    if [ -f "$PICK_MARKER" ] && grep -qxF "$resolved" "$PICK_MARKER" 2>/dev/null; then
        printf 'user\n'
        return 0
    fi

    theme_name=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null) || theme_name=""

    case "$resolved" in
        "$HOME/.local/state/omarchy/current/theme/backgrounds/"*) printf 'theme\n' ;;
        "$HOME/.config/omarchy/backgrounds/$theme_name/"*)         printf 'theme\n' ;;
        *)                                                          printf 'user\n' ;;
    esac
}

# Record a wallpaper as the user's own pick.
#
# Called from the strip's apply path, which is the only place a wallpaper is
# chosen on purpose. The marker is what lets ownership survive the pick landing
# inside a theme's backgrounds folder -- see wallpaper_owner.
#
# Appended rather than replaced, and only while the file is one this session can
# vouch for: a stale entry naming a deleted wallpaper would keep protecting a
# path that no longer exists, so entries are pruned on every write instead of
# accumulating. The marker is a convenience, not the record of what is on
# screen -- that stays $STATE.
# The permanent collection, chosen independently of `wallpaperDir`.
#
# It cannot just be $WPDIR: this desktop's wallpaperDir points at
# `current/theme/backgrounds` — which is exactly the transient directory the
# preserve exists to escape. Using it copied a wallpaper onto itself, and the
# pick stayed a pick from the theme. So the destination is resolved separately,
# and a candidate that lives inside `current/theme` is rejected outright.
permanent_collection() {
    local cand
    for cand in "$HOME/Pictures/Wallpapers" "$HOME/Pictures/wallpapers" \
                "$HOME/Wallpapers" "$HOME/wallpapers"; do
        case "$cand" in
            "$HOME/.local/state/omarchy/current/"*) continue ;;
        esac
        if [ -n "$WPDIR" ] && [ "$WPDIR" != "$cand" ]; then
            case "$WPDIR" in
                "$HOME/.local/state/omarchy/current/"*) break ;;
            esac
        fi
        printf '%s\n' "$cand"
        return 0
    done
    printf '%s\n' "$HOME/Pictures/Wallpapers"
}

preserve_pick() {
    local pic="${1:-}" resolved dest destdir

    resolved=$(readlink -f -- "$pic" 2>/dev/null) || return 0
    [ -n "$resolved" ] && [ -f "$resolved" ] || return 0

    # Nothing to preserve if it is already in a permanent collection: copying it
    # onto itself only costs a stat.
    case "$resolved" in
        "$HOME/Pictures/Wallpapers/"*|"$HOME/Pictures/wallpapers/"*|"$HOME/Wallpapers/"*|"$HOME/wallpapers/"*)
            mark_pick "$resolved"
            return 0
            ;;
    esac

    # A wallpaper picked from an active theme's backgrounds lives inside
    # `current/theme`, which omarchy deletes wholesale on every theme switch
    # (`rm -rf current/theme; mv next/theme current/theme`). So the pick was
    # temporary by construction — switch theme and it is gone, the recorded path
    # is dead, and there is nothing left to restore. The user did nothing wrong
    # and lost a wallpaper they chose.
    #
    # Copy it out on the way in and record THAT path. A copy rather than a move,
    # so the theme keeps the file it shipped with and uninstalling the theme
    # leaves the copy behind.
    #
    # A name collision between two themes that both ship `backgrounds/void.png`
    # would silently overwrite the first, so theme-namespace the destination.
    destdir=$(permanent_collection)

    local theme_name qualifier=""
    theme_name=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null | tr -cd '[:alnum:]-') || theme_name=""
    # `case`, not `[ = ]`: in POSIX test the `*` is LITERAL, so
    #   [ "$p" = "$dir/"* ]
    # compares against the string ending in a star and is always false. That is
    # why every preserved copy arrived unprefixed and collided with the theme's
    # own file of the same name.
    if [ -n "$theme_name" ]; then
        case "$resolved" in
            "$HOME/.local/state/omarchy/current/theme/backgrounds/"*) qualifier="$theme_name-" ;;
        esac
    fi

    mkdir -p "$destdir" 2>/dev/null || { mark_pick "$resolved"; return 0; }
    dest="$destdir/$qualifier$(basename "$resolved")"

    if [ "$dest" = "$resolved" ]; then
        # Nowhere permanent to put it; keep the pick on the original rather
        # than losing it to a failed copy.
        mark_pick "$resolved"
        return 0
    fi

    if cp -p -- "$resolved" "$dest" 2>/dev/null && [ -f "$dest" ]; then
        mark_pick "$dest"
    else
        # A full or read-only disk is not a reason to lose the pick.
        mark_pick "$resolved"
    fi
}

# Where a pick was preserved to, or "" if it was not.
# Callers use this so the recorded path — the map and the state file — names the
# copy rather than the theme's own file, and therefore outlives the theme.
preserved_path() {
    local pic="${1:-}" resolved dest destdir theme_name qualifier
    resolved=$(readlink -f -- "$pic" 2>/dev/null) || return 0
    [ -n "$resolved" ] && [ -f "$resolved" ] || return 0
    case "$resolved" in
        "$HOME/Pictures/Wallpapers/"*|"$HOME/Pictures/wallpapers/"*|"$HOME/Wallpapers/"*|"$HOME/wallpapers/"*)
            printf '%s\n' "$resolved"
            return 0
            ;;
    esac
    destdir=$(permanent_collection)
    theme_name=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null | tr -cd '[:alnum:]-') || theme_name=""
    qualifier=""
    if [ -n "$theme_name" ]; then
        case "$resolved" in
            "$HOME/.local/state/omarchy/current/theme/backgrounds/"*) qualifier="$theme_name-" ;;
        esac
    fi
    dest="$destdir/$qualifier$(basename "$resolved")"
    [ -f "$dest" ] && [ "$dest" != "$resolved" ] && printf '%s\n' "$dest"
    return 0
}

mark_pick() {
    local pic="${1:-}" resolved keep existing

    resolved=$(readlink -f -- "$pic" 2>/dev/null) || return 0
    [ -n "$resolved" ] && [ -f "$resolved" ] || return 0

    mkdir -p "$(dirname "$PICK_MARKER")" || return 0

    keep=$(mktemp "$PICK_MARKER.XXXXXX") || return 0
    : > "$keep"
    if [ -f "$PICK_MARKER" ]; then
        while IFS= read -r existing; do
            [ -n "$existing" ] || continue
            [ "$existing" = "$resolved" ] && continue
            [ -f "$existing" ] || continue
            printf '%s\n' "$existing" >> "$keep"
        done < "$PICK_MARKER"
    fi
    printf '%s\n' "$resolved" >> "$keep"
    mv -f "$keep" "$PICK_MARKER" 2>/dev/null || rm -f "$keep"
}

# May $1 replace the wallpaper currently on screen? Exit 0 for yes.
#
# The rule in one line: a theme wallpaper may not replace a wallpaper the user
# owns. Everything else -- another theme wallpaper, the user's own file, an
# empty state, a file that has since been deleted -- may apply.
#
# --force skips the check, and the wallpaper surface passes it for a pick made
# in the strip. A user who taps a theme's own wallpaper in the strip is making
# that choice deliberately, and it must not be second-guessed here; only the
# wallpaper arriving on its own, from a theme switch, is ever refused.
should_apply() {
    local candidate="$1" force="${2:-}" current

    [ "$force" = "--force" ] && return 0

    [ "$(wallpaper_owner "$candidate")" = "theme" ] || return 0

    current=$(cat "$STATE" 2>/dev/null) || current=""
    [ -n "$current" ] || return 0
    [ "$(wallpaper_owner "$current")" = "user" ] || return 0

    return 1
}

# Report ownership, for the surface and for tests. Answering this without
# touching the daemon is the point: the surface asks on every wallpaper change
# to decide whether to follow, and that must not start or wait on awww.
if [ "$cmd" = "owner" ]; then
    wallpaper_owner "${2:-}"
    exit 0
fi

# Record a pick. Reached before the daemon, because marking must work even when
# awww is missing or wedged: the whole point is that the wallpaper survives
# later, and a wallpaper that failed to paint is still the one the user chose.
if [ "$cmd" = "mark-pick" ]; then
    mark_pick "${2:-}"
    exit 0
fi

# The guard on its own, for the same reason. Exits 0 when the wallpaper may
# apply, so a caller can use it as a plain condition.
if [ "$cmd" = "should-apply" ]; then
    should_apply "${2:-}" "${3:-}"
    exit $?
fi

# regen: refresh the shared wallpaper palette (colors.json, in the better cache
# dir) from the current wallpaper, without touching the daemon or any wallpaper
# state. Fired when a dynamic mode is picked, so switching to dynamic re-derives
# from the live wallpaper even when the cached palette went stale — e.g. written
# by an older install that stored the manual hue in colors.json.
if [ "$cmd" = "regen" ]; then
    palette_update
    exit 0
fi

daemon_was_running=true
awww query >/dev/null 2>&1 || daemon_was_running=false
ensure_daemon || exit 0

if [ "$cmd" = "init" ]; then
    if [ ! -s "$MAP" ] && [ -s "$STATE" ]; then
        pic=$(cat "$STATE")
        [ -f "$pic" ] && map_put_all "$pic"
    fi
    if [ "$daemon_was_running" = true ]; then
        if map_has_video && ! mpv_running; then
            sync_videos
        fi
        # Up is not the same as painted. When the daemon came up empty, put the
        # recorded wallpaper back; the old check only ever restored a daemon
        # that was down, which a session-managed one never is at this point.
        # Gated on a wallpaper actually being on record: with nothing recorded
        # there is nothing to restore, and restore_all would otherwise reach for
        # the bag and paint a random pick nobody asked for. When the daemon
        # already shows the right image this is skipped, so reloading the shell
        # never replays the wave transition over a correct desktop.
        if { [ -s "$STATE" ] || [ -s "$MAP" ]; } && ! daemon_painted; then
            restore_all
        fi
        exit 0
    fi
    restore_all
elif [ "$cmd" = "set" ]; then
    pic="${2:-}"
    [ -f "$pic" ] || exit 1
    # The output may be omitted ("set <pic>") or given as "all", and --force
    # may sit on either side of it, so both are pulled out of the argument
    # list rather than read positionally. Reading $3 as the target would miss
    # a trailing --force, and the guard would then refuse a wallpaper the user
    # had just picked in the strip.
    shift                       # drop "set"
    force=""
    target=""
    for arg in "$@"; do
        case "$arg" in
            "$pic") ;;                       # the wallpaper, already read
            --force) force="--force" ;;
            *) [ -z "$target" ] && target="$arg" ;;
        esac
    done
    [ "$target" = "all" ] && target=""

    # A pick is recorded before the wallpaper is painted, not after: the paint
    # can fail (a missing codec, a full disk) and the wallpaper is still the
    # one the user chose, so the marker must not depend on the paint landing.
    [ -n "$force" ] && preserve_pick "$pic"

    # A wallpaper the user owns outranks a theme wallpaper arriving on its
    # own, so refuse and put the symlink back. Both halves matter: without the
    # repoint, current/background keeps advertising the theme's wallpaper, so
    # the next poll re-offers it and the wallpaper looks like it keeps
    # snapping back. omarchy-theme-set wrote that link, and it is the state
    # every other wallpaper reader trusts, so it is left agreeing with what is
    # actually on screen.
    if ! should_apply "$pic" "$force"; then
        kept=$(cat "$STATE" 2>/dev/null) || kept=""
        if [ -n "$kept" ] && [ -f "$kept" ]; then
            ln -nsf "$kept" "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true
            printf 'better: kept your wallpaper, ignoring the theme default\n' >&2
        fi
        exit 0
    fi

    # Repoint current/background on a SUCCESSFUL set, not only on a refusal.
    #
    # This is the link omarchy-theme-set writes and "the state every other
    # wallpaper reader trusts" -- the refusal branch above already maintains it,
    # but the success branch did not, so the link kept advertising whatever the
    # theme had installed. The next background-set hook then fired with that
    # stale target and re-applied it, silently undoing the pick.
    #
    # Resolved to the real file: a pick made from a theme's backgrounds directory
    # is reached THROUGH omarchy's current/theme symlink, and pointing the link at
    # a path that a later theme switch would replace would strand it.
    if [ -n "$pic" ]; then
        resolved=$(readlink -f -- "$pic" 2>/dev/null) || resolved="$pic"
        [ -f "$resolved" ] && \
            ln -nsf "$resolved" "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true
        # And record the FILE. This used to resolve only to repoint the link
        # and let $pic go on into the map as whatever the caller passed, which
        # for omarchy's own theme-set hook is the `current/background` symlink.
        # See resolve_pic for why a link must never be what gets stored.
        # The pick now records the PRESERVED copy, so the value that goes on
        # into the map and the state file names a file that outlives the
        # theme it was picked from. resolve_pic already ran, so this cannot
        # turn $pic into a link.
        # No `local`: this is the script body, not a function.
        kept=""
        if kept=$(preserved_path "$pic"); then
            pic="$kept"
        fi
    fi
elif [ "$cmd" = "fit" ]; then
    mode="${2:-crop}"
    case "$mode" in no|crop|fit|stretch) ;; *) mode=crop ;; esac
    if command -v jq >/dev/null 2>&1; then
        jq --arg v "$mode" '.wallpaperFit = $v' "$flags_file" > "$flags_file.tmp" 2>/dev/null \
            && mv "$flags_file.tmp" "$flags_file" || true
    fi
    FIT="$mode"
    silent_reapply
    sync_videos
    exit 0
else
    scope=$(jq -r '.randomScope // "all"' "$flags_file" 2>/dev/null || echo all)
    if [ "$scope" = "cursor" ]; then
        target=$(cursor_output)
    fi
    pic=$(pop_bag) || exit 0
fi

[ -n "$pic" ] || exit 0

if [ -n "$target" ]; then
    map_put "$target" "$pic"
else
    map_put_all "$pic"
fi

apply_visual "$pic" "$target"
sync_videos
palette_update
