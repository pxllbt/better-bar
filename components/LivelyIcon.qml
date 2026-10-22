pragma ComponentBehavior: Bound

import "../Singletons"
import QtQuick
import QtQuick.Shapes

/**
 * The bar's icons, in colour.
 *
 * The bar was drawn entirely in one flat, pale colour, so every cell in it
 * read as the same white shape in a different position: a row of little
 * labels with nothing behind them. That is a legend, not a bar.
 *
 * So the status cells are drawn in colour now, the way a phone's dynamic
 * island or a desktop's settings panel draws them: filled, rounded, two
 * tones deep, each one a little object rather than a sign for an object.
 * The artwork is baked into this file as vector paths, so the bar keeps its
 * promise of shipping no assets and no fonts -- it looks the same on every
 * machine, at every scale, in every theme.
 *
 * They are given a little life as well: when an icon's state changes it
 * gives a small bounce, so a new notification, a changed forecast or a new
 * track says so instead of silently swapping one glyph for another.
 *
 * The bounce is EVENT driven, never continuous. A bar that breathes on its
 * own is a bar that never stops animating, and this bar spends most of its
 * life asleep; the liveliness is paid for when something happens, not
 * every frame of every minute.
 *
 * Any name without artwork here keeps the original line glyph, so the row
 * is never half and half.
 */
Item {
    id: root

    /** The same names the vector glyph table uses. */
    property string name: ""
    /** Used by the line-glyph fallback. */
    property color color: Theme.iconDim
    /** Used by the line-glyph fallback. */
    property real stroke: 1.7
    /**
     * How alive the icon is right now: 0 is resting, 1 is a full bounce.
     * Bound to whatever changed -- unread notifications, a new track, a
     * changed forecast.
     */
    property real bump: 0

    /**
     * The artwork.
     *
     * Each entry is a list of layers, painted back to front. A layer is
     * either a filled shape (a round of colour) or a stroked one (a ray, a
     * wave, a slash). The paths are drawn in a 24x24 space and scaled to
     * whatever cell they land in, exactly like the line glyphs are.
     */
    readonly property var art: ({
        // --- weather ---
        "sun": {
            "layers": [
                { "d": "M12 1.6v2.8M12 19.6v2.8M1.6 12h2.8M19.6 12h2.8M4.6 4.6l2 2M17.4 17.4l2 2M19.4 4.6l-2 2M6.6 17.4l-2 2", "stroke": "#FFA726", "w": 1.9 },
                { "d": "M12 6.4a5.6 5.6 0 1 0 0 11.2a5.6 5.6 0 0 0 0-11.2z", "fill": "#FFC53D" },
                { "d": "M9.2 9.4a3.6 3.6 0 0 1 3.2-1.4", "stroke": "#FFE9A8", "w": 1.5 }
            ]
        },
        "moon": {
            "layers": [
                { "d": "M19.6 15.4A8.6 8.6 0 0 1 8.6 4.4 9 9 0 1 0 19.6 15.4z", "fill": "#C4B5FD" },
                { "d": "M18.2 2.6l.7 1.5 1.5.7-1.5.7-.7 1.5-.7-1.5-1.5-.7 1.5-.7z", "fill": "#FFD166" }
            ]
        },
        "cloud": {
            "layers": [
                { "d": "M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9z", "fill": "#F1F6FF" },
                { "d": "M6.4 16.6h11.2v1.5a2.6 2.6 0 0 1-2.6 2.6H9a2.6 2.6 0 0 1-2.6-2.6z", "fill": "#C3D8F2" }
            ]
        },
        "cloud-rain": {
            "layers": [
                { "d": "M16.4 15.4H8.6a6.2 6.2 0 1 1 5.94-7.94 4 4 0 0 1 1.86 7.94z", "fill": "#F1F6FF" },
                { "d": "M8.2 17.4c0 1 .8 1.8 1.8 1.8s1.8-.8 1.8-1.8c0-1.3-1.8-3.3-1.8-3.3s-1.8 2-1.8 3.3z", "fill": "#4FA8F5" },
                { "d": "M12 19.6c0 1 .8 1.8 1.8 1.8s1.8-.8 1.8-1.8c0-1.3-1.8-3.3-1.8-3.3s-1.8 2-1.8 3.3z", "fill": "#7FC4F8" },
                { "d": "M15.8 17.4c0 1 .8 1.8 1.8 1.8s1.8-.8 1.8-1.8c0-1.3-1.8-3.3-1.8-3.3s-1.8 2-1.8 3.3z", "fill": "#4FA8F5" }
            ]
        },
        "cloud-snow": {
            "layers": [
                { "d": "M16.4 15.4H8.6a6.2 6.2 0 1 1 5.94-7.94 4 4 0 0 1 1.86 7.94z", "fill": "#F1F6FF" },
                { "d": "M8.2 17.6a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6zM12 19a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6zM15.8 17.6a1.3 1.3 0 1 0 0 2.6 1.3 1.3 0 0 0 0-2.6z", "fill": "#8FD3FF" }
            ]
        },
        "cloud-lightning": {
            "layers": [
                { "d": "M16.4 15.4H8.6a6.2 6.2 0 1 1 5.94-7.94 4 4 0 0 1 1.86 7.94z", "fill": "#F1F6FF" },
                { "d": "M13.4 15.2l-3.6 4.6h2.6l-1.2 4.4 4-5.2h-2.6z", "fill": "#FFC53D" }
            ]
        },
        "cloud-fog": {
            "layers": [
                { "d": "M16.4 14.6H8.6a6.2 6.2 0 1 1 5.94-7.94 4 4 0 0 1 1.86 7.94z", "fill": "#F1F6FF" },
                { "d": "M6 17.4h12M8.4 20.4h7.2", "stroke": "#9FB2C6", "w": 1.9 }
            ]
        },
        "waves": {
            "layers": [
                { "d": "M2.6 9.2c2-2.2 4-2.2 6 0s4 2.2 6 0 4-2.2 6.8 0", "stroke": "#6EC1F7", "w": 2 },
                { "d": "M2.6 15.2c2-2.2 4-2.2 6 0s4 2.2 6 0 4-2.2 6.8 0", "stroke": "#2F8FE0", "w": 2 }
            ]
        },
        "droplet": {
            "layers": [
                { "d": "M12 3.2c3.6 4.4 5.6 7.3 5.6 9.9a5.6 5.6 0 0 1-11.2 0c0-2.6 2-5.5 5.6-9.9z", "fill": "#3FA9F5" },
                { "d": "M9.4 13.2a3.4 3.4 0 0 0 1.7 2.6", "stroke": "#C6E7FF", "w": 1.4 }
            ]
        },
        // --- network ---
        "wifi": {
            "layers": [
                { "d": "M3.4 9.2a12.4 12.4 0 0 1 17.2 0", "stroke": "#8AD8F0", "w": 2.1 },
                { "d": "M6.6 12.8a8.4 8.4 0 0 1 10.8 0", "stroke": "#45B6E8", "w": 2.1 },
                { "d": "M9.9 16.3a4.4 4.4 0 0 1 4.2 0", "stroke": "#1E90D6", "w": 2.1 },
                { "d": "M12 18.4a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4z", "fill": "#1E90D6" }
            ]
        },
        "bluetooth": {
            "layers": [
                { "d": "M7 7.2l10 9.6-5 3.8V3.4l5 3.8L7 16.8", "stroke": "#3B82F6", "w": 2 }
            ]
        },
        "battery": {
            "layers": [
                { "d": "M2.6 7.2h14.6a1.1 1.1 0 0 1 1.1 1.1v7.4a1.1 1.1 0 0 1-1.1 1.1H2.6a1.1 1.1 0 0 1-1.1-1.1V8.3a1.1 1.1 0 0 1 1.1-1.1z", "fill": "#34C759" },
                { "d": "M19.6 10.2h1.5a.9.9 0 0 1 .9.9v2.8a.9.9 0 0 1-.9.9h-1.5z", "fill": "#1E7A45" },
                { "d": "M11.1 8.6h3.6l-2.1 3.1h2.2l-4.6 4.3 1.3-3.3H8.4z", "fill": "#FFFFFF" }
            ]
        },
        "hotspot": {
            "layers": [
                { "d": "M12 9.6a2.4 2.4 0 1 0 0 4.8 2.4 2.4 0 0 0 0-4.8z", "fill": "#FF9F0A" },
                { "d": "M8.2 5.6A6.4 6.4 0 0 0 5.6 8.2M15.8 5.6a6.4 6.4 0 0 1 2.6 2.6M5.6 15.8a6.4 6.4 0 0 0 2.6 2.6M18.4 15.8a6.4 6.4 0 0 1-2.6 2.6M4.4 3.2A10.4 10.4 0 0 0 2.2 5.4M19.6 3.2a10.4 10.4 0 0 1 2.2 2.2M2.2 18.6a10.4 10.4 0 0 0 2.2 2.2M21.8 18.6a10.4 10.4 0 0 1-2.2 2.2", "stroke": "#FFB340", "w": 1.8 }
            ]
        },
        "ethernet": {
            "layers": [
                { "d": "M4.6 4.6h14.8a1.2 1.2 0 0 1 1.2 1.2v9.4a1.2 1.2 0 0 1-1.2 1.2H4.6a1.2 1.2 0 0 1-1.2-1.2V5.8a1.2 1.2 0 0 1 1.2-1.2z", "fill": "#8E9AAF" },
                { "d": "M6.8 8.2h2.4v1.6H6.8zM10.8 8.2h2.4v1.6h-2.4zM14.8 8.2h2.4v1.6h-2.4z", "fill": "#FFD166" },
                { "d": "M10.6 19.4h2.8v-1.6h-2.8z", "fill": "#6B7684" }
            ]
        },
        // --- the bar's own cells ---
        "inbox": {
            "layers": [
                { "d": "M3 12.4h4.7l1.7 2.8h5.2l1.7-2.8H21v4.4A2.6 2.6 0 0 1 18.4 19.4H5.6A2.6 2.6 0 0 1 3 16.8z", "fill": "#3B82F6" },
                { "d": "M12 3.6l4.2 4.2h-2.7v4.6h-3V7.8H7.8z", "fill": "#FFFFFF" }
            ]
        },
        "dnd": {
            "layers": [
                { "d": "M12 3.4a5.6 5.6 0 0 0-5.6 5.6v3.2l-1.8 3.2h14.8l-1.8-3.2V9A5.6 5.6 0 0 0 12 3.4z", "fill": "#AEBAC9" },
                { "d": "M9.8 17.4a2.2 2.2 0 0 0 4.4 0z", "fill": "#AEBAC9" },
                { "d": "M4.2 4.2l15.6 15.6", "stroke": "#FF453A", "w": 2.1 }
            ]
        },
        "mixer": {
            "layers": [
                { "d": "M6 4.4v15.2M12 4.4v15.2M18 4.4v15.2", "stroke": "#C7D3E0", "w": 1.6 },
                { "d": "M4.3 8.2h3.4a.9.9 0 0 1 .9.9v1.4a.9.9 0 0 1-.9.9H4.3a.9.9 0 0 1-.9-.9V9.1a.9.9 0 0 1 .9-.9z", "fill": "#FF453A" },
                { "d": "M10.3 12.6h3.4a.9.9 0 0 1 .9.9v1.4a.9.9 0 0 1-.9.9h-3.4a.9.9 0 0 1-.9-.9v-1.4a.9.9 0 0 1 .9-.9z", "fill": "#34C759" },
                { "d": "M16.3 6.2h3.4a.9.9 0 0 1 .9.9v1.4a.9.9 0 0 1-.9.9h-3.4a.9.9 0 0 1-.9-.9V7.1a.9.9 0 0 1 .9-.9z", "fill": "#0A84FF" }
            ]
        },
        "monitor": {
            "layers": [
                { "d": "M4 4.4h16a2.6 2.6 0 0 1 2.6 2.6v8.6A2.6 2.6 0 0 1 20 18.2H4a2.6 2.6 0 0 1-2.6-2.6V7A2.6 2.6 0 0 1 4 4.4z", "fill": "#39424E" },
                { "d": "M3.6 6.6h16.8v9.4H3.6z", "fill": "#57C1F5" },
                { "d": "M15 8.2a1.9 1.9 0 1 0 0 3.8 1.9 1.9 0 0 0 0-3.8z", "fill": "#FFE08A" },
                { "d": "M3.6 13.6l4.4-3.4 3 2.6 3.2-2.8 6.2 4.4v1.6H3.6z", "fill": "#6BCB77" },
                { "d": "M10 18.2h4v1.6h2.6v1.4H7.4v-1.4H10z", "fill": "#39424E" }
            ]
        },
        "wallpaper": {
            "layers": [
                { "d": "M3 4.4h18a1.6 1.6 0 0 1 1.6 1.6v12a1.6 1.6 0 0 1-1.6 1.6H3A1.6 1.6 0 0 1 1.4 18V6A1.6 1.6 0 0 1 3 4.4z", "fill": "#C98A4B" },
                { "d": "M3.6 6.4h16.8v11.2H3.6z", "fill": "#7EC8F7" },
                { "d": "M16.2 8.4a1.9 1.9 0 1 0 0 3.8 1.9 1.9 0 0 0 0-3.8z", "fill": "#FFD166" },
                { "d": "M3.6 14.2l4.6-4 3.2 2.8 3.4-3.4 6 5.2v2.8H3.6z", "fill": "#6BCB77" }
            ]
        },
        "clipboard": {
            "layers": [
                { "d": "M6 3.6h12a1.6 1.6 0 0 1 1.6 1.6v15A1.6 1.6 0 0 1 18 21.8H6a1.6 1.6 0 0 1-1.6-1.6v-15A1.6 1.6 0 0 1 6 3.6z", "fill": "#C98A4B" },
                { "d": "M7.2 6.6h9.6v12.4H7.2z", "fill": "#FFF7EC" },
                { "d": "M9.2 2.6h5.6a1.1 1.1 0 0 1 1.1 1.1v2.1a1.1 1.1 0 0 1-1.1 1.1H9.2a1.1 1.1 0 0 1-1.1-1.1V3.7a1.1 1.1 0 0 1 1.1-1.1z", "fill": "#8D99AE" },
                { "d": "M9.2 9.8h5.6M9.2 12.6h5.6M9.2 15.4h3.6", "stroke": "#C4CDD7", "w": 1.2 }
            ]
        },
        "app-window": {
            "layers": [
                { "d": "M4 3.4h16a2.6 2.6 0 0 1 2.6 2.6v12a2.6 2.6 0 0 1-2.6 2.6H4a2.6 2.6 0 0 1-2.6-2.6V6A2.6 2.6 0 0 1 4 3.4z", "fill": "#F1F5F9" },
                { "d": "M4.4 4.6h2.8v2.8H4.4zM10.6 4.6h2.8v2.8h-2.8zM16.8 4.6h2.8v2.8h-2.8zM4.4 10.6h2.8v2.8H4.4zM10.6 10.6h2.8v2.8h-2.8zM16.8 10.6h2.8v2.8h-2.8zM4.4 16.6h2.8v2.8H4.4zM10.6 16.6h2.8v2.8h-2.8zM16.8 16.6h2.8v2.8h-2.8z", "fill": "#3B82F6" },
                { "d": "M4.4 4.6h2.8v2.8H4.4zM10.6 10.6h2.8v2.8h-2.8zM16.8 16.6h2.8v2.8h-2.8z", "fill": "#FF9F0A" }
            ]
        },
        "cog": {
            "layers": [
                { "d": "M3.4 6.6h17.2M3.4 12h17.2M3.4 17.4h17.2", "stroke": "#C7D3E0", "w": 1.6 },
                { "d": "M6.2 5.2h3.4a.9.9 0 0 1 .9.9v1a.9.9 0 0 1-.9.9H6.2a.9.9 0 0 1-.9-.9v-1a.9.9 0 0 1 .9-.9z", "fill": "#BF5AF2" },
                { "d": "M13.2 10.6h3.4a.9.9 0 0 1 .9.9v1a.9.9 0 0 1-.9.9h-3.4a.9.9 0 0 1-.9-.9v-1a.9.9 0 0 1 .9-.9z", "fill": "#34C759" },
                { "d": "M9.4 16h3.4a.9.9 0 0 1 .9.9v1a.9.9 0 0 1-.9.9H9.4a.9.9 0 0 1-.9-.9v-1a.9.9 0 0 1 .9-.9z", "fill": "#0A84FF" }
            ]
        },
        "shutdown": {
            "layers": [
                { "d": "M7.2 6.4a7.2 7.2 0 1 0 9.6 0", "stroke": "#FF453A", "w": 2.2 },
                { "d": "M12 2.8v8.4", "stroke": "#FF453A", "w": 2.2 }
            ]
        },
        // --- media ---
        "music": {
            "layers": [
                { "d": "M9.4 17.4V5.6l11-1.8v11.4", "stroke": "#FF9F0A", "w": 1.8 },
                { "d": "M9.4 17.4a2.9 2.9 0 1 0 0 5.8 2.9 2.9 0 0 0 0-5.8zM20.4 15.2a2.9 2.9 0 1 0 0 5.8 2.9 2.9 0 0 0 0-5.8z", "fill": "#FFD166" }
            ]
        },
        "speaker": {
            "layers": [
                { "d": "M3.4 9.2h3.6L11.6 5v14L7 14.8H3.4z", "fill": "#5E5CE6" },
                { "d": "M15.4 9.2a4 4 0 0 1 0 5.6M18 6.4a7.6 7.6 0 0 1 0 11.2", "stroke": "#8E8CE8", "w": 1.7 }
            ]
        },
        "speaker-off": {
            "layers": [
                { "d": "M3.4 9.2h3.6L11.6 5v14L7 14.8H3.4z", "fill": "#8E8CE8" },
                { "d": "M15.6 9.6l4.8 4.8M20.4 9.6l-4.8 4.8", "stroke": "#FF453A", "w": 1.8 }
            ]
        },
        "mic": {
            "layers": [
                { "d": "M8.6 4.6a3.4 3.4 0 0 1 6.8 0v6a3.4 3.4 0 0 1-6.8 0z", "fill": "#FF9F0A" },
                { "d": "M5.4 11.4a6.6 6.6 0 0 0 13.2 0M12 18v3.4", "stroke": "#C9A227", "w": 1.8 }
            ]
        },
        "headphones": {
            "layers": [
                { "d": "M4 14.6v-2.4a8 8 0 0 1 16 0v2.4", "stroke": "#5E5CE6", "w": 2 },
                { "d": "M2.6 13.4h3.2a1.4 1.4 0 0 1 1.4 1.4v3.4a1.4 1.4 0 0 1-1.4 1.4H4a1.4 1.4 0 0 1-1.4-1.4z", "fill": "#5E5CE6" },
                { "d": "M18.2 13.4h3.2a1.4 1.4 0 0 1 1.4 1.4v3.4a1.4 1.4 0 0 1-1.4 1.4h-1.8a1.4 1.4 0 0 1-1.4-1.4z", "fill": "#5E5CE6" }
            ]
        },
        "record": {
            "layers": [
                { "d": "M12 4.6a7.4 7.4 0 1 0 0 14.8 7.4 7.4 0 0 0 0-14.8z", "fill": "#FF453A" },
                { "d": "M9.2 8.4a3.8 3.8 0 0 1 3-1.4", "stroke": "#FF8A85", "w": 1.4 }
            ]
        },
        "gamepad": {
            "layers": [
                { "d": "M7.2 8.4h9.6a5.2 5.2 0 0 1 5.1 6.2l-.7 3.4a2.6 2.6 0 0 1-4.4 1.4L14.9 17H9.1l-1.8 2.4a2.6 2.6 0 0 1-4.4-1.4l-.7-3.4A5.2 5.2 0 0 1 7.2 8.4z", "fill": "#5E5CE6" },
                { "d": "M6.6 12.6h3.2M8.2 11v3.2", "stroke": "#FFFFFF", "w": 1.5 },
                { "d": "M15.4 11.8a1.1 1.1 0 1 0 0 2.2 1.1 1.1 0 0 0 0-2.2zM18 13.6a1.1 1.1 0 1 0 0 2.2 1.1 1.1 0 0 0 0-2.2z", "fill": "#FFFFFF" }
            ]
        },
        "play": {
            "layers": [
                { "d": "M6.4 4.4l13 7.6-13 7.6z", "fill": "#34C759" }
            ]
        },
        "pause": {
            "layers": [
                { "d": "M6.6 4.4h4v15.2h-4zM13.4 4.4h4v15.2h-4z", "fill": "#FF9F0A" }
            ]
        },
        "next": {
            "layers": [
                { "d": "M5 4.6l11 7.4-11 7.4zM17 4.6h2.6v14.8H17z", "fill": "#34C759" }
            ]
        },
        "prev": {
            "layers": [
                { "d": "M19 4.6L8 12l11 7.4zM4.4 4.6H7v14.8H4.4z", "fill": "#34C759" }
            ]
        },
        "camera": {
            "layers": [
                { "d": "M3 7.6h4l1.6-2.4h6.8L17 7.6h4a1.6 1.6 0 0 1 1.6 1.6v9.2A1.6 1.6 0 0 1 21 20H3a1.6 1.6 0 0 1-1.6-1.6V9.2A1.6 1.6 0 0 1 3 7.6z", "fill": "#39424E" },
                { "d": "M12 9.6a4.4 4.4 0 1 0 0 8.8 4.4 4.4 0 0 0 0-8.8z", "fill": "#57C1F5" },
                { "d": "M12 11.4a2.6 2.6 0 1 0 0 5.2 2.6 2.6 0 0 0 0-5.2z", "fill": "#B3E5FC" }
            ]
        },
        "video": {
            "layers": [
                { "d": "M3 6.4h12a1.6 1.6 0 0 1 1.6 1.6v8a1.6 1.6 0 0 1-1.6 1.6H3A1.6 1.6 0 0 1 1.4 16V8A1.6 1.6 0 0 1 3 6.4z", "fill": "#39424E" },
                { "d": "M16.6 10.4l6-3.2v9.6l-6-3.2z", "fill": "#5E5CE6" }
            ]
        },
        "user": {
            "layers": [
                { "d": "M12 3.4a4.6 4.6 0 1 0 0 9.2 4.6 4.6 0 0 0 0-9.2z", "fill": "#FF9F0A" },
                { "d": "M3.4 20.6a8.6 8.6 0 0 1 17.2 0z", "fill": "#FFD166" }
            ]
        },
        "sparkles": {
            "layers": [
                { "d": "M12 2.8l1.8 5.6 5.6 1.8-5.6 1.8-1.8 5.6-1.8-5.6L4.6 10.2l5.6-1.8z", "fill": "#FFD166" },
                { "d": "M18.6 14.4l.9 2.7 2.7.9-2.7.9-.9 2.7-.9-2.7-2.7-.9 2.7-.9z", "fill": "#FF9F0A" }
            ]
        },
        "bolt": {
            "layers": [
                { "d": "M13.4 2.2L5 13.6h5.4L10.2 21.8 19 10.4h-5.6z", "fill": "#FFC53D" }
            ]
        },
        "palette": {
            "layers": [
                { "d": "M12 2.6a9.4 9.4 0 0 0 0 18.8c1 0 1.8-.8 1.8-1.8v-.9a1.8 1.8 0 0 1 1.8-1.8h1.2a5.4 5.4 0 0 0 5.4-5.4c0-4.9-4.6-8.9-10.2-8.9z", "fill": "#F1F5F9" },
                { "d": "M7.2 12.2a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM9 7.4a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM14 6.6a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM17.4 9.6a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3z", "fill": "#FF9F0A" }
            ]
        },
        "language": {
            "layers": [
                { "d": "M12 2.6a9.4 9.4 0 1 0 0 18.8 9.4 9.4 0 0 0 0-18.8z", "fill": "#5E5CE6" },
                { "d": "M2.6 12h18.8M12 2.6c2.6 2.6 3.9 5.9 3.9 9.4s-1.3 6.8-3.9 9.4c-2.6-2.6-3.9-5.9-3.9-9.4s1.3-6.8 3.9-9.4z", "stroke": "#B9B4FF", "w": 1.1 }
            ]
        },
        "rocket": {
            "layers": [
                { "d": "M12 2.4c3.2 2.4 4.8 5.7 4.8 9.2l-2 3.4H9.2l-2-3.4c0-3.5 1.6-6.8 4.8-9.2z", "fill": "#E8EDF3" },
                { "d": "M12 7.2a1.9 1.9 0 1 0 0 3.8 1.9 1.9 0 0 0 0-3.8z", "fill": "#57C1F5" },
                { "d": "M7.2 14.4l-2.6 2.6 4.4 1.4 1.4 4.4 2.6-2.6zM16.8 14.4l2.6 2.6-4.4 1.4-1.4 4.4-2.6-2.6z", "fill": "#FF453A" },
                { "d": "M10.4 18.4h3.2l-1.6 3.4z", "fill": "#FF9F0A" }
            ]
        },
        "search": {
            "layers": [
                { "d": "M10.4 3.4a7 7 0 1 0 0 14 7 7 0 0 0 0-14z", "fill": "#5E5CE6" },
                { "d": "M15.6 15.6l5 5", "stroke": "#8E8CE8", "w": 2.4 }
            ]
        },
        "trash": {
            "layers": [
                { "d": "M6.6 7.4h10.8l-1 12a1.8 1.8 0 0 1-1.8 1.6H9.4a1.8 1.8 0 0 1-1.8-1.6z", "fill": "#8E9AAF" },
                { "d": "M3.4 5.4h17.2v2.2H3.4z", "fill": "#6B7684" },
                { "d": "M9.2 2.6h5.6l1 2.8H8.2z", "fill": "#6B7684" },
                { "d": "M10.2 10.4v7M13.8 10.4v7", "stroke": "#F1F5F9", "w": 1.3 }
            ]
        },
        "download": {
            "layers": [
                { "d": "M10.4 2.6h3.2v9.2h3.4L12 18.2l-5-6.4h3.4z", "fill": "#34C759" },
                { "d": "M3.4 19.4h17.2v2.2H3.4z", "fill": "#2FB35E" }
            ]
        },
        "check": {
            "layers": [
                { "d": "M20.4 6.6L9.6 18.4 3.6 12.4l2.2-2.2 3.8 3.9 8.6-9.7z", "fill": "#34C759" }
            ]
        },
        "close": {
            "layers": [
                { "d": "M5.4 3.6L12 10.2l6.6-6.6 2.2 2.2-6.6 6.6 6.6 6.6-2.2 2.2-6.6-6.6-6.6 6.6-2.2-2.2 6.6-6.6-6.6-6.6z", "fill": "#FF453A" }
            ]
        },
        "refresh": {
            "layers": [
                { "d": "M12 4.4a7.6 7.6 0 0 1 6.6 3.8l2-2.2v5.6h-5.6l2.2-2.2A5.6 5.6 0 0 0 6.5 12H4.4A7.6 7.6 0 0 1 12 4.4z", "fill": "#5E5CE6" },
                { "d": "M12 19.6a7.6 7.6 0 0 1-6.6-3.8l-2 2.2v-5.6h5.6l-2.2 2.2A5.6 5.6 0 0 0 17.5 12h2.1A7.6 7.6 0 0 1 12 19.6z", "fill": "#8E8CE8" }
            ]
        }
    })

    readonly property var layers: art[name] !== undefined ? art[name].layers : []

    /** The 24-unit path space scaled into this cell, exactly as the line glyphs do it. */
    readonly property real u: Math.min(width, height) / 24

    /**
     * The layers, grouped by paint.
     *
     * A `Shape` can only hold shape paths, and a `Repeater` can only
     * create items -- so the artwork cannot be instantiated from a list.
     * It can, however, be PAINTED from a list: one path can carry many
     * subpaths, and every subpath in a path shares its fill and its
     * stroke. So the layers are grouped by the paint they use, each
     * group's paths are joined into one path string, and a fixed set of
     * path slots takes them.
     *
     * Six slots is enough for every icon here; the empty ones cost
     * nothing, because a path with no data has no bounds and no paint.
     */
    readonly property var groups: groupLayers(layers)

    function groupLayers(list) {
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const l = list[i];
            const key = (l.fill || "") + "|" + (l.stroke || "") + "|" + (l.w || 0);
            let g = null;
            for (let j = 0; j < out.length; j++) {
                if (out[j].key === key) {
                    g = out[j];
                    break;
                }
            }
            if (!g) {
                g = { "key": key, "fill": l.fill || "transparent", "stroke": l.stroke || "transparent", "w": l.w || 0, "d": "" };
                out.push(g);
            }
            g.d += (g.d ? " " : "") + l.d;
        }
        return out;
    }

    function groupAt(i) {
        return i < groups.length ? groups[i] : { "fill": "transparent", "stroke": "transparent", "w": 0, "d": "" };
    }

    /**
     * The bounce.
     *
     * A short push out and back, with a little overshoot on the way so it
     * reads as a thing that noticed something rather than a widget that
     * resized. `Behavior` does the easing; the timer clears the bump so the
     * next event can raise it again.
     */
    /**
     * True once the icon has been shown at least once. The first name
     * binding is not a change -- it is the icon arriving -- so it must not
     * make the bar twitch on every start.
     */
    property bool settled: false
    Component.onCompleted: settled = true

    /** Nudge the icon. Callers use it when something they care about moved. */
    function pulse() {
        if (settled)
            bump = 1;
    }

    onNameChanged: pulse()
    onBumpChanged: if (bump > 0) bumpTimer.restart()
    Timer {
        id: bumpTimer
        interval: 240
        onTriggered: root.bump = 0
    }

    Shape {
        id: glyph
        width: 24
        height: 24
        scale: root.u
        transformOrigin: Item.TopLeft
        x: glyph.boundingRect.width > 0 ? root.width / 2 - (glyph.boundingRect.x + glyph.boundingRect.width / 2) * root.u : (root.width - 24 * root.u) / 2
        y: glyph.boundingRect.height > 0 ? root.height / 2 - (glyph.boundingRect.y + glyph.boundingRect.height / 2) * root.u : (root.height - 24 * root.u) / 2
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer
        visible: root.layers.length > 0

        ShapePath {
            fillColor: root.groupAt(0).fill
            strokeColor: root.groupAt(0).stroke
            strokeWidth: root.groupAt(0).w
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.groupAt(0).d }
        }

        ShapePath {
            fillColor: root.groupAt(1).fill
            strokeColor: root.groupAt(1).stroke
            strokeWidth: root.groupAt(1).w
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.groupAt(1).d }
        }

        ShapePath {
            fillColor: root.groupAt(2).fill
            strokeColor: root.groupAt(2).stroke
            strokeWidth: root.groupAt(2).w
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.groupAt(2).d }
        }

        ShapePath {
            fillColor: root.groupAt(3).fill
            strokeColor: root.groupAt(3).stroke
            strokeWidth: root.groupAt(3).w
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.groupAt(3).d }
        }

        ShapePath {
            fillColor: root.groupAt(4).fill
            strokeColor: root.groupAt(4).stroke
            strokeWidth: root.groupAt(4).w
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.groupAt(4).d }
        }

        ShapePath {
            fillColor: root.groupAt(5).fill
            strokeColor: root.groupAt(5).stroke
            strokeWidth: root.groupAt(5).w
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.groupAt(5).d }
        }
    }

    GlyphIcon {
        id: fallback
        anchors.fill: parent
        visible: root.layers.length === 0
        name: root.name
        color: root.color
        stroke: root.stroke
    }
}
