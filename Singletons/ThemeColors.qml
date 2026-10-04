import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Omarchy's active theme palette, parsed out of the active theme's colors.toml.
 *
 * This component used to own the reading. It does not any more: `ThemeSync` owns
 * the single watch on `theme.name` and the single process that reads colors.toml
 * *and* resolves the wallpaper, so the palette and the background behind the pill
 * change in the same tick instead of a moment apart. What is left here is the
 * part that is genuinely about colours: the TOML-ish parse and the active-border
 * maths.
 *
 * Consuming rather than reading also means this file no longer needs to know
 * *how* Omarchy swaps a theme — that detail lives in exactly one place now.
 */
pragma Singleton

Item {
    id: root

    /** key -> "#rrggbb", or {} before the first read lands. */
    property var palette: ({})

    /**
     * The theme's active-window border as colour stops, so Better Bar can draw the
     * same edge. omarchy encodes it as "rgba(..) rgba(..) ... 90deg"; a theme
     * with a single stop is still honoured (one flat edge).
     */
    property var activeBorder: []
    /** Writable: adopt() updates it from the theme's angle, so not readonly. */
    property real activeBorderAngle: 90

    function parse(text) {
        var out = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            if (!line || line.charAt(0) === "#")
                continue
            var eq = line.indexOf("=")
            if (eq === -1)
                continue
            var key = line.slice(0, eq).trim()
            var value = line.slice(eq + 1).trim()
            if (value.length >= 2 && value.charAt(0) === '"' && value.charAt(value.length - 1) === '"')
                value = value.slice(1, -1)
            if (key)
                out[key] = value
        }
        return out
    }

    /**
     * Parses omarchy's active-border encoding: "rgba(rrggbbaa) ..." with
     * an optional trailing angle. Handles both the single 8-digit hex
     * form omarchy uses and the classic comma-separated form for
     * compatibility.
     */
    function parseBorder(value) {
        var out = []
        var re = /rgba?\(([^)]*)\)/g
        var match
        // Hyprland writes colours as rrggbbaa; Qt's color type is #AARRGGBB.
        // Handing QML an rrggbbaa string silently reinterprets the channels —
        // ff8800ff became #8800ff (a violet ring) and 0055aaff became #55aaff
        // at alpha 0, i.e. an invisible bottom edge. Always reorder here.
        function pair(s) {
            s = (s === undefined || s === null) ? "" : String(s).trim()
            if (s.length === 0)
                return "00"
            return s.length === 1 ? s + s : s.slice(0, 2)
        }
        // The comma form is decimal 0..255, not hex: rgba(255,136,0,1.0).
        function byte(s) {
            s = (s === undefined || s === null) ? "" : String(s).trim()
            if (s.length === 0)
                return "00"
            if (/^\d+$/.test(s))
                return Math.max(0, Math.min(255, parseInt(s, 10))).toString(16).padStart(2, "0")
            return pair(s)
        }
        // Alpha may be hex (ff) or a 0..1 float (1.0), depending on the theme.
        function alphaOf(s) {
            s = (s === undefined || s === null) ? "" : String(s).trim()
            if (s.length === 0)
                return "ff"
            if (/^0?\.\d+$|^1(\.0+)?$/.test(s)) {
                var f = parseFloat(s)
                if (isNaN(f))
                    return "ff"
                return pair(Math.round(Math.max(0, Math.min(1, f)) * 255)
                    .toString(16).padStart(2, "0"))
            }
            return pair(s)
        }
        while ((match = re.exec(String(value || ""))) !== null) {
            var raw = match[1].trim()
            var parts = raw.split(",")
            var hex
            if (parts.length === 1 && /^[0-9a-fA-F]{8}$/.test(parts[0].trim())) {
                var h = parts[0].trim()
                hex = "#" + h.slice(6, 8) + h.slice(0, 6)
            } else {
                hex = "#" + alphaOf(parts[3]) + byte(parts[0]) + byte(parts[1]) + byte(parts[2])
            }
            out.push(hex)
        }
        return out
    }

    function adopt(text) {
        ThemeColors.palette = ThemeColors.parse(text)
        var border = ThemeColors.palette["hyprland_active_border"]
        if (border) {
            ThemeColors.activeBorder = ThemeColors.parseBorder(border)
            var angle = /(-?[0-9.]+)deg/.exec(String(border))
            if (angle)
                ThemeColors.activeBorderAngle = Number(angle[1])
            return
        }
        ThemeColors.deriveBorder()
    }

    /**
     * Border stops for themes that do not name any.
     *
     * Only 3 of the 22 shipped themes set `hyprland_active_border`; the rest leave
     * Hyprland to its own default while the pill ring — which only draws when
     * there are stops — went dark. So a theme switch moved the window borders and
     * left the pill's alone, which is the mismatch this removes.
     *
     * The fallback is built from the theme's own accent, because that is the
     * colour Omarchy themes the rest of the desktop with, so the pill agrees with
     * the themed part of the shell even where the windows do not. Two stops, so
     * the ring keeps its gradient, at the default 90deg — which is also what
     * Hyprland falls back to.
     *
     * An accent that is empty or not a hex colour leaves the stops empty and the
     * ring dark, which is the honest answer: there is nothing to draw.
     */
    function deriveBorder() {
        var accent = String(ThemeColors.palette["accent"] || "").trim()
        if (!/^#?[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(accent))
            return;
        if (accent.charAt(0) !== "#")
            accent = "#" + accent;
        var rgb = accent.substring(1, 7).toLowerCase();
        ThemeColors.activeBorder = ["#ff" + rgb, "#ff" + rgb];
        ThemeColors.activeBorderAngle = 90;
    }

    /**
     * The palette now comes from ThemeSync, which owns the one watch and the one
     * read for both the colours and the wallpaper. This component is left with
     * the parsing and the border maths, which are genuinely its own.
     */
    Connections {
        target: ThemeSync
        function onRevisionChanged() { root.readPalette(); }
    }

    function readPalette() {
        var text_ = String(ThemeSync.paletteText || "").trim();
        if (text_)
            root.adopt(text_);
    }

    Component.onCompleted: root.readPalette()
}
