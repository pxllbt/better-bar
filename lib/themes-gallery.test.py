#!/usr/bin/env python3
"""Asserts that themes.py emits a tile colour for every installed theme.

Why this exists: themes.py read colors.toml with a plain split on `=`, so a
value kept any trailing TOML comment -- `background = "#141412"  # night`
became `#141412"  # night`. Nothing checked the result was a colour, and QML
takes an unparseable colour string as opaque black. The theme tile filled with
`modelData.bg`, so a theme whose background failed to parse rendered as a
black rectangle with an invisible title and an invisible palette ribbon: a
dead tile that looks like a rendering bug in the surface rather than a parse
bug in the generator.

Stock omarchy themes are machine-generated and carry no inline comments, so
their values ended at the closing quote by luck. A hand-written theme
annotates every line, so it was the one that broke -- and the user who
installed it saw the tile go black and could not pick their own theme.

What it pins:

  * every colour the script emits is a bare #rrggbb, for EVERY installed theme
  * an inline comment never survives into a value
  * a missing or unparseable colour falls back rather than going black
  * `mode` is normalised, because it is a name and not a colour

It runs against the real theme directories on this machine, so it cannot pass
while a theme that is installed right now would render as a black tile.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
THEMES_PY = os.path.join(HERE, "..", "scripts", "themes.py")

failed = []


def check(ok, label, detail=""):
    if ok:
        print(f"PASS {label}")
    else:
        failed.append(label)
        print(f"FAIL {label}")
        if detail:
            print(f"       {detail}")


# Run the real script -- not a reimplementation of it.
out = subprocess.run(
    [sys.executable, THEMES_PY], capture_output=True, text=True
)
check(out.returncode == 0, "themes.py runs", out.stderr.strip()[:200])
if out.returncode != 0:
    sys.exit(1)

themes = json.loads(out.stdout)
check(len(themes) > 0, f"themes.py emits entries (got {len(themes)})")

import re

HEX = re.compile(r"^#[0-9a-fA-F]{6}$")

# 1. Every colour field on EVERY tile must be a bare hex, or QML paints black.
bad = []
for t in themes:
    for key in ("bg", "accent", "fg"):
        value = str(t.get(key, ""))
        if not HEX.match(value):
            bad.append(f'{t["name"]}.{key} = {value!r}')
    for i, entry in enumerate(t.get("palette") or []):
        if not HEX.match(str(entry)):
            bad.append(f'{t["name"]}.palette[{i}] = {entry!r}')
check(
    not bad,
    "every tile colour is a bare #rrggbb",
    "; ".join(bad[:6]) + (f" (+{len(bad) - 6} more)" if len(bad) > 6 else ""),
)

# 2. Specifically: no value may carry a leftover TOML comment or stray quote.
commented = [
    f'{t["name"]}.{k} = {t[k]!r}'
    for t in themes
    for k in ("bg", "accent", "fg")
    if "#" in str(t.get(k, ""))[1:] or '"' in str(t.get(k, ""))
]
check(
    not commented,
    "no tile colour carries a TOML comment or stray quote",
    "; ".join(commented[:6]),
)

# 3. mode is a name, and a theme that omits it must still get a usable one.
modes = {str(t.get("mode", "")) for t in themes}
check(
    modes <= {"dark", "light"},
    "mode is always dark or light",
    f"unexpected: {sorted(modes - {'dark', 'light'})}",
)

# 4. A tile must be distinguishable: bg must differ from fg, or the title text
#    is invisible on the fill even when both parse.
same = [
    t["name"]
    for t in themes
    if str(t.get("bg", "")).lower() == str(t.get("fg", "")).lower()
]
check(
    not same,
    "no tile has fg equal to its bg (title would be invisible)",
    ", ".join(same[:6]),
)

# 5. The parser itself must drop inline comments, checked directly so the
#    failure names the cause rather than only the symptom. The fixture is a
#    real THEME under a fake HOME -- themes.py only scans ~/.config/omarchy/themes
#    and /usr/share/omarchy/themes, so a bare temp dir would never be seen.
probe_dir = os.path.join(tempfile.mkdtemp(prefix="themes-gallery-"), "home")
theme = os.path.join(probe_dir, ".config", "omarchy", "themes", "commented")
os.makedirs(theme)
with open(os.path.join(theme, "colors.toml"), "w") as f:
    f.write(
        'mode = "dark"\n'
        'background = "#141412"  # night\n'
        'accent = "#83b755"  # glass\n'
        'foreground = "#d1cab5"  # bone\n'
        'red = "#ee9b57"  # neon\n'
    )
check(os.path.isdir(theme), "probe fixture built")

env = dict(os.environ)
env["HOME"] = probe_dir
r = subprocess.run(
    [sys.executable, THEMES_PY], capture_output=True, text=True, env=env
)
got = [t for t in json.loads(r.stdout) if t["id"] == "commented"]
if not got:
    check(False, "parser probe produced a tile", r.stdout[:200])
else:
    t = got[0]
    check(
        t["bg"] == "#141412",
        "parser strips an inline comment from background",
        f'got {t["bg"]!r}',
    )
    check(
        t["accent"] == "#83b755",
        "parser strips an inline comment from accent",
        f'got {t["accent"]!r}',
    )
    check(
        t["fg"] == "#d1cab5",
        "parser strips an inline comment from foreground",
        f'got {t["fg"]!r}',
    )
    check(
        t["palette"][1] == "#ee9b57",
        "parser strips an inline comment from a palette entry",
        f'got {t["palette"][1]!r}',
    )

if failed:
    print(f"\n{len(failed)} failing")
    sys.exit(1)
print("\nall green")
