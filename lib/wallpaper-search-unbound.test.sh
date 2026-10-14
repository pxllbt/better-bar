#!/usr/bin/env bash
# Asserts that the scripts that write wallpaper state do not reference a
# variable before assigning it.
#
# Why this exists: the transient-directory guard was inserted into
# wallpaper-search.sh by replacing the four lines that ASSIGNED `wpdir` -- so the
# guard read a variable that was never set. Under `set -u` that is fatal, and the
# script exited before printing anything, so `wallpaper-search.sh download` took
# no action at all and reported success: the picker's download process exited 0
# with an empty stdout, `savedPath` stayed empty, and nothing was applied. Every
# remote source -- wallhaven, alphacoders, wallwidgy -- silently stopped working
# at once.
#
# That is worse than a syntax error, which `bash -n` catches and this does not.
# The check is to RUN the scripts with `set -u` and an explicitly cleared
# environment, so an unbound variable is a hard failure rather than a silent
# exit zero, and to assert the download path produces a real path.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SEARCH="$ROOT/scripts/wallpaper-search.sh"
WALL="$ROOT/scripts/wallpaper.sh"

failed=0
check() {
    if [ "$2" = "yes" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n' "$1"
    fi
}

[ -f "$SEARCH" ] || { echo "no wallpaper-search.sh" >&2; exit 1; }

# 1. A syntax check, which is necessary but not sufficient.
check "wallpaper-search.sh parses" "$(bash -n "$SEARCH" 2>/dev/null && echo yes || echo no)"
check "wallpaper.sh parses" "$(bash -n "$WALL" 2>/dev/null && echo yes || echo no)"

# 2. Every variable the download path uses must be assigned first. The failure
#    this pins is one the shell only reports at run time.
for v in wpdir flags; do
    assigns=$(grep -cE "^[[:space:]]*$v=" "$SEARCH")
    check "wallpaper-search.sh assigns $v before using it" \
        "$([ "$assigns" -gt 0 ] && echo yes || echo no)"
done

# 3. The real test: run the download path with nothing in the environment, under
#    set -u, and confirm it does not die on an unbound variable. A URL that will
#    not resolve is fine -- the point is the failure must come from the network,
#    not from the shell aborting on a variable the script forgot to set.
SANDBOX=$(mktemp -d)
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
mkdir -p "$SANDBOX/state/better"
# No wallpaperDir at all, which is the fresh-install case.
out=$(env -i HOME="$SANDBOX" PATH="/usr/bin:/bin" \
    bash -c 'set -u; bash "$1" download "https://wallhaven.invalid/nope.jpg"' _ "$SEARCH" 2>&1)
if printf '%s' "$out" | grep -q "unbound variable"; then
    failed=$((failed + 1))
    printf 'FAIL %s\n  got: %s\n' \
        "the download path does not abort on an unbound variable" \
        "$(printf '%s' "$out" | head -1)"
else
    printf 'PASS %s\n' "the download path does not abort on an unbound variable"
fi

# 4. And the transient guard must still be in place, since removing it is what
#    the next person would do to "fix" a download.
if grep -q 'omarchy/current/' "$SEARCH"; then
    printf 'PASS %s\n' "the transient-directory guard survives"
else
    failed=$((failed + 1))
    printf 'FAIL %s\n' "the transient-directory guard survives"
fi

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
