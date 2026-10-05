#!/usr/bin/env bash
# Tests for the alphacoders wallpaper source.
#
# The parse is the whole feature and it is worth pinning down hard, because
# Alpha Coders serves no API: a category page is HTML, and everything the strip
# needs has to come out of it. That makes three things easy to get subtly wrong
# and invisible until browsing looks broken:
#
#   * the thumbnail URL and the wallpaper id live in *different* attributes of
#     the same tile, so parsing one and dropping the other yields tiles that
#     render but cannot be picked
#   * a page repeats each id (a <source> and an <img> per breakpoint), so a
#     naive extract returns every wallpaper two or three times
#   * the full-size file is not derivable from the thumbnail URL -- some are
#     .jpg and some .png, and the extension cannot be guessed -- so the pick has
#     to go back to the page for the real URL rather than rewriting the thumb
#
# Network is stubbed by putting a fake `curl` on PATH, so these are assertions
# about the parser rather than about today's site.

set -uo pipefail

SEARCH="${1:?usage: alphacoders.test.sh <path to wallpaper-search.sh>}"
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

# A category page shaped like the real one: each wallpaper appears as a link to
# big.php?i=<id> wrapping a <picture> with a webp source and an <img>, so the
# id shows up three times per tile the way it does on the live site.
mkpage() {
    cat <<PAGE
<!DOCTYPE html><html><body>
<div class="center">
  <a href="https://wall.alphacoders.com/big.php?i=72092" title="HD desktop wallpaper featuring a vibrant, abstract fractal design with cool colors.">
    <picture>
      <source media="(max-width:400px)" srcset="https://images2.alphacoders.com/720/thumb-350-72092.jpg">
      <source srcset="https://images2.alphacoders.com/720/thumbbig-72092.webp">
      <img class="thumb" src="https://images2.alphacoders.com/720/thumbbig-72092.webp" alt="abstract">
    </picture>
  </a>
</div>
<div class="center">
  <a href="https://wall.alphacoders.com/big.php?i=48578" title="HD desktop wallpaper featuring a mountain range at dusk.">
    <picture>
      <source media="(max-width:400px)" srcset="https://images4.alphacoders.com/485/thumb-350-48578.jpg">
      <source srcset="https://images4.alphacoders.com/485/thumbbig-48578.webp">
      <img class="thumb" src="https://images4.alphacoders.com/485/thumbbig-48578.webp" alt="nature">
    </picture>
  </a>
</div>
<div class="center">
  <a href="https://wall.alphacoders.com/big.php?i=8788" title="4K desktop wallpaper featuring a red geometric pattern.">
    <picture>
      <source media="(max-width:400px)" srcset="https://images4.alphacoders.com/878/thumb-350-8788.png">
      <source srcset="https://images4.alphacoders.com/878/thumbbig-8788.webp">
      <img class="thumb" src="https://images4.alphacoders.com/878/thumbbig-8788.webp" alt="abstract">
    </picture>
  </a>
</div>
</body></html>
PAGE
}

# The detail page for a wallpaper: the full-size file is in og:image, which is
# the only place it appears. It is named thumb-* but is the original bytes, and
# it keeps the real extension -- .jpg for 72092, .png for 8788.
JPG_PAGE='<html><head><meta property="og:image" content="https://images2.alphacoders.com/720/thumb-1920-72092.jpg"></head><body>1920x1200</body></html>'
PNG_PAGE='<html><head><meta property="og:image" content="https://images4.alphacoders.com/878/thumb-1920-8788.png"></head><body>2560x1600</body></html>'
EMPTY_PAGE='<html><head><title>not found</title></head><body>gone</body></html>'

# A curl stub: prints the body, then the status code on its own line, the way
# `curl -w '\n%{http_code}'` does. Written as a single generated script with
# the page bodies inlined, because a stub that had to call back into these
# functions would need them exported and that is what made the first version of
# this stub fail.
mkbin() {
    local page_b64 jpg_b64 png_b64 empty_b64
    page_b64=$(mkpage | base64 -w0)
    jpg_b64=$(printf '%s' "$JPG_PAGE" | base64 -w0)
    png_b64=$(printf '%s' "$PNG_PAGE" | base64 -w0)
    empty_b64=$(printf '%s' "$EMPTY_PAGE" | base64 -w0)
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'url=""; for a in "$@"; do case "$a" in http*) url="$a";; esac; done'
        # Log every call so the cache assertion can tell a cache hit from a
        # second request.
        printf '%s\n' "printf '%s\\n' \"\$url\" >> '$TMP/calls'"
        printf '%s\n' 'body=""; code="404"'
        printf '%s\n' 'b64() { printf %s "$1" | base64 -d; }'
        printf '%s\n' 'case "$url" in'
        # Redirects, answered as the page they point at. Only followed when the
        # caller passed -L, which is what makes the missing-flag case visible.
        printf '%s\n' '  *art-wallpapers*|*cars-wallpapers*|*minimal-wallpapers*|*tech-wallpapers*)'
        printf '%s\n' '    for a in "$@"; do'
        printf '%s\n' '      case "$a" in'
        # Any bundled short flag containing L, so -sL counts the way real curl
        # reads it. Matching a bare -L would let a stub pass against a script
        # that only ever sent -s.
        printf '%s\n' '        -*L*|--location*) body=$(b64 '"$page_b64"'); code=200; break ;;'
        printf '%s\n' '      esac'
        printf '%s\n' '    done'
        printf '%s\n' '    [ -n "$body" ] || { body=""; code=301; } ;;'
        printf '%s\n' '  *alphacoders.com/*-wallpapers*)'
        printf '%s\n' '    if [ "${AC_PAGE_FAIL:-0}" = 1 ]; then body=nope; code=503;'
        printf '%s\n' '    else'
        printf '      body=$(b64 %s)\n' "$page_b64"
        printf '%s\n' '      code=200'
        printf '%s\n' '    fi ;;'
        printf '%s\n' '  *big.php?i=72092*) body=$(b64 '"$jpg_b64"'); code=200 ;;'
        printf '%s\n' '  *big.php?i=48578*) body=$(b64 '"$jpg_b64"'); code=200 ;;'
        printf '%s\n' '  *big.php?i=8788*)  body=$(b64 '"$png_b64"'); code=200 ;;'
        printf '%s\n' '  *big.php?i=999999*) body=$(b64 '"$empty_b64"'); code=200 ;;'
        printf '%s\n' '  *thumbbig-*) : > "$TMP/fake.webp"; code=200 ;;'
        printf '%s\n' 'esac'
        printf '%s\n' 'printf "%s" "$body"'
        printf '%s\n' 'printf "\n%s" "$code"'
    } > "$1"
    chmod +x "$1"
}

# Only curl is stubbed. jq, awk and sha1sum are the real ones on purpose: they
# do the actual work under test, and stubbing them would let the assertions
# pass against a fake pipeline.
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"
mkbin "$TMP/bin/curl"

# Both XDG roots are redirected, not just the cache one: wh_state puts the
# per-page cache under XDG_STATE_HOME, and pointing only XDG_CACHE_HOME at the
# temp dir left the real machine's cached pages in play -- which is how a run
# kept reporting a stale entry from an earlier, broken parse.
export XDG_CACHE_HOME="$TMP/cache"
export XDG_STATE_HOME="$TMP/state"
export HOME="$TMP/home"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

# One field of one entry. The index is honoured, because a helper that printed
# every entry's field made a correct three-entry page look like a wrong answer.
jqfield() {
    printf '%s' "$1" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d[int(sys.argv[1])].get(sys.argv[2],""))' "$2" "$3" 2>/dev/null
}
count() { printf '%s' "$1" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'; }

# --- parsing ---------------------------------------------------------------
out=$(bash "$SEARCH" acsearch abstract 1)
ok "acsearch: one entry per wallpaper on the page" "$(count "$out")" "3"
ok "acsearch: the thumbnail URL is taken from the tile" \
    "$(jqfield "$out" 0 thumb)" "https://images2.alphacoders.com/720/thumbbig-72092.webp"
ok "acsearch: the pick URL carries the wallpaper id" \
    "$(jqfield "$out" 0 image)" "https://wall.alphacoders.com/big.php?i=72092"
ok "acsearch: every entry has both a thumb and a pick URL" \
    "$(printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(sum(1 for x in d if x.get("thumb") and x.get("image")))')" "3"
ok "acsearch: ids are not duplicated by the repeated source tags" \
    "$(printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ids=[x["image"] for x in d]
print("unique" if len(ids)==len(set(ids)) else "dupes")')" "unique"

# The stub counts its own invocations, so a second call for the same page can be
# told apart from a second request. Without a counter this assertion would pass
# on a cache that never existed.
ok "acsearch: a repeated page is served from cache without a new request" \
    "$(bash "$SEARCH" acsearch abstract 1 >/dev/null; \
       bash "$SEARCH" acsearch abstract 1 >/dev/null; \
       grep -c 'alphacoders.com/.*-wallpapers' "$TMP/calls")" "1"

# An unknown category falls back to the default collection rather than
# erroring, so browsing with a stale category name from an older version still
# shows wallpapers instead of an empty strip.
out=$(bash "$SEARCH" acsearch notreal 1)
ok "acsearch: an unknown category falls back rather than erroring" \
    "$(count "$out")" "$(count "$(bash "$SEARCH" acsearch minimal 1)")"

# Four category names the strip offers are not the site's own: it redirects
# art -> artistic, cars -> cars-(pixar), minimal -> minimalist, tech ->
# technology. The stub answers a redirect as the page it points at, so a missing
# -L shows up here as those four categories parsing to nothing.
ok "acsearch: a redirected category name still returns wallpapers" \
    "$(count "$(bash "$SEARCH" acsearch tech 1)")" "3"

# A page the site refuses answers empty, so the strip shows its empty state
# instead of spinning. Exported rather than prefixed, and run against a
# category no earlier assertion cached, so what is measured is the failure
# path rather than a cached success.
export AC_PAGE_FAIL=1
out=$(bash "$SEARCH" acsearch nature 1)
unset AC_PAGE_FAIL
ok "acsearch: a failing page answers empty instead of erroring" "$out" "[]"

ok "acsearch: a non-numeric page falls back to page 1" \
    "$(bash "$SEARCH" acsearch abstract notanumber | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')" "3"

# --- picking ---------------------------------------------------------------
# A pick has to recover the real file, because the thumbnail URL cannot be
# rewritten into one: the extension differs per wallpaper and is only known
# from the detail page.
out=$(bash "$SEARCH" acresolve "https://wall.alphacoders.com/big.php?i=72092")
ok "acresolve: a jpg wallpaper resolves to the full-size jpg" \
    "$out" "https://images2.alphacoders.com/720/72092.jpg"

out=$(bash "$SEARCH" acresolve "https://wall.alphacoders.com/big.php?i=8788")
ok "acresolve: a png wallpaper keeps its png extension" \
    "$out" "https://images4.alphacoders.com/878/8788.png"

ok "acresolve: a detail page with no image yields nothing" \
    "$(bash "$SEARCH" acresolve "https://wall.alphacoders.com/big.php?i=999999")" ""

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'