#!/usr/bin/env python3
import os
import glob
import json

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
            if os.path.exists(colors_file):
                try:
                    with open(colors_file, "r", encoding="utf-8", errors="ignore") as f:
                        for line in f:
                            line = line.strip()
                            if "=" in line and not line.startswith("#"):
                                k, v = line.split("=", 1)
                                colors[k.strip()] = v.strip().strip('"').strip("'")
                except Exception:
                    pass

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

            themes[key] = {
                "id": d,
                "name": name,
                "bg": colors.get("background", "#1e1e2e"),
                "accent": colors.get("accent", "#89b4fa"),
                "fg": colors.get("foreground", "#cdd6f4"),
                "mode": colors.get("mode", "dark"),
                "preview": preview,
                "palette": [
                    colors.get("accent", "#89b4fa"),
                    colors.get("red", "#f38ba8"),
                    colors.get("green", "#a6e3a1"),
                    colors.get("yellow", "#f9e2af"),
                    colors.get("blue", "#89b4fa"),
                    colors.get("magenta", "#cba6f7"),
                ]
            }

    return sorted(themes.values(), key=lambda t: t["name"])

if __name__ == "__main__":
    print(json.dumps(get_themes()))
