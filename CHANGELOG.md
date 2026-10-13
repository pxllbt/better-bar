# Changelog

All notable changes documented below. Loosely follows [Keep a Changelog](https://keepachangelog.com/), SemVer for versions.

## Unreleased

### Added
- 0.0% idle CPU architecture — Cava FFT gated to active playback, canvas repaints paused while resting, dock polling replaced with Hyprland IPC events
- 27-theme visual gallery in `ThemeSurface` with live color ribbons and search
- Wallpaper x theme harmony swatches in the Accent surface
- Dynamic scratchpad indicator via `activespecial` detection
- `scripts/optimize-setup.sh` integrated into `remote-install.sh`

### Fixed
- Corner spandrel artifacts — replaced rectangular border strips with `Shape.CurveRenderer` vector paths
- Theme sync delay reduced from 400ms to 50ms with optimistic UI updates
- Media CD artwork cropping improved, outer rim softened, center spindle cleaned up

### Removed
- Redundant clipboard button from media card
- Old screenshots in favor of clean hero banner