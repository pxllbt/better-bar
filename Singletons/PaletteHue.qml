pragma Singleton
import QtQuick
import Quickshell

/**
 * Manual-palette hue math — the exact wallcolors.py `--hue` computation,
 * rendered locally in QML so a manual palette never has to touch the shared
 * `colors.json` file. The wallpaper palette (`Dyn`) stays the source for
 * dynamic modes on both the pill and the dock; a manual hue is a per-side
 * overlay computed here from that side's own hue flags. Dragging any theme
 * slider therefore recolours only the side that owns it — no shared-file
 * rewrite, no cross-side coupling.
 *
 * `build(hueDeg, sat, dark)` mirrors `tint()`/`lerp()` and the DARK/LIGHT
 * step tables in wallcolors.py and returns the same keys Dyn exposes
 * (surface ramp, primary pair, outline, text tiers), so consumers swap a
 * `Dyn.x` branch for a `PaletteHue.build(...).x` branch with the same shape.
 */
Singleton {
    id: root

    function tintHex(h, s, l) {
        var c = Qt.hsla(h, s, l, 1);
        function hx(x) { return ("0" + Math.round(x * 255).toString(16)).slice(-2); }
        return "#" + hx(c.r) + hx(c.g) + hx(c.b);
    }

    function lerp(x, x0, x1, y0, y1) {
        var t = Math.max(0, Math.min(1, (x - x0) / (x1 - x0)));
        return y0 + t * (y1 - y0);
    }

    function build(hueDeg, sat, dark) {
        var hue = (((Math.round(hueDeg) % 360) + 360) % 360) / 360;
        sat = Math.max(0, Math.min(1, sat));
        var light = !dark;
        var ch = sat > 0.02;
        var ml = light ? 0.85 : 0.12;
        var ss = light ? Math.min(sat, 0.26)
            : Math.min(Math.max(sat, ch ? 0.30 : 0.0), 0.45);
        var as = ch ? (light ? Math.min(sat + 0.18, 0.85)
            : Math.min(Math.max(sat, 0.30) + 0.12, 0.82)) : 0.05;
        var base = light ? lerp(ml, 0.40, 0.66, 0.80, 0.93)
            : lerp(ml, 0.0, 0.40, 0.045, 0.20);
        var st = light ? [0.0, -0.045, -0.075, -0.115, -0.160, -0.340]
            : [0.0, 0.022, 0.038, 0.065, 0.100, 0.225];
        function T(s2, l2) { return root.tintHex(hue, s2, l2); }
        return {
            surface: T(ss, base + st[0]),
            surface_container_low: T(ss, base + st[1]),
            surface_container: T(ss, base + st[2]),
            surface_container_high: T(ss, base + st[3]),
            surface_container_highest: T(ss, base + st[4]),
            outline_variant: T(ss, base + st[5]),
            primary: T(as, light ? 0.42 : 0.70),
            primary_container: T(Math.min(as + 0.08, 0.9), light ? 0.30 : 0.34),
            on_primary_container: T(Math.min(as, 0.45), light ? 0.55 : 0.86),
            outline: T(ss, base + (light ? -0.35 : 0.35)),
            cream: T(light ? 0.18 : 0.05, light ? 0.20 : 0.90),
            bright: T(light ? 0.20 : 0.03, light ? 0.10 : 0.97),
            subtle: T(light ? 0.14 : 0.07, light ? 0.36 : 0.73),
            dim: T(light ? 0.10 : 0.06, light ? 0.48 : 0.54),
            faint: T(light ? 0.08 : 0.05, light ? 0.56 : 0.44),
            icon_dim: T(light ? 0.12 : 0.07, light ? 0.28 : 0.81),
            tick_rest: T(light ? 0.12 : 0.08, light ? 0.34 : 0.75)
        };
    }
}