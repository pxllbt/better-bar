#!/usr/bin/env bash
set -euo pipefail

flags_file="${XDG_STATE_HOME:-$HOME/.local/state}/better/flags.json"
WPDIR=$(jq -r '.wallpaperDir // ""' "$flags_file" 2>/dev/null || echo "")
FIT=$(jq -r '.wallpaperFit // "crop"' "$flags_file" 2>/dev/null || echo crop)
case "$FIT" in no|crop|fit|stretch) ;; *) FIT=crop ;; esac
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
    local js
    js=$(awww query -j 2>/dev/null) || return 1
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$js" \
            | jq -e '[ .[]?[]?.displaying?.image? | select(type == "string" and length > 0) ] | length > 0' \
            >/dev/null 2>&1
        return $?
    fi
    printf '%s' "$js" | grep -qE '"image"[[:space:]]*:[[:space:]]*"[^"]+"'
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

map_put() {
    mkdir -p "$(dirname "$MAP")"
    { awk -F'\t' -v o="$1" '$1 != o' "$MAP" 2>/dev/null || true; printf '%s\t%s\n' "$1" "$2"; } > "$MAP.tmp"
    mv "$MAP.tmp" "$MAP"
}

map_put_all() {
    local o
    mkdir -p "$(dirname "$MAP")"
    : > "$MAP.tmp"
    for o in $(outputs); do
        printf '%s\t%s\n' "$o" "$1" >> "$MAP.tmp"
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
    awww img ${oflag[@]+"${oflag[@]}"} "$show" \
        --resize "$FIT" \
        --transition-type wave \
        --transition-angle 30 \
        --transition-wave "60,30" \
        --transition-fps 60 \
        --transition-step 90
    if [ "$show" != "$pic" ] && ! is_video "$pic"; then
        sleep 0.9
        awww img ${oflag[@]+"${oflag[@]}"} "$pic" --resize "$FIT" --transition-type none
    fi
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
    local o pic st
    for o in $(outputs); do
        pic=$(map_get "$o")
        [ -n "$pic" ] && [ -f "$pic" ] || pic=$(cat "$STATE" 2>/dev/null || true)
        [ -n "$pic" ] && [ -f "$pic" ] || continue
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
        pic=$(map_get "$o")
        [ -n "$pic" ] && [ -f "$pic" ] || pic=$(cat "$STATE" 2>/dev/null || true)
        [ -n "$pic" ] && [ -f "$pic" ] || pic=$(pop_bag) || continue
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

    theme_name=$(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null) || theme_name=""

    case "$resolved" in
        "$HOME/.local/state/omarchy/current/theme/backgrounds/"*) printf 'theme\n' ;;
        "$HOME/.config/omarchy/backgrounds/$theme_name/"*)         printf 'theme\n' ;;
        *)                                                          printf 'user\n' ;;
    esac
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
