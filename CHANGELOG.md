# Changelog

All notable changes documented below. Loosely follows [Keep a Changelog](https://keepachangelog.com/), SemVer for versions.

## Unreleased

### Added
- 0.0% idle CPU architecture — Cava FFT gated to active playback, canvas repaints paused while resting, dock polling replaced with Hyprland IPC events
- 27-theme visual gallery in `ThemeSurface` with live color ribbons and search
- Wallpaper x theme harmony swatches in the Accent surface
- Dynamic scratchpad indicator via `activespecial` detection
- `scripts/optimize-setup.sh` runs as part of the standalone install path

### Fixed
- Corner spandrel artifacts — replaced rectangular border strips with `Shape.CurveRenderer` vector paths
- Theme sync delay reduced from 400ms to 50ms with optimistic UI updates
- Media CD artwork cropping improved, outer rim softened, center spindle cleaned up

### Removed
- `remote-install.sh` — the piped bootstrap installer is gone. Standalone installs are now
  an explicit `git clone` plus `scripts/optimize-setup.sh`, so nothing from a moving branch
  is fetched and executed before review
- Redundant clipboard button from media card
- Old screenshots in favor of clean hero banner