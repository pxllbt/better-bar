# Better Bar

A dynamic-island status bar for Hyprland on Wayland, built with Quickshell.

The idea: keep your screen clean until you need something. A small capsule sits at the top of each monitor. Hover or tap it and it smoothly morphs into whatever you need — media player, calendar, mixer, system monitor, wallpaper browser, launcher, or settings. When it's not open, it takes up zero space and nearly zero CPU.

There's also a floating dock at the bottom if you want one — pinned apps, running windows, the usual.

![Better Bar preview](preview.png)

## How it works

- **Morphing pill**: the top capsule grows in-place into each surface. No popping dialogs or separate windows floating around.
- **Event-driven**: uses Hyprland IPC events (`activewindow`, `openwindow`, etc.) instead of polling. The audio visualizer (Cava) only runs while music is playing.
- **27+ themes**: there's a built-in theme browser — pick a theme and it applies across Hyprland, the bar, and your terminal.

## Surfaces

Launcher, media player, audio mixer, wallpaper browser, calendar, clipboard history, Wi-Fi, Bluetooth, battery, power controls, notifications, settings, and more. Each one morphs from the same pill.

There's also live detection of Hyprland's scratchpad — the pill turns into a little `[Scratchpad]` chip when something's there.

## Install

### Omarchy plugin (recommended)

```bash
omarchy plugin add https://github.com/pxllbt/better-bar.git --enable
```

Update later with `omarchy plugin update pix.bar`, or hit the Update button in the bar's settings.

### Standalone (Quickshell)

```bash
git clone https://github.com/pxllbt/better-bar.git ~/.local/share/quickshell/better
~/.local/share/quickshell/better/scripts/optimize-setup.sh
~/.local/share/quickshell/better/launch.sh
```

Then add to your `hyprland.conf`:

```conf
exec-once = ~/.local/share/quickshell/better/launch.sh
exec-once = awww-daemon
```

## Hotkeys

Wire these into your `hyprland.conf`:

```conf
bind = SUPER, slash,   exec, qs -p ~/.local/share/quickshell/better ipc call better launcher ""
bind = SUPER, SHIFT+W, exec, qs -p ~/.local/share/quickshell/better ipc call better wallpaper ""
bind = SUPER, SHIFT+V, exec, qs -p ~/.local/share/quickshell/better ipc call better clipboard ""
bind = SUPER, L,       exec, ~/.local/share/quickshell/better/scripts/lock.sh
```

Full list of IPC targets: `launcher`, `wallpaper`, `clipboard`, `mixer`, `calendar`, `media`, `power`, `battery`, `sysmon`, `link`, `theme`, `weather`, `wifi`, `bt`, `accent`, `glass`, `interface`, `fontpicker`, `plugins`, `update`, `appearance`, `display`, `fontcolor`, `appcat`.

## Tests

```bash
node lib/border-geometry.test.mjs
node lib/monitors.test.mjs
bash lib/media-pill.test.sh .
bash lib/strip-layout.test.sh .
bash lib/surfaces-wired.test.sh .
bash lib/theme-sync.test.sh .
```

## Credits

Built on [Quickshell](https://quickshell.outfoxxed.me) by outfoxxed. Pill/morphing concepts borrowed from [Ukishima](https://github.com/amanhex/Ukishima) and [Ricelin](https://github.com/Gakuseei/Ricelin). Full license details in [NOTICE.md](NOTICE.md).

MIT licensed. By [pxllbt](https://github.com/pxllbt).