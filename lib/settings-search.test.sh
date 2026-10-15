#!/usr/bin/env bash
# Asserts the settings search catalog stays wired to real destinations.
#
# The bug this guards: a search result can look right and still be dead, because
# it points at a surface with no setter, a route with no loader, or an external
# command that does not exist. This checks the destination kinds the surface
# understands, and that known problem areas resolve.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CATALOG="$ROOT/lib/settings-search.js"
SURFACE="$ROOT/surfaces/Appearance.qml"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}

[ -f "$CATALOG" ] || { echo "no lib/settings-search.js" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP settings-search: node is unavailable\n'
    exit 0
fi

OUT=$(node - "$CATALOG" <<'JS'
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library\s*/, "");
const ctx = {};
vm.createContext(ctx);
vm.runInContext(src, ctx);

const out = [];
out.push("entries:" + ctx.search("").length);
out.push("keybind:" + (ctx.search("keybind")[0] ? ctx.search("keybind")[0].entry.to : ""));
out.push("lock:" + (ctx.search("lock").some((r) => r.entry.to === "lockstyle")));
out.push("plymouth:" + (ctx.search("plymouth").some((r) => r.entry.to === "plymouth")));
out.push("hide:" + (ctx.search("hide").length > 0));
console.log(out.join("\n"));
JS
)

# The count assertion is a minimum, not a fixed number: a new setting adds an
# entry, which should not fail the test.
if [ "$(printf '%s' "$OUT" | sed -n 's/^entries://p')" -ge 30 ]; then
    ok "the catalog carries a usable settings index" "yes" "yes"
else
    ok "the catalog carries a usable settings index" "no" "yes"
fi

ok "keybindings search opens the native keybinds surface" \
    "$(printf '%s' "$OUT" | sed -n 's/^keybind://p')" "keybinds"

ok "lock search opens the lock style surface" \
    "$(printf '%s' "$OUT" | sed -n 's/^lock://p')" "true"

ok "plymouth search opens the Plymouth surface" \
    "$(printf '%s' "$OUT" | sed -n 's/^plymouth://p')" "true"

ok "hide search returns real settings" \
    "$(printf '%s' "$OUT" | sed -n 's/^hide://p')" "true"

ok "the search surface can invoke a plugin destination" \
    "$(grep -c 'Plugins.openOrEnable(entry.plugin)' "$SURFACE")" "1"

printf '\n'
if [ "$failed" -gt 0 ]; then
    printf '%s failing\n' "$failed"
    exit 1
fi
printf 'all green\n'
