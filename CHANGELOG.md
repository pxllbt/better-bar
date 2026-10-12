# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **0.0% Idle CPU Performance**: Engineered complete dormancy at rest by gating Cava audio FFT to active playback, pausing Ame canvas repaints while resting, and replacing 120ms dock polling with instant Hyprland IPC events.
- **27-Theme Visual Gallery**: Built an in-bar system theme browser in `ThemeSurface` with live color ribbons, search filtering, and one-tap instant switching.
- **Adaptive Wallpaper × Theme Harmony**: Added five harmonic swatches to the Accent surface that blend desktop wallpaper tones with the active theme in real time.
- **Dynamic Scratchpad Indicator**: Added live Hyprland `activespecial` detection that morphs the resting pill into a clean `[ 🔖 Scratchpad • ]` chip.
- **Automated Setup & Optimization**: Added `scripts/optimize-setup.sh` and integrated it into `remote-install.sh` for one-command low-CPU setup and Omarchy hook installation.
- **Continuous Integration**: Added GitHub Actions CI workflows for automated pull request validation and unit test suites.

### Fixed
- **Corner Spandrel Artifacts**: Replaced overlapping straight rectangular border strips in `ActiveBorderRing` with a true `Shape.CurveRenderer` vector path that cleanly traces rounded silhouettes on both the bar and dock.
- **Theme Sync Delay**: Reduced theme-sync settlement delay from 400ms to 50ms and added optimistic UI updates for instant theme switching.
- **Media CD Artwork Clarity**: Adjusted image cropping to `PreserveAspectCrop`, softened outer-rim grooves, and cleaned up the center spindle hub so album covers remain sharp, vibrant, and unobstructed.

### Removed
- Removed the redundant copy/clipboard button from the media card.
- Removed legacy cluttered screenshots from documentation in favor of a clean, dedicated hero banner.
