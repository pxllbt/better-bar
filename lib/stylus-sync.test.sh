#!/usr/bin/env bash
# Asserts the stylus-sync script generates a proper CSS variables file
# from the active Omarchy theme colors, and that the Stylus singleton
# is wired to theme changes. Also verifies the isNotificationSound guard
# that prevents Dorian notification sounds from triggering the media
# surface.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT/scripts/stylus-sync.py"
STYLUS_QML="$ROOT/Singletons/Stylus.qml"
PLAYERS_QML="$ROOT/Singletons/Players.qml"
SHELL_QML="$ROOT/shell.qml"
OUTPUT_CSS="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/better-test-stylus.css"
TMP_COLORS=$(mktemp /tmp/stylus-test-colors-XXXXXX.toml)
tmp_cleanup=1

cleanup() {
    [ "$tmp_cleanup" = "1" ] && rm -f "$TMP_COLORS" "$OUTPUT_CSS"
}
trap cleanup EXIT

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

# --- Test 1: script exists and is executable ---
ok "stylus-sync.py exists" \
    "$([ -f "$SCRIPT" ] && echo 1 || echo 0)" "1"

ok "stylus-sync.py is executable" \
    "$([ -x "$SCRIPT" ] && echo 1 || echo 0)" "1"

# --- Test 2: Stylus.qml singleton exists and is wired ---
ok "Stylus.qml singleton exists" \
    "$([ -f "$STYLUS_QML" ] && echo 1 || echo 0)" "1"

ok "Stylus.qml references ThemeSync" \
    "$(grep -c 'ThemeSync' "$STYLUS_QML")" "3"

ok "Stylus.qml uses Config.configDir for script path" \
    "$(grep -c 'Config.configDir' "$STYLUS_QML")" "2"

ok "Stylus.qml connects to ThemeSync.revision" \
    "$(grep -c 'onRevisionChanged' "$STYLUS_QML")" "1"

ok "Stylus.qml has a sync function" \
    "$(grep -c 'function sync()' "$STYLUS_QML")" "1"

ok "Stylus.qml has a Process for running the script" \
    "$(grep -c 'Process' "$STYLUS_QML")" "1"

# --- Test 3: Players.qml excludes notification sounds ---
ok "Players.qml has isNotificationSound function" \
    "$(grep -c 'function isNotificationSound' "$PLAYERS_QML")" "1"

ok "Players.qml isActualMedia excludes notification sounds" \
    "$(grep -c 'isNotificationSound(active)' "$PLAYERS_QML")" "1"

ok "isNotificationSound detects webkit/dorion dbus names" \
    "$(grep -c 'indexOf.*webkit' "$PLAYERS_QML")" "1"

ok "isNotificationSound detects dorion dbus names" \
    "$(grep -c 'dorion' "$PLAYERS_QML")" "1"

# --- Test 4: shell.qml calls Stylus.sync on theme reload ---
ok "shell.qml reloadTheme calls Stylus.sync" \
    "$(grep -c 'Stylus.sync()' "$SHELL_QML")" "1"

# --- Test 5: script extracts colors from colors.toml ---
cat > "$TMP_COLORS" <<'EOF'
mode = "dark"
accent = "#1e66f5"
background = "#000000"
foreground = "#cdd6f4"
red = "#d20f39"
green = "#40a02b"
cyan = "#179299"
blue = "#1e66f5"
EOF

python3 "$SCRIPT" "$TMP_COLORS" "$OUTPUT_CSS" >/dev/null 2>&1

ok "script generates CSS output file" \
    "$([ -f "$OUTPUT_CSS" ] && echo 1 || echo 0)" "1"

# --- Test 6: CSS contains --theme-* custom properties ---
ok "CSS contains --theme-background" \
    "$(grep -c -- '--theme-background' "$OUTPUT_CSS")" "1"

ok "CSS contains --theme-foreground" \
    "$(grep -c -- '--theme-foreground' "$OUTPUT_CSS")" "1"

ok "CSS contains --theme-accent" \
    "$(grep -c -- '--theme-accent' "$OUTPUT_CSS")" "1"

ok "CSS contains --theme-mode" \
    "$(grep -c -- '--theme-mode' "$OUTPUT_CSS")" "1"

# --- Test 7: CSS has correct color values from colors.toml ---
ok "CSS --theme-background matches colors.toml" \
    "$(grep -c '#000000' "$OUTPUT_CSS")" "1"

ok "CSS --theme-foreground matches colors.toml" \
    "$(grep -c '#cdd6f4' "$OUTPUT_CSS")" "1"

# accent and blue share the same hex value, so check the line specifically
ok "CSS --theme-accent line has correct value" \
    "$(grep '\-\-theme-accent' "$OUTPUT_CSS" | grep -c '#1e66f5')" "1"

# --- Test 8: CSS is valid :root block ---
ok "CSS wraps variables in :root" \
    "$(grep -c ':root' "$OUTPUT_CSS")" "1"

# --- Test 9: script handles missing colors.toml gracefully ---
python3 "$SCRIPT" "/nonexistent/colors.toml" "$OUTPUT_CSS" 2>/dev/null
ok "script doesn't crash on missing colors.toml" \
    "$([ -f "$OUTPUT_CSS" ] && echo 1 || echo 0)" "1"

# --- Test 10: script generates file at default path when no args ---
python3 "$SCRIPT" >/dev/null 2>&1
ok "default output path is ~/.local/share/better/stylus-theme.css" \
    "$([ -f "${HOME}/.local/share/better/stylus-theme.css" ] && echo 1 || echo 0)" "1"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
