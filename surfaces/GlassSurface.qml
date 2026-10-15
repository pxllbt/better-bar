pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"

/**
 * 玻 GLASS sub-surface: the pill's material. Transparency mode switches between
 * the translucent glass and the solid frosted look; text visibility adds extra
 * contrast for copy drawn on the glass. Reached from the Appearance index and
 * folds back to it on the back chevron or an empty click.
 */
SettingsSurface {
    id: root

    backSurface: "appcat"
    implicitHeight: content.implicitHeight

    rows: [
        { item: glassRow, kind: "toggle", get: function () { return Flags.glass; }, set: function (v) { Flags.glass = v; } },
        { item: bgRow, kind: "seg", vals: [1, 0.8, 0.6], get: function () { return bgLevel(); }, set: function (v) { Flags.pillOpacity = v; } },
        { item: glassTextRow, kind: "seg", vals: [0, 0.5, 1], get: function () { return Flags.glassText; }, set: function (v) { Flags.glassText = v; } }
    ]

    /**
     * How see-through the pill is, as one of four steps. This is the pill's own
     * background, not the glass material: `Flags.pillOpacity` is what
     * LiquidGlass multiplies the fill alpha by on BOTH paths, so the desktop
     * shows through whether transparency is on or off. It was already wired into
     * the fill and had no control anywhere, so the one knob that actually
     * governs the pill's opacity was unreachable.
     */
    // Three steps, not four. SettingsRow's control slot is right-anchored with
    // no width cap, so a fourth word-length pill pushes the control's left edge
    // past the row's own label and the two overlap -- the same overflow the
    // Screens resolution row had. Short labels and no sub-caption keep the
    // control inside its half of the row.
    readonly property var bgOptions: [
        { label: "Solid", value: 1 },
        { label: "Soft", value: 0.8 },
        { label: "Sheer", value: 0.6 }
    ]

    /** Snap whatever is stored to the nearest offered step, so the seg always lights. */
    function bgLevel() {
        var v = (Flags.pillOpacity === undefined || Flags.pillOpacity === null) ? 1 : Number(Flags.pillOpacity);
        var best = bgOptions[0].value;
        var bestD = Math.abs(v - best);
        for (var i = 1; i < bgOptions.length; i++) {
            var d = Math.abs(v - bgOptions[i].value);
            if (d < bestD) { bestD = d; best = bgOptions[i].value; }
        }
        return best;
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "GLASS"
            showBack: true
        }

Item { width: 1; height: 7 * root.s }
        SettingsRow {
            id: glassRow
            surface: root
            name: "Transparency mode"
            icon: "droplet"
            sub: "Translucent pill · desktop shows through"

            LinkToggle {
                s: root.s
                on: Flags.glass
                onToggled: Flags.glass = !Flags.glass
            }
        }

        // The pill's own background, independent of the material switch above:
        // it applies whether transparency is on or off, because it is the fill
        // alpha rather than the glass treatment.
        //
        // Disabled while following, because Hyprland now owns the value. Leaving
        // it live would let you set an opacity that is silently overridden on the
        // next read — a control that does nothing is worse than a missing one.
        SettingsRow {
            id: bgRow
            surface: root
            name: "Background"
            icon: "layers"
            sub: ""
            enabled: !root.following

            SettingsSeg {
                s: root.s
                options: root.bgOptions
                value: root.bgLevel()
                onPicked: (v) => Flags.pillOpacity = v
            }
        }

        /**
         * Follow Hyprland instead of the bar's own opinion.
         *
         * This is the row that makes the disagreement go away. Hyprland's blur is
         * what the whole desktop gets to smear under, so a bar that picks its own
         * translucency disagrees with every window behind it — and on a box where
         * blur is off, the glassy pill is precisely the artifact that setting was
         * disabled to avoid.
         *
         * The sub says what following would do right now rather than describing
         * the feature in the abstract, so "solid · 100% opaque" is a decidable
         * answer instead of a promise.
         */
        SettingsRow {
            id: followRow
            surface: root
            icon: "droplet"
            name: "Match Hyprland"
            sub: {
                if (!HyprGlass.usable)
                    return "Hyprland is not being read, so the bar keeps its own setting";
                var v = [HyprGlass.blurEnabled ? "blurred" : "solid"];
                v.push(Math.round(HyprGlass.pillOpacity * 100) + "% opaque");
                return v.join(" · ");
            }

            LinkToggle {
                s: root.s
                on: Flags.glassFollowHypr
                onToggled: Flags.glassFollowHypr = !Flags.glassFollowHypr
            }
        }

        /** True while the compositor, not the bar, is choosing the material. */
        readonly property bool following: (Flags.glassFollowHypr || false) && HyprGlass.usable

        SettingsRow {
            id: glassTextRow
            surface: root
            name: "Text visibility"
            icon: "type"
            sub: "Extra contrast for copy on the glass"
            enabled: Flags.glass
            last: true

            SettingsSeg {
                s: root.s
                options: [
                    { label: "Off", value: 0 },
                    { label: "Soft", value: 0.5 },
                    { label: "Strong", value: 1 }
                ]
                value: Flags.glassText || 0
                onPicked: (v) => Flags.glassText = v
            }
        }
    }
}