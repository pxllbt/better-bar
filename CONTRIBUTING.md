# Contributing to Better Bar

Thank you for your interest in improving Better Bar! Whether you're fixing a bug, designing a new surface, or optimizing performance, contributions are welcome.

---

## 🛠️ Development Setup

### Prerequisites
- **Linux on Wayland** with **Hyprland**
- **Quickshell** `0.3.0+`
- **Node.js** `20+` (for unit tests)
- **Python** `3.10+` (for theme & palette scripts)

### Running from Source
Clone the repository and launch directly with Quickshell:

```bash
git clone https://github.com/pxllbt/better-bar.git
cd better-bar
quickshell --config .
```

---

## ⚡ Core Principles

1. **Zero Idle CPU**:
   Better Bar strictly maintains **0.0% CPU at idle**.
   - Never introduce polling timers with short intervals (`interval < 1000ms`).
   - Rely strictly on Hyprland IPC events (`Hyprland.rawEvent`) or inotify (`FileView`).
   - Never run unbounded animations (`loops: Animation.Infinite`) or software canvas repaints (`canvas.requestPaint()`) on resting elements.

2. **Convention & Aesthetics**:
   - Follow existing QML architecture (`Singletons/` for state, `components/` for reusable widgets, `surfaces/` for expanded cards).
   - Preserve theme and wallpaper reactivity across light, dark, and dynamic modes.

---

## 🧪 Running Tests

Always run the full test suite before submitting a pull request:

```bash
# Run unit and integration tests
node lib/border-geometry.test.mjs
node lib/monitors.test.mjs
bash lib/media-pill.test.sh .
bash lib/strip-layout.test.sh .
bash lib/surfaces-wired.test.sh .
bash lib/theme-sync.test.sh .
```

All suites must report green before merging.

---

## 📝 Pull Request Guidelines

1. **Clear Commit Messages**: Use concise, imperative commit messages (e.g. `Fix corner spandrels in ActiveBorderRing`, `Add scratchpad indicator to strip face`).
2. **Performance Validation**: Inspect `top` or `ps aux` to ensure idle CPU remains at ~0.0%.
3. **Keep PRs Focused**: Avoid bundling unrelated refactorings or aesthetic tweaks into a single PR.
