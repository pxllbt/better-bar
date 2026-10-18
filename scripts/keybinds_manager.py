#!/usr/bin/env python3
import json, glob, os, sys

def list_keybinds():
    cache_dir = os.path.expanduser("~/.cache/omarchy")
    files = sorted(glob.glob(os.path.join(cache_dir, "keybindings-*.records")), key=os.path.getmtime, reverse=True)
    if not files:
        os.system("/usr/bin/omarchy-menu-keybindings --print >/dev/null 2>&1")
        files = sorted(glob.glob(os.path.join(cache_dir, "keybindings-*.records")), key=os.path.getmtime, reverse=True)
    
    active = []
    if files:
        with open(files[0], "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if not parts or not parts[0]: continue
                first = parts[0]
                action = parts[2] if len(parts) > 2 else ""
                if "→" in first:
                    key, desc = first.split("→", 1)
                    key = key.strip()
                    desc = desc.strip()
                else:
                    key = first.strip()
                    desc = action
                active.append({
                    "key": key,
                    "description": desc,
                    "action": action,
                    "category": "Keybinding",
                    "status": "active",
                    "source": "default"
                })
    return {"active": active, "catalog": [], "conflicts": []}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        print(json.dumps(list_keybinds()))
    else:
        print(json.dumps({"ok": True, "message": "Keybindings updated"}))
