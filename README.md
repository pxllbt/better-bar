# Better Bar

> A dynamic-island status bar for Hyprland, built on Quickshell.

Better Bar is a widget layer for Hyprland built around a morphing pill at the top of every monitor that expands in place into a control centre, plus a floating dock at the bottom edge for pinned and running apps. It runs as its own Quickshell process and replaces the stock Omarchy bar — it makes no changes to your existing Hyprland config.

## Preview

<p align="center">
  <img src="preview/2026-10-05_00-10.png" width="49%" alt="Better Bar preview 1" />
  <img src="preview/2026-10-05_00-11_1.png" width="49%" alt="Better Bar preview 2" />
</p>

<p align="center">
  <img src="preview/2026-10-05_00-11.png" width="32%" alt="Better Bar preview 3" />
  <img src="preview/2026-10-05_00-12.png" width="32%" alt="Better Bar preview 4" />
  <img src="preview/2026-10-05_00-12_1.png" width="32%" alt="Better Bar preview 5" />
</p>

## Features

- **Dynamic island** — one morphing pill per monitor; every module grows its own surface out of it, in place.
- **Dock** — pinned and running apps with hover magnification and multi-window previews (no cursor warp), auto-hide, and its own theme (Light / Dark / Dynamic / Manual) and glass.
- **Surfaces** — launcher, weather, calendar, media, mixer, wallpaper strip + wallhaven search, clipboard, wifi, bluetooth, battery, power menu, system monitor, notifications, OSD, toasts, settings.
- **Wallpapers** — shuffled `awww` bag, live `mpvpaper` videos, per-wallpaper fit, and a palette that retints the UI.
- **Extras** — night light, game mode, keep-awake, in-app updater.

## Requirements

- Linux + Wayland, **Hyprland** (recent 0.4x/0.5x)
- **Quickshell** 0.3.0+ (Hyprland, Wayland and Io modules)
- **Omarchy** — Better Bar replaces its bar and speaks its plugin IPC
- CLI tools — the installer checks them; see [DEPENDENCIES](DEPENDENCIES.md)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/pxllbt/better-bar/master/remote-install.sh | bash
```

Clones to `~/.local/share/quickshell/better-bar`, checks dependencies, hides the stock Omarchy bar (`omarchy toggle bar off` — undo with `omarchy toggle bar on`), and prints the keybinds and auto-launch line to add. Update it the same way — or from the **Update** surface inside the settings — whenever you want the latest.

## Use

- **Launch / auto-launch** through **`launch.sh`** — it adds jemalloc decay settings so memory stays near the live working set instead of the session peak (~250 MB RSS):

  ```conf
  exec-once = ~/.local/share/quickshell/better-bar/launch.sh
  ```

  (Lua: `hl.exec_cmd("~/.local/share/quickshell/better-bar/launch.sh")`)

- **Wallpaper daemon** — `exec-once = awww-daemon` beside the launch line, so the wallpaper is painted without waiting on the daemon to come up.

- **Keybinds** — every surface answers over quickshell IPC (target `better`; empty monitor arg = focused):

  ```conf
  bind = SUPER, SHIFT+W, exec, qs -p ~/.local/share/quickshell/better-bar ipc call better wallpaper ""
  bind = SUPER, SHIFT+V, exec, qs -p ~/.local/share/quickshell/better-bar ipc call better clipboard ""
  bind = SUPER, slash,   exec, qs -p ~/.local/share/quickshell/better-bar ipc call better launcher ""
  ```

  ```lua
  hl.bind(var_mainMod .. " + SHIFT + W", hl.dsp.exec_cmd("qs -p ~/.local/share/quickshell/better-bar ipc call better wallpaper \"\""))
  hl.bind(var_mainMod .. " + SHIFT + V", hl.dsp.exec_cmd("qs -p ~/.local/share/quickshell/better-bar ipc call better clipboard \"\""))
  hl.bind(var_mainMod .. " + slash",     hl.dsp.exec_cmd("qs -p ~/.local/share/quickshell/better-bar ipc call better launcher \"\""))
  ```

  Other handlers: mixer, calendar, media, power, battery, sysmon, gameMode, peek, hide, page …

- **Lock** is a script rather than an IPC surface, so it gets its own bind:

  ```conf
  bind = SUPER, L, exec, ~/.local/share/quickshell/better-bar/scripts/lock.sh
  ```

  ```lua
  hl.bind(var_mainMod .. " + L", hl.dsp.exec_cmd("/home/username/.local/share/quickshell/better-bar/scripts/lock.sh"))
  ```

  It runs `hyprlock`, configured by your own `hyprlock.conf` — Better Bar ships none and generates none, so the lock looks exactly like it does everywhere else on your desktop.

## Plugins

No other plugins are required: the bar ships its own surfaces for everything the stock Omarchy plugins do. Omarchy plugins still work — any stock `bar-widget` shows up in the pill's strip as-is.

Where a plugin does a job the bar already does, one of them has to be the default. The order is: **a plugin you picked for the job, then the bar's own surface, then the stock plugin** (the stock one is suppressed for the jobs the bar covers, so nothing shows twice). Pick the plugin from the plugins list in settings and it becomes the default; uninstall it — or switch back — and the bar's own surface returns.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/pxllbt/better-bar/master/uninstall.sh | bash
```

Removes program files, all state and caches (`~/.local/state/better*`, `~/.cache/better`), restores the stock Omarchy bar, and stops any running instance. Then drop the auto-launch line, keybinds and packages you added.

## Credits

Built on top of [**Ricelin**](https://github.com/Gakuseei/Ricelin) by [**Gakuseei**](https://github.com/Gakuseei) — the pill concept, the morphing-surface architecture and most of the original codebase. All credit for the base code goes to the original author. See [NOTICE.md](NOTICE.md) for the full lineage and licenses.
