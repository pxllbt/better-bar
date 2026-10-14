#!/usr/bin/env python3
import os
import glob
import json
import re
import shutil
import subprocess
import tempfile

# A colour we are willing to hand to QML.
#
# This check is the point of the module. The tile fills with `bg` and prints its
# title in `fg`, so a value that is not a colour does not degrade -- QML reads an
# unparseable colour string as opaque black, and the tile becomes a black
# rectangle with an invisible title and an invisible palette ribbon. A dead tile
# that looks like a rendering bug in the surface, when the cause is a parse
# failure here.
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")

FALLBACK = {
    "bg": "#1e1e2e",
    "accent": "#89b4fa",
    "fg": "#cdd6f4",
}


def strip_comment(value):
    """Cut a TOML value at its comment, honouring quotes.

    A `#` only starts a comment outside a quoted string, and that detail is the
    whole job: every colour here is itself `#rrggbb`, so cutting at the first
    `#` would leave an empty string instead of trimming the comment.

    Without this, `background = "#141412"  # night` parsed as
    `#141412"  # night`. Stock omarchy themes are machine-generated and carry no
    inline comments, so their values ended at the closing quote by luck; a
    hand-written theme annotates every line and so was the one that broke.
    """
    in_string = False
    for i, ch in enumerate(value):
        if ch == '"' or ch == "'":
            in_string = not in_string
        elif ch == "#" and not in_string:
            return value[:i].strip()
    return value.strip()


def color_of(colors, key):
    """A validated #rrggbb for `key`, or the neutral fallback."""
    value = colors.get(key, "")
    if isinstance(value, str) and HEX_RE.match(value.strip()):
        return value.strip()
    return FALLBACK.get(key, FALLBACK["accent"])


def mode_of(colors):
    """dark or light, never anything else.

    `mode` is a name rather than a colour, so it needs its own check: a theme
    that omits it, or spells it some other way, used to pass the raw string
    through to the surface and leave the tile deciding its own contrast.
    """
    value = str(colors.get("mode", "")).strip().strip('"').strip("'").lower()
    return value if value in ("dark", "light") else "dark"


def read_colors(colors_file):
    """Parse a colors.toml, or {} when there is none."""
    colors = {}
    if not colors_file or not os.path.exists(colors_file):
        return colors
    try:
        with open(colors_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    v = strip_comment(v)
                    colors[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    return colors


def derive_colors(theme_dir):
    """Ask omarchy to generate a colors.toml from the theme's alacritty.toml.

    Delegating matters: omarchy owns the mapping from its own palette keys to
    the shell's colour names, so re-deriving it here would drift the moment
    omarchy changed, and the gallery would then disagree with the colours the
    desktop actually gets when that theme is applied.

    Worked on a copy. The generator writes colors.toml INTO the directory it is
    given, and a gallery build must not modify the user's themes -- that would
    make a read of the picker mutate what the picker is showing.
    """
    alacritty = os.path.join(theme_dir, "alacritty.toml")
    if not os.path.exists(alacritty):
        return None
    if not (shutil.which("omarchy-theme-colors-from-alacritty") or
            os.path.exists("/usr/bin/omarchy-theme-colors-from-alacritty")):
        return None
    scratch = tempfile.mkdtemp(prefix="better-theme-colors-")
    try:
        for entry in os.listdir(theme_dir):
            src = os.path.join(theme_dir, entry)
            dst = os.path.join(scratch, entry)
            try:
                if os.path.isdir(src):
                    shutil.copytree(src, dst, symlinks=True)
                else:
                    shutil.copy2(src, dst)
            except Exception:
                continue
        out = os.path.join(scratch, "colors.toml")
        try:
            subprocess.run(
                ["bash", "/usr/bin/omarchy-theme-colors-from-alacritty", scratch],
                capture_output=True, timeout=10,
            )
        except Exception:
            return None
        if not os.path.exists(out):
            return None
        # Read the derived colours HERE, while the scratch copy still exists.
        # Returning the path and cleaning up in a finally deleted it before the
        # caller could open it, so the derivation silently produced nothing --
        # and the tile went back to the flat fallback that started this.
        return read_colors(out)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def get_themes():
    themes = {}
    paths = [
        os.path.expanduser("~/.config/omarchy/themes"),
        "/usr/share/omarchy/themes"
    ]

    for base in paths:
        if not os.path.exists(base):
            continue
        for d in sorted(os.listdir(base)):
            full = os.path.join(base, d)
            if not os.path.isdir(full) or d.startswith("."):
                continue
            key = d.lower().replace("-", " ").replace("_", " ")
            if key in themes:
                continue

            colors = {}
            colors_file = os.path.join(full, "colors.toml")

            # A theme can ship without a colors.toml and still be perfectly
            # valid: omarchy generates one from the theme's alacritty.toml at
            # install time, so the desktop gets real colours and the source
            # directory has none. Reading only colors.toml left such a theme
            # with an empty palette, and every field fell back to the SAME
            # neutral default -- so its tile filled with that default and drew
            # its title in that default too, which is an invisible title on a
            # flat block. It looked like a rendering bug in the surface.
            #
            # Derive it the same way omarchy does, into a scratch copy so the
            # user's checkout is never written to by a read-only gallery build.
            if not os.path.exists(colors_file):
                colors = derive_colors(full) or read_colors(None)
            else:
                colors = read_colors(colors_file)

            name = " ".join(word.capitalize() for word in d.replace("-", " ").replace("_", " ").split())

            preview = ""
            for p in ["preview.png", "preview-unlock.png"]:
                cand = os.path.join(full, p)
                if os.path.exists(cand):
                    preview = cand
                    break
            if not preview:
                bgs = glob.glob(os.path.join(full, "backgrounds", "*"))
                if bgs:
                    preview = bgs[0]

            accent = color_of(colors, "accent")
            themes[key] = {
                "id": d,
                "name": name,
                "bg": color_of(colors, "background"),
                "accent": accent,
                "fg": color_of(colors, "foreground"),
                "mode": mode_of(colors),
                "preview": preview,
                "palette": [
                    accent,
                    color_of(colors, "red"),
                    color_of(colors, "green"),
                    color_of(colors, "yellow"),
                    color_of(colors, "blue"),
                    color_of(colors, "magenta"),
                ]
            }

    return sorted(themes.values(), key=lambda t: t["name"])

if __name__ == "__main__":
    print(json.dumps(get_themes()))
