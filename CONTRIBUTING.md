# Contributing to Better Bar

Thanks for wanting to help out. Whether you're fixing a bug, designing a new surface, or squeezing out more performance, contributions are welcome.

## Setup

You'll need:
- Linux on Wayland with Hyprland
- Quickshell 0.3.0+
- Node.js 20+ (for tests)
- Python 3.10+ (for theme/palette scripts)

```bash
git clone https://github.com/pxllbt/better-bar.git
cd better-bar
quickshell --config .
```

## Things to keep in mind

1. **Idle CPU matters.** Better Bar is built to rest near 0% when you're not interacting with it. Don't add polling timers under 1 second, don't run infinite animations on resting elements, don't repaint canvases in the background. Use Hyprland IPC events or `FileView` instead.
2. **Follow the structure.** `Singletons/` for state, `components/` for reusable widgets, `surfaces/` for expanded cards. Keep it consistent.

## Tests

```bash
node lib/border-geometry.test.mjs
node lib/monitors.test.mjs
bash lib/media-pill.test.sh .
bash lib/strip-layout.test.sh .
bash lib/surfaces-wired.test.sh .
bash lib/theme-sync.test.sh .
```

All green before merging, please.

## PRs

- Clear, imperative commit messages (e.g. `Fix corner spandrels in ActiveBorderRing`)
- Check `top`/`ps aux` for idle CPU before submitting
- One thing per PR — don't bundle unrelated changes