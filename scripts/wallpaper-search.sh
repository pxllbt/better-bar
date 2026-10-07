#!/usr/bin/env bash

UA="Mozilla/5.0 (X11; Linux x86_64) Gecko/20100101 Firefox/126.0"

search_moewalls() {
    local query="${1:-}"
    UA="$UA" python3 - "$query" <<'PYEOF'
import concurrent.futures
import json
import os
import re
import sys
import urllib.parse
import urllib.request

ua = os.environ.get("UA", "Mozilla/5.0")

def fetch(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Referer": "https://moewalls.com/"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "ignore")

def post_entry(url):
    html = fetch(url)
    prev = re.search(r'<source src="(/wp-content/uploads/preview/[^"]+)"', html)
    token = re.search(r'id="moe-download"[^>]*data-url="([^"]+)"', html)
    thumb = re.search(r'poster="([^"]+)"', html)
    if not prev or not token:
        return None
    res = re.search(r'resolutions-(\d+)x(\d+)', html)
    return {
        "image": "https://go.moewalls.com/download.php?video=" + token.group(1),
        "thumb": urllib.parse.urljoin("https://moewalls.com/", thumb.group(1)) if thumb else "",
        "preview": urllib.parse.urljoin("https://moewalls.com/", prev.group(1)),
        "w": int(res.group(1)) if res else 0,
        "h": int(res.group(2)) if res else 0,
    }

try:
    q = urllib.parse.quote(sys.argv[1])
    page = fetch("https://moewalls.com/?s=" + q, timeout=12)
    posts = []
    for m in re.finditer(r'href="(https://moewalls\.com/[a-z0-9-]+/[a-z0-9-]+-live-wallpaper/)"', page):
        if m.group(1) not in posts:
            posts.append(m.group(1))
    out = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        for entry in ex.map(post_entry, posts[:24]):
            if entry:
                out.append(entry)
    print(json.dumps(out))
except Exception:
    print("[]")
PYEOF
}

wh_state() {
    local base="${XDG_STATE_HOME:-$HOME/.local/state}/better"
    mkdir -p "$base"
    printf '%s\n' "$base"
}

# Shared rate gate for every wallhaven-bound request (API searches, thumbnail
# fetches, picks), so the strip can never trip wallhaven's limits again: the
# documented API cap is 45 calls/min (429 past it), and a Cloudflare WAF has
# also banned whole IPs on request bursts — one such burst here took even a
# cookie'd browser down with a 403. The gate is a rolling-window budget: it
# lets a burst through (so a fresh page of thumbs loads in seconds instead of
# trickling), but caps everything wallhaven-bound at WH_BUDGET (default 30)
# requests per 60s, shared across all processes via a timestamp journal, and
# latches a hard cooling-off period on any throttle/block signal.
wh_state() {
    local base="${XDG_STATE_HOME:-$HOME/.local/state}/better"
    mkdir -p "$base"
    printf '%s\n' "$base"
}

# Suspend all wallhaven traffic for `secs` (default 60). Seeded by any 429/403
# the fetchers see, so a throttle resets the whole pipeline's clock instead of
# letting parts of the UI keep slipping requests through.
wh_backoff() {
    local secs="${1:-60}" base
    base=$(wh_state)
    printf '%s\n' "$(( $(date +%s) + secs ))" > "$base/wh-cooldown.until"
}

wh_gate() {
    local base budget now oldest need_ms count
    base=$(wh_state)
    budget="${WH_BUDGET:-30}"
    { [ "$budget" -gt 0 ] 2>/dev/null; } || budget=30
    exec 9>"$base/wh-window.lock"
    flock 9

    # Cooling-off latch: a recent 429/403 parks every wallhaven request until
    # the timestamp passes. The lock is held throughout so the whole pipeline
    # wakes together instead of trickling back in.
    local cooldown until now_s
    cooldown="$base/wh-cooldown.until"
    if [ -f "$cooldown" ]; then
        until=$(cat "$cooldown" 2>/dev/null || echo 0)
        now_s=$(date +%s)
        if [ "$now_s" -lt "$until" ]; then
            sleep "$(( until - now_s ))"
        fi
        rm -f "$cooldown"
    fi

    window="$base/wh-window.ts"
    while :; do
        now=$(date +%s%N)
        if [ -f "$window" ]; then
            awk -v now="$now" ' $0 + 60000000000 > now ' "$window" > "$window.tmp" \
                && mv "$window.tmp" "$window"
            count=$(wc -l < "$window")
        else
            count=0
        fi
        if [ "$count" -lt "$budget" ]; then
            printf '%s\n' "$now" >> "$window"
            break
        fi
        # Budget exhausted: wait until the oldest in-window request ages out.
        oldest=$(head -1 "$window")
        need_ms=$(( 60000 - (now - oldest) / 1000000 ))
        if [ "$need_ms" -le 250 ]; then
            # Nearly expired anyway — nudge past without a clever sleep.
            sleep 0.3
        else
            sleep "$(awk -v w="$need_ms" 'BEGIN { printf "%.3f", w/1000 }')"
        fi
    done
    flock -u 9
}

# Wallhaven browse/search. An empty query returns the default hot feed —
# clicking the strip's wallhaven chip lands there; a query tags it. The third
# arg picks the sort bucket (hot, latest, top, random, favorites). Each maps to
# the API's own sort, so the UI labels mean exactly what the site's tabs show:
# hot -> the Hot feed (rolls over constantly), latest -> date_added, top ->
# toplist over the last month (its topRange window rolls, so it is not frozen),
# random -> random, favorites -> all-time Top Liked (kept for API parity, not
# exposed in the UI because it never changes). A typed query keeps the chosen
# sort — there is no silent favorites fallback, which used to make tag searches
# show the same static most-favorited wallpapers forever. The API serves
# ready-made thumbs, so results are URLs handed over to `thumbget` for a paced
# local copy: nothing is downloaded until the strip actually shows it.
whsearch() {
    local query="${1:-}" page="${2:-1}" want="${3:-}"
    case "$page" in
        ''|*[!0-9]*) page=1 ;;
    esac

    local enc sort extra raw code base key mapped
    enc=$(jq -rn --arg q "$query" '$q|@uri') || { printf '[]\n'; return 0; }
    sort="hot"
    extra=""
    case "$want" in
        latest)    sort="date_added" ;;
        top)       sort="toplist"; extra="topRange=1M&" ;;
        random)    sort="random" ;;
        favorites) sort="favorites" ;;
        hot)       sort="hot" ;;
    esac
    # Hot is the default browse bucket and the API's real Hot sort: it rolls
    # over constantly, unlike toplist/views/favorites which sit on the same
    # mega-popular page one for weeks. Top maps to toplist (with a rolling 1M
    # window) so it changes over time instead of freezing on all-time views.
    # A typed query keeps the picked sort; there is no implied favorites.

    base=$(wh_state)
    key=$(printf '%s' "$query|$page|$sort" | sha1sum | cut -c1-24)
    cache="$base/wh-cache/$key.json"
    # Dedupe: a repeat of the same query+page+sort within the window replays the
    # stored chunk without any network. The UI re-fires the current page on
    # picks, sort changes and surface re-entry, which used to be a fresh request
    # every time; now those are free.
    if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt 20 ]; then
        cat "$cache"
        return 0
    fi

    wh_gate
    raw=$(curl -s --max-time 15 -w $'\n%{http_code}' -A "$UA" \
        "https://wallhaven.cc/api/v1/search?${query:+q=${enc}&}sorting=${sort}&${extra}order=desc&page=${page}")
    code="${raw##*$'\n'}"
    raw="${raw%$'\n'*}"
    [ -n "$code" ] || code=000
    if [ "$code" = "000" ]; then
        # No HTTP response at all — offline, DNS failure, or a time-out. That
        # is a network hiccup, not wallhaven blocking us: don't latch a phantom
        # cooldown or a blocked chip, just hand back an empty page and let the
        # UI sit idle until connectivity returns.
        printf '[]\n'
        return 0
    fi
    if [ "$code" != "200" ]; then
        # 429 = the documented rate cap (45/min); 403/5xx = WAF block or edge
        # hiccup. Either way latch a hard cooldown so no part of the UI can
        # keep requesting, and hand the UI a pause marker — its slow retry
        # timer owns the re-checks, and this is never cached.
        case "$code" in
            429) wh_backoff 120 ;;
            *)   wh_backoff 60 ;;
        esac
        printf '%s\n' '{"wallhaven":"blocked"}'
        return 0
    fi
    [ -n "$raw" ] || { printf '%s\n' '{"wallhaven":"blocked"}'; return 0; }

    # Map the wallhaven JSON to the strip's entry shape and keep the mapped
    # chunk as the dedupe cache line.
    mapped=$(printf '%s' "$raw" | jq -c '
        .data // []
        | map({
            image: .path,
            thumb: (.thumbs.large // .thumbs.original // ""),
            w: (.dimension_x // 0),
            h: (.dimension_y // 0)
          })
        | map(select(.image != null and .image != ""))
    ' 2>/dev/null || true)
    if [ -n "$mapped" ]; then
        mkdir -p "$base/wh-cache"
        printf '%s\n' "$mapped" > "$cache"
        printf '%s\n' "$mapped"
    else
        printf '%s\n' '{"wallhaven":"blocked"}'
    fi
}

# ---------------------------------------------------------------------------
# Alpha Coders
# ---------------------------------------------------------------------------
#
# A third source, and the only one with no API at all: api.alphacoders.com is
# gone (404), so a category page is scraped HTML. The site splits phone
# wallpapers into separate `<category>-phone-wallpapers` sections, so the
# desktop sections are already free of them and no orientation filter is
# needed here.
#
# Both pieces of a wallpaper live in different attributes of the same tile --
# the id in the link to wall.alphacoders.com/big.php?i=<id>, the thumbnail in
# the picture's source -- so both are pulled per tile rather than one being
# matched up to the other afterwards. Each id appears three times in the markup
# (a source per breakpoint plus the img), so tiles are emitted once per unique
# id; a naive extract returns the same wallpaper two or three times and the
# strip fills with duplicates.
#
# The full-size file cannot be derived from the thumbnail URL. Alpha Coders
# serves .jpg and .png from the same shape of path and nothing in the listing
# says which, so a pick goes back to the wallpaper's own page for it. That
# costs one request per pick, which is the right trade: picks are deliberate
# and rare, and a strip full of tiles that cannot be downloaded is worthless.

# One wallpaper's entry: the thumbnail the tile renders, and the page the pick
# resolves through.
AC_PAGE_URL='https://alphacoders.com'
AC_VIEW_URL='https://wall.alphacoders.com/big.php?i='

# True when $1 is one of the categories this source is browsed by. The site
# has far more sections than the strip offers; these are the ones that line up
# with what the other two sources already expose, so switching sources keeps
# the meaning of the category row.
ac_category_ok() {
    case "${1:-}" in
        abstract|anime|amoled|architecture|art|cars|minimal|nature|tech) ;;
        *) return 1 ;;
    esac
}

# Parse a category page into the strip's entry shape. Reads the page on stdin.
#
# awk rather than grep -o here because the two fields are ordered differently
# per tile -- the link precedes the picture in every tile seen so far, but a
# regex that assumed it would silently drop the tail of a page the moment the
# markup shifted. Matching the id anywhere in the tile and the thumb anywhere
# in the same tile does not care about their order.
ac_parse_page() {
    awk '
        # New tile: a link to the wallpaper page carries its id.
        /big\.php\?i=[0-9]+/ {
            # The digits are matched directly rather than sliced out of a
            # wider match, so no offset arithmetic can drift and leave the
            # "=" or a stray character glued to the id.
            if (match($0, /big\.php\?i=[0-9]+/)) {
                line = $0
                sub(/.*big\.php\?i=/, "", line)
                sub(/[^0-9].*$/, "", line)
                id = line
                thumb = ""
                have = 1
            }
        }
        # The thumbnail for the tile being read. Kept as the last one seen so a
        # page that repeats the image per breakpoint still yields one thumb.
        have && /thumbbig-[0-9]+\.webp/ {
            if (match($0, /https:\/\/images[0-9]*\.alphacoders\.com\/[0-9]+\/thumbbig-[0-9]+\.webp/))
                thumb = substr($0, RSTART, RLENGTH)
        }
        # End of tile: the </a> closes the link the id came from, which is the
        # only reliable boundary between one wallpaper and the next.
        have && /<\/a>/ {
            if (thumb != "" && !(id in seen)) {
                seen[id] = 1
                printf "{\"thumb\":\"%s\",\"image\":\"%s%s\"}\n", thumb, "'"$AC_VIEW_URL"'", id
            }
            id = ""
            thumb = ""
            have = 0
        }
    '
}

# Browse one category page. Output is JSON lines, which the caller turns into
# an array; a page that cannot be fetched answers an empty array so the strip
# shows its empty state rather than spinning.
acsearch() {
    local cat="${1:-}" page="${2:-1}" base cache raw code mapped
    ac_category_ok "$cat" || cat="minimal"
    case "$page" in
        ''|*[!0-9]*) page=1 ;;
    esac
    [ "$page" -lt 1 ] && page=1

    base=$(wh_state)
    cache="$base/ac-cache/$(printf '%s' "$cat-$page" | sha1sum | cut -c1-24).json"

    # Cached for the same window as the wallhaven chunks: the strip re-fires a
    # page on every entry and category change, and the collection moves slowly
    # enough that a fresh fetch is almost never what is wanted.
    if [ -f "$cache" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -lt 1200 ]; then
        cat "$cache"
        return 0
    fi

    # -L because four of the category names the strip uses are not the site's own:
    # it redirects art -> artistic, cars -> cars-(pixar), minimal ->
    # minimalist and tech -> technology. Without following, those four answer
    # 301 with an empty body, which parsed as "this category has no
    # wallpapers" and left four of the nine chips permanently blank.
    raw=$(curl -sL --max-time 20 -w $'\n%{http_code}' -A "$UA" \
        "$AC_PAGE_URL/$cat-wallpapers?page=$page")
    # The site serves an empty 200 for an out-of-range page rather than a 404,
    # so a page number past the end is a legitimate empty answer and not a
    # failure to report.
    code="${raw##*$'\n'}"
    raw="${raw%$'\n'*}"
    [ -n "$code" ] || code=000
    # 000 is offline or a timeout rather than the site refusing: no cooldown
    # latch here, because there is no rate budget to protect. An empty answer
    # lets the strip sit idle until connectivity returns.
    [ "$code" = "200" ] || { printf '[]\n'; return 0; }

    # fromjson on each line: -R reads the awk output as raw strings, so without it
# the array would hold the JSON as text and every consumer would get a string
# where it expects an entry.
    mapped=$(printf '%s\n' "$raw" | ac_parse_page \
        | jq -R -s -c 'split("\n") | map(select(length > 0)) | map(fromjson)')

    if [ -z "$mapped" ] || [ "$mapped" = "[]" ]; then
        printf '[]\n'
        return 0
    fi

    mkdir -p "$(dirname "$cache")"
    printf '%s\n' "$mapped" > "$cache"
    printf '%s\n' "$mapped"
}

# Recover the full-size image URL for a picked wallpaper.
#
# The detail page's og:image is the original file, named thumb-1920-<id>.<ext>
# because it is also what the page shows inline. The name is rewritten to
# <id>.<ext>, keeping the extension the site chose -- which is the whole point,
# since guessing it wrong 404s on the png wallpapers.
acresolve() {
    local url="${1:-}" id raw full
    id="${url##*=}"
    case "$id" in
        ''|*[!0-9]*) printf '\n'; return 0 ;;
    esac

    raw=$(curl -s --max-time 20 -A "$UA" "$url")
    [ -n "$raw" ] || { printf '\n'; return 0; }

    full=$(printf '%s\n' "$raw" | grep -oE \
        'https://images[0-9]*\.alphacoders\.com/[0-9]+/thumb-1920-[0-9]+\.(jpg|png)' \
        | head -1 | sed -E 's#/thumb-1920-([0-9]+)\.(jpg|png)$#/\1.\2#')

    printf '%s\n' "$full"
}

# WallWidgy browse. The API's search endpoint only ever hands back a
# handful of random picks, but its index endpoint lists the whole
# collection with metadata (category, orientation, resolution,
# timestamp). The index is cached for an hour; each call filters it
# to desktop wallpapers of the chosen collection (or all of them),
# newest first, and slices out the requested page. Results are JSON
# in the strip's entry shape, like whsearch, plus the matching total
# so the UI can page without asking the server.
wwsearch() {
    local cat="${1:-}" count="${2:-17}" page="${3:-0}"
    case "$count" in
        ''|*[!0-9]*) count=17 ;;
    esac
    [ "$count" -gt 2000 ] && count=2000
    [ "$count" -lt 1 ] && count=1
    case "$page" in
        ''|*[!0-9]*) page=0 ;;
    esac
    case "$cat" in
        all|"") cat="all" ;;
        abstract|anime|amoled|architecture|art|cars|minimal|nature|tech) ;;
        *) cat="minimal" ;;
    esac

    local base idx raw code
    base=$(wh_state)
    mkdir -p "$base/ww-cache"
    idx="$base/ww-index.json"
    # The collection changes slowly, so the index is kept for an hour.
    # A stale or corrupt cache is re-fetched; with no response at all
    # a stale cache still serves, and only a cold cache yields an
    # empty page until connectivity returns.
    if ! { [ -f "$idx" ] && [ $(( $(date +%s) - $(stat -c %Y "$idx") )) -lt 3600 ] && jq -e 'type == "array"' "$idx" >/dev/null 2>&1; }; then
        raw=$(curl -s --max-time 20 -w $'\n%{http_code}' -A "$UA" \
            "https://wallwidgy.vercel.app/api/wallpapers/index")
        code="${raw##*$'\n'}"
        raw="${raw%$'\n'*}"
        [ -n "$code" ] || code=000
        if [ "$code" = "000" ]; then
            [ -f "$idx" ] || { printf '%s\n' '{"wallpapers":[],"total":0}'; return 0; }
        elif [ "$code" != "200" ] || [ -z "$raw" ]; then
            printf '%s\n' '{"wallwidgy":"blocked"}'
            return 0
        else
            printf '%s' "$raw" > "$idx"
        fi
    fi

    # Filter to desktop wallpapers of the collection, newest
    # first, then slice the page out. The thumb is the
    # collection's pre-scaled webp cache variant (a few tens
    # of KB) rather than the multi-megabyte master the image
    # field names — the strip renders tiles, not wallpapers,
    # and the master is fetched only when a pick is applied.
    jq -c --arg cat "$cat" --arg u "https://raw.githubusercontent.com/not-ayan/storage/main/" \
        --argjson skip "$(( page * count ))" --argjson take "$count" '
        ([.[] | select(.orientation == "Desktop" and .file_main_name != null and .file_main_name != "")]
         | if $cat == "all" then .
           else map(select((.category // "") | ascii_downcase == ("#" + ($cat | ascii_downcase)))) end
         | sort_by(.timestamp) | reverse) as $all
         | {
            wallpapers: ($all[$skip : ($skip + $take)]
              | map({ image: ($u + "main/" + .file_main_name),
                      thumb: (if (.file_cache_name // "") != ""
                              then ($u + "cache/" + .file_cache_name)
                              else ($u + "main/" + .file_main_name) end),
                      w: (.width // 0), h: (.height // 0) })),
            total: ($all | length)
          }
    ' "$idx" 2>/dev/null || printf '%s\n' '{"wallwidgy":"blocked"}'
}

# Fetch one wallhaven thumb into a disk cache at the same shared pace.
# Cached hits are served instantly with no network and no gate (Qt decodes by
# content, so the extensionless cache name is fine), so scrolling back over a
# page costs zero wallhaven requests. The cache is kept under
# WH_THUMB_MAX_MB (default 20): every fresh store prunes the least-recently
# used thumbs (newest just saved is kept) until the directory fits again.
thumbget() {
    local url="${1:-}"
    [ -n "$url" ] || exit 1
    local base digest cache tmp
    base="${XDG_CACHE_HOME:-$HOME/.cache}/better/wh-thumbs"
    digest=$(printf '%s\n' "$url" | sha1sum | cut -c1-24)
    # The cache holds the resized JPEG, so the suffix is part
    # of the name. Qt decodes by content, and the LRU prune
    # below counts the directory either way.
    cache="$base/$digest.jpg"
    # Cache check before mkdir — every hit skips the directory
    # creation entirely, which is the point of the disk cache.
    [ -s "$cache" ] && { printf '%s\n' "$cache"; exit 0; }
    mkdir -p "$base"
    # The rate gate exists for wallhaven's API budget. The
    # WallWidgy thumbnails come from GitHub's raw CDN, which
    # has no such budget, so they fetch without it -- the
    # fetch pool on the QML side already bounds how many run
    # at once.
    case "$url" in
        *wallhaven.cc*) wh_gate ;;
    esac
    tmp="$base/.$digest.tmp"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL --max-time 25 -A "$UA" -o "$tmp" "$url" \
        || exit 1
    [ -s "$tmp" ] || exit 1
    # Shrink anything a tile never needs to a 720px JPEG
    # before caching it. Wallhaven serves ready-made thumbs
    # and WallWidgy's cache variant is a pre-scaled webp,
    # so most fetches are already inside the box and are
    # cached untouched -- no decode, no encode, no CPU. The
    # ones that are not go through vips when it is
    # installed: it resizes in a single pass at a fraction
    # of ImageMagick's CPU and memory, and writes JPEG, a
    # tenth the size of the PNG it replaces. ImageMagick
    # stays as the fallback.
    local dim w h
    if command -v vipsheader >/dev/null 2>&1; then
        # [0-9]+ (not *) so a bare "x" in the path -- the
        # home directory is /home/pixllbeat -- cannot match
        # ahead of the real dimensions.
        dim=$(vipsheader "$tmp" 2>/dev/null | head -1 \
              | grep -oE '[0-9]+x[0-9]+' | head -1 | tr 'x' ' ')
    fi
    if [ -z "$dim" ]; then
        export MAGICK_CONFIGURE_PATH="$(dirname "$0")/magick-policy"
        dim=$(magick identify -format '%w %h' "$tmp" 2>/dev/null | head -1) || dim=""
        case "$dim" in
            *[!0-9\ ]*) dim="" ;;
        esac
    fi
    w=${dim%% *}
    h=${dim##* }
    if [ -n "$dim" ] && { [ "$w" -gt 720 ] || [ "$h" -gt 720 ]; }; then
        if command -v vipsthumbnail >/dev/null 2>&1; then
            vipsthumbnail "$tmp" -s 720x720 -o "$cache[Q=85]" \
                >/dev/null 2>&1 && [ -s "$cache" ] || rm -f "$cache"
        else
            export MAGICK_CONFIGURE_PATH="$(dirname "$0")/magick-policy"
            magick "$tmp" -resize '720x720>' -quality 85 "$cache" \
                2>/dev/null && [ -s "$cache" ] || rm -f "$cache"
        fi
        # A resize that failed leaves nothing behind: fall
        # back to the fetched file as-is, decoded by content.
        [ -s "$cache" ] || mv "$tmp" "$cache"
    else
        mv "$tmp" "$cache"
    fi
    local max_mb total old
    max_mb="${WH_THUMB_MAX_MB:-20}"
    { [ "$max_mb" -gt 0 ] 2>/dev/null; } || max_mb=20
    total=$(du -sk "$base" 2>/dev/null | awk '{print $1}')
    while [ "${total:-0}" -gt $(( max_mb * 1024 )) ]; do
        old=$(find "$base" -maxdepth 1 -type f ! -name '.*' \
              -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
        [ -n "$old" ] || break
        rm -f "$old"
        total=$(du -sk "$base" 2>/dev/null | awk '{print $1}')
    done
    printf '%s\n' "$cache"
}

search() {
    local query="${1:-}" kind="${2:-all}"
    [ -n "$query" ] || { printf '[]\n'; return 0; }

    if [ "$kind" = "motion" ]; then
        search_moewalls "$query"
        return 0
    fi

    local q="$query" f=",,,"
    case "$kind" in
        still)  f="type:photo" ;;
    esac

    local enc vqd raw
    enc=$(jq -rn --arg q "$q" '$q|@uri') || { printf '[]\n'; return 0; }

    vqd=$(curl -s --max-time 10 "https://duckduckgo.com/?q=${enc}&iax=images&ia=images" -A "$UA" \
        | grep -oP 'vqd=\\?"?\K[0-9-]+' | head -1)
    [ -n "$vqd" ] || { printf '[]\n'; return 0; }

    raw=$(curl -s --max-time 10 \
        "https://duckduckgo.com/i.js?l=us-en&o=json&q=${enc}&vqd=${vqd}&f=${f}&p=-1" \
        -A "$UA" -H "Referer: https://duckduckgo.com/")
    [ -n "$raw" ] || { printf '[]\n'; return 0; }

    printf '%s' "$raw" | jq -c --arg kind "$kind" '
        (.results // [])
        | if $kind == "still" then map(select(.image // "" | test("\\.gif(\\?|$)"; "i") | not)) else . end
        | map({
            image: .image,
            thumb: (.thumbnail // .image),
            w: (.width // 0 | if . == null then 0 else . end),
            h: (.height // 0 | if . == null then 0 else . end)
          })
        | map(select(.image != null and .image != ""))
        | .[0:60]
    ' 2>/dev/null || printf '[]\n'
}

download() {
    set -euo pipefail
    url="${1:-}"
    [ -n "$url" ] || exit 1

    # This script copy belongs to the better bar, so the collection a
    # pick lands in is the better bar's own state: the stock shell's
    # better/flags.json carries its own (empty) wallpaper dir, which
    # would drop every pick into the autodetect fallback instead of the
    # folder the bar resolved.
    flags="${XDG_STATE_HOME:-$HOME/.local/state}/better/flags.json"
    wpdir=$(jq -r '.wallpaperDir // ""' "$flags" 2>/dev/null || echo "")
    [ -n "$wpdir" ] || wpdir=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/better-wallpaper-dir" 2>/dev/null || true)
    [ -n "$wpdir" ] || wpdir="$HOME/Pictures/Wallpapers"
    # Every pick lands directly in the collection root so it joins the shuffle
    # bag; wallhaven keeps its id, moewalls/DDG get stamped names. No subfolder
    # is ever created, so browsing never leaves an empty downloads/ dir behind.

    case "$url" in
        https://go.moewalls.com/download.php*)
            fn=$(curl -fsI --max-time 20 -A "$UA" -e "https://moewalls.com/" "$url" \
                | grep -oiP 'filename=\K[^"\r\n;]+' | head -1 | tr -d '/\\')
            [ -n "$fn" ] || fn="moewalls-$(date +%s).mp4"
            out="$wpdir/$fn"
            curl -fsL --max-time 600 -A "$UA" -e "https://moewalls.com/" -o "$out" "$url" || exit 1
            [ -s "$out" ] || exit 1
            printf '%s\n' "$out"
            exit 0
            ;;
        https://wall.alphacoders.com/big.php\?i=*)
            # The listing cannot say whether a wallpaper is a jpg or a png --
            # both come off the same shape of path -- so the pick resolves the
            # real file from the wallpaper's own page. That is one extra request
            # per pick, which is the right way round: picks are deliberate and
            # rare, whereas guessing wrong 404s every png wallpaper.
            id="${url##*=}"
            case "$id" in
                ''|*[!0-9]*) exit 1 ;;
            esac
            full=$(acresolve "$url")
            [ -n "$full" ] || exit 1
            fn="alphacoders-$id.${full##*.}"
            out="$wpdir/$fn"
            curl -fsL --max-time 600 -A "$UA" -e "https://alphacoders.com/" -o "$out" "$full" || exit 1
            [ -s "$out" ] || exit 1
            printf '%s\n' "$out"
            exit 0
            ;;
        https://w.wallhaven.cc/*)
            # Picked wallhaven wallpaper lands in the collection root itself so
            # it joins the shuffle bag; the filename keeps the wallhaven id. A
            # pick is a wallhaven-bound request too, so it shares the pace gate
            # that protects the API and thumb CDN.
            wh_gate
            fn=$(basename "$url" | tr -d '/\\')
            [ -n "$fn" ] || exit 1
            out="$wpdir/$fn"
            curl -fsL --max-time 600 -A "$UA" -e "https://wallhaven.cc/" -o "$out" "$url" || exit 1
            [ -s "$out" ] || exit 1
            printf '%s\n' "$out"
            exit 0
            ;;
    esac

    tmp=$(mktemp "${TMPDIR:-/tmp}/ddg-wp.XXXXXX")
    trap 'rm -f "$tmp" "$tmp.out"' EXIT

    curl -fsL --max-time 60 -A "$UA" -e "https://duckduckgo.com/" -o "$tmp" "$url" || exit 1
    [ -s "$tmp" ] || exit 1

    export MAGICK_CONFIGURE_PATH="$(dirname "$0")/magick-policy"

    fmt=$(magick identify -format '%m' "${tmp}[0]" 2>/dev/null | head -1) || exit 1

    case "$fmt" in
        JPEG) ext=jpg ;;
        PNG)  ext=png ;;
        GIF)  ext=gif ;;
        WEBP) ext=webp ;;
        *)    ext=png ;;
    esac

    out="$wpdir/ddg-$(date +%s)-${RANDOM}.${ext}"

    if [ "$ext" = "png" ] && [ "$fmt" != "PNG" ]; then
        magick "${tmp}[0]" -strip "png:$tmp.out" 2>/dev/null || exit 1
        [ -s "$tmp.out" ] || exit 1
        mv "$tmp.out" "$out"
    else
        cp "$tmp" "$out"
    fi

    [ -s "$out" ] || exit 1
    printf '%s\n' "$out"
}

case "${1:-}" in
    search)   search "${2:-}" "${3:-all}" ;;
    whsearch) whsearch "${2:-}" "${3:-1}" "${4:-}" ;;
    # WallWidgy pages through the index: the bar passes category, page
    # size and the zero-based page. Without forwarding $4 every request
    # silently answered page 0, so the chevrons never moved.
    wwsearch) wwsearch "${2:-}" "${3:-17}" "${4:-0}" ;;
    # Alpha Coders: a category page, and the full-size URL for a picked
    # wallpaper (its detail page is the only place the real file appears, since
    # the listing gives no usable way to tell a jpg from a png).
    acsearch) acsearch "${2:-}" "${3:-1}" ;;
    acsearch) acsearch "${2:-}" "${3:-1}" ;;
    acresolve) acresolve "${2:-}" ;;
    thumbget) thumbget "${2:-}" ;;
    download) download "${2:-}" ;;
    *)        printf '[]\n'; exit 0 ;;
esac
