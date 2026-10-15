#!/usr/bin/env bash
# Asserts every settings page announces itself, and that the index's headings
# describe what is beneath them.
#
# Why it exists: one page shipped with no header. Screens opened with no title
# and no chevron of its own, while every sibling had both. The failure is
# invisible in review -- the page still works, and nothing errors -- it just
# looks like the one settings page nobody finished. Which is what "the settings
# aren't organised" reduces to once you look: not a missing taxonomy, but a page
# that doesn't say where you are.
#
# Counting headers rather than reading each surface is what turns "I happened to
# notice" into a check. It is also what caught the two ways my own first attempt
# was wrong: it matched a *comment* mentioning SettingsSurface in a surface that
# is not one, and it demanded a back chevron on a page whose header deliberately
# closes the panel instead. So the scope is spelled out below rather than implied.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SURFACES="$ROOT/surfaces"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -d "$SURFACES" ] || { echo "no surfaces/ at $SURFACES" >&2; exit 1; }

# Scope: a *settings page*, meaning a file whose root declaration is
# SettingsSurface. That phrasing is the point -- matching a SettingsSurface
# mention anywhere in the file sweeps in surfaces that merely reference one in a
# comment (SysmonSurface, a panel) and surfaces that host a SettingsHeader
# without being one (DockSurface).
is_settings_page() {
    grep -qE '^SettingsSurface \{' "$1"
}

missing=0
while IFS= read -r f; do
    is_settings_page "$f" || continue
    if ! grep -q 'SettingsHeader' "$f"; then
        printf '  no header: %s\n' "$(basename "$f")"
        missing=$((missing + 1))
    fi
done < <(find "$SURFACES" -name '*.qml' | sort)

ok "every settings page carries a header" "$missing" "0"

# The header has to name its page. A SettingsHeader with an empty title draws
# the chrome without saying what it belongs to.
no_title=0
while IFS= read -r f; do
    is_settings_page "$f" || continue
    grep -q 'SettingsHeader' "$f" || continue
    if ! grep -A4 'SettingsHeader {' "$f" | grep -q 'title:'; then
        printf '  no title: %s\n' "$(basename "$f")"
        no_title=$((no_title + 1))
    fi
done < <(find "$SURFACES" -name '*.qml' | sort)

ok "every header names its page" "$no_title" "0"

# --- the index's headings describe what is beneath them ----------------
INDEX="$SURFACES/Appearance.qml"
[ -f "$INDEX" ] || { echo "no $INDEX" >&2; exit 1; }

# Count rows, not `name: "` -- the chevron glyph carries one too, so a loose
# pattern reports a group of one as a group of two and the check passes on the
# broken layout it is meant to catch.
group_rows() {
    sed -n "/$1/,/$2/p" "$INDEX" | grep -c 'SettingsRow {'
}

ok "the Bar & Dock Layout heading names more than one surface" \
    "$(group_rows 'Bar & Dock Layout' '--- ')" "3"
ok "the Visuals & Theme heading names more than one surface" \
    "$(group_rows 'Visuals & Theme' '--- ')" "3"
ok "the System & Extensions heading names more than one surface" \
    "$(sed -n '/--- System & Extensions ---/,$p' "$INDEX" | grep -c 'SettingsRow {')" "3"

# Dock Settings is what the layout heading names, so it has to sit inside that
# group -- and not under a heading of its own, which is what made the group a
# heading over a single row.
ok "Dock Settings sits under the layout heading it belongs to" \
    "$(sed -n '/--- Bar & Dock Layout ---/,/--- System/p' "$INDEX" |
        grep -c 'name: "Dock Settings"')" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'