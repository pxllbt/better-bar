# Changelog

All notable changes documented below. Loosely follows [Keep a Changelog](https://keepachangelog.com/), SemVer for versions.

## Unreleased

### Added
- `scripts/better-doctor.sh` v2 — the diagnostic engine now checks the source tree as well as the live session: qmldir registration drift, the surface registry, the settings-search targets, flags that have no Singleton alias, script syntax, the QML integrity gate, the install layout, and the project's own test suite. Reports are emitted in a fixed order, the JSON is properly escaped, and `--static` runs the source-tree checks alone (this is what CI runs).
- `lib/qml-audit.py --check` — compares the audit against the reviewed baseline and exits non-zero only on findings nobody has signed off on. The baseline is read from `lib/qml-audit.test.sh`, so the gate and the test cannot drift apart.
- `better doctor` — the diagnostic engine is reachable from the terminal through the existing `~/.local/bin/better` helper.
- 0.0% idle CPU architecture — Cava FFT gated to active playback, canvas repaints paused while resting, dock polling replaced with Hyprland IPC events
- 27-theme visual gallery in `ThemeSurface` with live color ribbons and search
- Wallpaper x theme harmony swatches in the Accent surface
- Dynamic scratchpad indicator via `activespecial` detection
- `scripts/optimize-setup.sh` runs as part of the standalone install path

### Fixed
- The media card's transport controls rendered BELOW the card's bottom edge — the card was sized to 132·s while its content needed 166·s, so the play/pause row hung outside the rounded rectangle
- The media bud could not be kept on screen with no player: `Flags.mediaAlways` was consulted only after `Players.has` had already ruled the media out, so the flag could not deliver what its own label promised
- `Flags.glassFollowHypr` had no Singleton-level alias, so it read as `undefined` in QML — the "Match Hyprland" toggle rendered, animated, and silently discarded the write
- `Singletons/Stylus.qml` was never declared in `Singletons/qmldir`, so `Stylus.sync()` was an unresolved identifier whenever the theme reloaded
- `screens.sh` tried the Lua transport before `hyprctl --batch`, so the batched monitor specs were never sent
- `screens.sh` shifted every field after an empty one (tab is an IFS-whitespace character), interpolated unescaped values into a Lua literal, and rewrote the user's `monitors.lua` on every apply
- The Omarchy menu extension file had unescaped quotes, so the whole file was discarded at parse time and every user override in it was inert
- The settings search offered surfaces that no longer existed
- Corner spandrel artifacts — replaced rectangular border strips with `Shape.CurveRenderer` vector paths
- Theme sync delay reduced from 400ms to 50ms with optimistic UI updates
- Media CD artwork cropping improved, outer rim softened, center spindle cleaned up

### Removed
- `remote-install.sh` — the piped bootstrap installer is gone. Standalone installs are now
  an explicit `git clone` plus `scripts/optimize-setup.sh`, so nothing from a moving branch
  is fetched and executed before review
- Redundant clipboard button from media card
- Old screenshots in favor of clean hero banner