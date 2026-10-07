import QtQuick
import Quickshell
import "../Singletons"

/**
 * A strip entry for an enabled Omarchy plugin, hosted inside Better Bar.
 *
 * The host shell is the owner of plugin state and services, but its bar is
 * hidden now that Better Bar replaced it, and a bar-widget's popout is painted
 * *in that bar's own window* — Omarchy's own words: "popups anchor on the side
 * opposite the bar edge, sliding into the workspace". So summoning one returns
 * "ok" and shows nothing at all, because the surface it opened is the bar that
 * is no longer there. That is why every plugin here mounts the plugin's real
 * QML locally instead of asking the host to open it: the widget builds its own
 * popout (`Ui/KeyboardPanel.qml`, a full-screen layer-shell window) anchored to
 * whatever item it is handed, so mounting it here puts that popout on screen,
 * on this side of the bar, at Better Bar's geometry.
 *
 * The bar contract comes from PluginBarStub, standing in for the bar the host
 * can no longer show, and a widget's inline settings come from the registry, so
 * one reading `setting("format", …)` still finds its config.
 *
 * Three kinds take different routes:
 *
 *   - panel / overlay / menu plugins are mounted by the host itself, which
 *     owns their windows and positions them. Loading a second copy would double
 *     the surface and fight the host over the IPC target, so a click just
 *     summons the host's instance.
 *   - bar-widget plugins draw a GlyphIcon here by default, and mount their own
 *     widget on the first click. This is what makes a plugin installed tomorrow
 *     look like part of this shell with nothing written for it: the icon, its
 *     optical baseline, its size and its tint all come from the same GlyphIcon
 *     every native pill icon uses, rather than from whatever the plugin's own
 *     QML happens to draw.
 *   - a bar-widget that opted into `"better": { "render": "widget" }` is
 *     mounted eagerly instead, filling the cell, because its visual carries data
 *     a bare icon cannot show — a volume bar, a temperature, a track name. That
 *     is also the escape hatch for a *stateful* strip entry, which no single
 *     icon can express — a recording dot, a live timer, a replay ring.
 *     A plugin that needs one ships its own component in the pill
 *     instead, and Plugins.hostsInStrip excludes it.
 *
 * A plugin panel is a layer-shell window, not an Item, so it cannot be drawn
 * with the pill's card chrome. What this does give it is Better Bar's placement:
 * correct band geometry via PluginBarStub's overrides, anchored to the icon.
 */
Item {
    id: root

    property string pluginId: ""

    /** Scale factor supplied by the pill, so the entry tracks strip sizing. */
    property real s: 1

    /** Mirrors the bar's hover.live gate, like the neighbouring icons. */
    property bool hoverLive: true

    /** The strip's real band size, forwarded to the panel's geometry. */
    property real barHeightOverride: -1
    property real barWidthOverride: -1

    /**
     * A widget with a bar entry opens its content in the pill's own surface:
     * the bar expands into the plugin exactly as a native cell expands into the
     * calendar. StripCell wires this to the pill's surface opener; host-mounted
     * kinds (no bar entry) and a function missing here fall back to the popout.
     */
    property var openSurfaceRequest: null

    readonly property var plugin: Plugins.byId(pluginId)
    readonly property string pluginName: plugin && plugin.name ? plugin.name : pluginId

    /**
     * The bar surface this plugin ships, loaded here when it has one.
     *
     * Keyed on the entry point rather than on `kinds`: a plugin can be both
     * `menu` and `bar-widget` (omarchy.menu is), and in that case its bar
     * surface is the better thing to host, because the host's own menu window
     * is anchored to the off-screen bar.
     */
    readonly property string entryPoint: Plugins.barEntryFor(pluginId)

    /**
     * "glyph" (the default) or "widget" — see Plugins.renderFor.
     *
     * A plugin draws its own strip entry only when it opts in, so a newly
     * installed plugin looks like part of this shell with nothing written for
     * it. The `iconName` half of the test matters as much as the mode: a plugin
     * that asks for the glyph path but resolves no glyph is better served by its
     * own widget than by a letter, so an unresolvable name falls back to the
     * hosting behaviour below rather than rendering an empty box.
     */
    readonly property string renderMode: Plugins.renderFor(pluginId)
    readonly property string iconName: Plugins.iconFor(pluginId)
    readonly property bool glyphMode: renderMode === "glyph" && iconName !== ""

    /**
     * No bar surface, so the host owns this plugin's UI and positions it. A
     * click just summons the host's instance rather than loading a second copy,
     * which would fight the host over the IPC target.
     */
    readonly property bool hostMounted: plugin !== null && entryPoint === ""

    /** Nothing to show: no plugin, or it ships no UI at all. */
    readonly property bool renderable: plugin !== null && (entryPoint !== "" || hostMounted)

    /**
     * Whether the plugin's own QML is instantiated yet.
     *
     * "widget" mode mounts immediately, because there the widget *is* the strip
     * entry and an unwritten cell is a wrong one. "glyph" mode mounts on the
     * first click instead: the mount exists to own the popout, so a plugin
     * nobody clicks should not cost a Pipewire graph, an MPRIS subscription or a
     * StatusNotifier binding just to sit invisible in the strip.
     */
    property bool mountRequested: !root.glyphMode

    readonly property bool mounted: root.renderable && !root.hostMounted && root.mountRequested

    // Strip rhythm: every entry occupies one icon cell so the row keeps its
    // spacing regardless of what a plugin renders internally. Clipped for the
    // same reason: a plugin laid out for a 26px bar must not stretch the strip.
    implicitWidth: 17 * s
    implicitHeight: 17 * s
    visible: renderable
    clip: true

    // ---- host-driven kinds --------------------------------------------------

    /**
     * Set by activate() when the mount has to exist before the panel can open.
     */
    property bool pendingOpen: false

    /**
     * The button waiting on the mount, or 0. Kept as the raw button code so the
     * replay after load is the same press, not an approximation of it.
     */
    property int pendingPress: 0

    /**
     * Open this plugin's own panel.
     *
     * A mounted widget opens its own popout, and that is the only route that
     * puts a panel where the user clicked: Omarchy paints a bar-widget's popup
     * against the bar it is given, and the bar it is given is the hidden one, so
     * a host summon lands the card against a window that is not on screen.
     *
     * `openOrEnable` is the fallback for the kinds the host mounts itself, and
     * for a widget that turns out to carry no popout at all. openOrEnable rather
     * than openPanel because a plugin the user has just enabled is not in the
     * registry yet, and summon refuses a disabled plugin outright.
     */
    /**
     * Open this plugin's own panel, in the pill's morphing-window surface.
     * The bar-widget opens the primary content; the plugin's settings panel is
     * the separate right-click contract routed through the same surface.
     */
    function openOwn(settingsMode) {
        if (!root.hostMounted && root.entryPoint !== "") {
            if (root.openSurfaceRequest) {
                root.openSurfaceRequest(root.pluginId, !!settingsMode);
                return;
            }
        }
        if (settingsMode) {
            // No surface host to carry the settings request: fall through to a
            // host summon rather than dropping the right-click.
            if (!root.hostMounted && root.openSurfaceRequest) {
                root.openSurfaceRequest(root.pluginId, true);
                return;
            }
        }
        if (root.mounted && widget.item && typeof widget.item.open === "function") {
            widget.item.open();
            return;
        }
        Plugins.openOrEnable(pluginId);
    }

    /**
     * One entry point for every button this cell accepts.
     *
     * A widget that registered a button answers for itself and knows what each
     * button means — Omarchy's audio mutes on right-click, opens on middle, and
     * scrolls for volume — so the press is handed to it verbatim rather than
     * reinterpreted here. Only a widget with no button of its own falls through
     * to opening its panel.
     *
     * Anything else loses the button: a bare Panel root has no right-click, and
     * treating that as "open the panel" would make a right-click indistinguishable
     * from a left-click.
     */
    function handlePress(button) {
        if (!root.renderable)
            return;
        if (!root.mounted) {
            // Mount before deciding, and replay the exact button once the widget
            // exists — otherwise the first press of any button could only ever
            // open the panel, and a first right-click would mute nothing.
            root.pendingPress = button;
            root.mountRequested = true;
            return;
        }
        if (barStub.pressAny(button))
            return;
        if (button === Qt.LeftButton)
            root.openOwn(false);
        else if (button === Qt.RightButton)
            root.openOwn(true);
    }

    function activate() {
        if (root.mounted) {
            root.openOwn();
            return;
        }
        if (!widget.loaded) {
            // Local files load synchronously, so onLoaded can finish this; the
            // flag keeps a widget that never finishes loading from swallowing the
            // click.
            root.pendingOpen = true;
            root.mountRequested = true;
            return;
        }
        Plugins.openOrEnable(pluginId);
    }

    // ---- locally hosted kinds ----------------------------------------------

    PluginBarStub {
        id: barStub
        moduleId: root.pluginId
        barHeightOverride: root.barHeightOverride
        barWidthOverride: root.barWidthOverride
        // A nominal bar band so a widget's `bar ? bar.barSize : default`
        // fallback is not zero; the cell is clamped below regardless.
        barSize: Math.round(26 * root.s)
    }

    /**
     * Where the plugin's own QML is mounted.
     *
     * "widget" mode fills the cell: the widget draws the strip entry and is
     * sized by the data it shows. "glyph" mode mounts it zero-sized on the cell's
     * horizontal centre, because there the GlyphIcon is the strip entry and this
     * exists only to own the popout — and KeyboardPanel places its card at
     * `anchorScreenPos.x + anchorW / 2`, so a zero-width anchor lands it exactly
     * under the icon.
     *
     * `visible` stays true in both modes and `opacity` does the hiding. That is
     * the whole trick: an invisible parent keeps a panel's popout from mapping,
     * while a zero-opacity one still maps it and paints nothing. The cell clips,
     * so even a widget that ignores the size it is given cannot spill sideways.
     */
    Item {
        id: mount
        x: root.glyphMode ? root.width / 2 : 0
        y: 0
        width: root.glyphMode ? 0 : root.width
        height: root.glyphMode ? 0 : root.height
        opacity: root.glyphMode ? 0 : 1

        Loader {
            id: widget
            anchors.fill: parent
            active: root.mounted
            source: root.mounted ? root.entryPoint : ""
            onLoaded: {
                root.inject();
                // Replay whichever press was waiting on the mount, then fall back
                // to the open request that has no button of its own.
                if (root.pendingPress !== 0) {
                    var button = root.pendingPress;
                    root.pendingPress = 0;
                    root.handlePress(button);
                } else if (root.pendingOpen) {
                    root.pendingOpen = false;
                    root.openOwn();
                }
            }
        }
    }

    /**
     * A widget that brings its own MouseArea (any bar surface) handles clicks
     * itself, and reports a real implicit size. A bare panel root is 0x0 and
     * has no hit area, so it needs the fallback target below.
     *
     * Never true in glyph mode: the mount is zero-sized there, so the widget's
     * own hit area is zero-sized too and would swallow the click with nothing to
     * show for it. The cell owns the click and routes it to the popout.
     */
    readonly property bool selfInteractive: !root.glyphMode && widget.item
        && (widget.item.implicitWidth > 0 || widget.item.implicitHeight > 0)

    /**
     * The strip entry itself — a vector glyph on Better Bar's icon cell, tinted
     * and stroked exactly like every other pill icon.
     *
     * Anchored to the cell rather than sized from `s` twice: the cell already is
     * 17*s, and the glyph shares one optical baseline with its neighbours by
     * construction, which is the part a plugin's own Text glyph cannot do.
     */
    GlyphIcon {
        anchors.fill: parent
        visible: root.glyphMode
        name: root.iconName
        color: area.containsMouse ? Theme.cream : Theme.iconDim
        stroke: 1.7
    }

/**
     * Declared before the Loader so it sits underneath: a widget that ships its
     * own click handling wins, and this only catches the bare-panel case.
     *
     * All three buttons, because a plugin's secondary actions are part of its
     * contract — the audio widget mutes on right-click and opens on middle-click,
     * and dropping to left-only made both of those unreachable.
     */
    MouseArea {
        id: area
        anchors.fill: parent
        anchors.margins: -6 * root.s
        hoverEnabled: true
        enabled: root.hoverLive && root.renderable && !root.selfInteractive
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) { root.handlePress(mouse.button); }
    }

    function inject() {
        var target = widget.item;
        if (!target)
            return;
        // A bar surface reads `bar` off itself; a panel root reads it too, and
        // needs the anchor to position against.
        if ("bar" in target)
            target.bar = barStub;
        if ("moduleName" in target && !target.moduleName)
            target.moduleName = root.pluginId;
        if ("settings" in target)
            target.settings = Plugins.settingsFor(root.pluginId);
        // The mount, not the cell: a popout anchors to this item's position, and
        // in glyph mode that is the point on the cell's centre the card hangs
        // from rather than the cell's left edge.
        if ("anchorItem" in target)
            target.anchorItem = mount;
        if ("hostWidget" in target)
            target.hostWidget = root;
        if ("service" in target)
            target.service = null;
    }

    Component.onCompleted: {
        root.inject();
        // Verification affordance, same shape as the selftest below: with
        // BETTER_PLUGIN_OPEN=<plugin-id> set, that entry mounts and opens itself
        // so the panel can be checked on screen without a pointer to click with.
        // Inert unless the variable names this plugin.
        var openId = Quickshell.env("BETTER_PLUGIN_OPEN");
        if (openId && openId === root.pluginId) {
            root.pendingOpen = true;
            root.mountRequested = true;
        }
        if (Quickshell.env("BETTER_PLUGIN_SELFTEST") === "1") {
            // Headless check that the auto-entry rule produced real, correctly
            // sized cells: a plugin that failed to load is reported rather than
            // leaving a silent blank in the strip.
            root.reportSelftest();
            // The manifest scan lands a beat after the strip is built, and
            // `entry` is read once — so a first pass saying `entry=-` may just
            // mean "not scanned yet", not "this plugin ships no bar surface".
            // Re-report once the scan has had its chance, which is the only way
            // to tell those two apart.
            settleSelftest.restart();
        }
    }

    Timer {
        id: settleSelftest
        interval: 2500
        repeat: false
        onTriggered: root.reportSelftest()
    }

    function reportSelftest() {
        print("better-plugin-selftest id=" + root.pluginId
            + " name=" + root.pluginName
            + " kinds=" + (root.plugin ? root.plugin.kinds.join(",") : "n/a")
            + " registry=" + Plugins.plugins.length
            + " manifests=" + Object.keys(Plugins.manifests).length
            + " hostMounted=" + root.hostMounted
            + " entry=" + (root.entryPoint || "-")
            + " render=" + root.renderMode
            + " icon=" + (root.iconName || "-")
            + " glyphMode=" + root.glyphMode
            + " selfInteractive=" + root.selfInteractive
            + " mounted=" + root.mounted
            + " anchorCell=" + mount.x + "," + mount.y + " " + mount.width + "x" + mount.height
            + " cell=" + root.width + "x" + root.height
            + " visible=" + root.visible
            + " loaded=" + (widget.item ? widget.item.toString().split("(")[0] : "no")
            + " loadStatus=" + widget.status
            + " loadError=" + (widget.status === Loader.Error ? "Loader.Error" : "-"));
    }

    // ---- fallback chrome ----------------------------------------------------

    /**
     * Shown for host-mounted kinds, and for a plugin whose entry point failed
     * to load. The plugin's own glyph is used whenever it renders one, so this
     * stays out of the way in the normal case.
     */
    Rectangle {
        id: chip
        anchors.centerIn: parent
        width: height
        radius: height / 2
        visible: !root.hostMounted && !root.glyphMode && !root.selfInteractive
        color: area.containsMouse ? Theme.accent : Theme.iconDim
        opacity: 0.85
        border.width: 1.2 * root.s
        // Theme.cream is theme-derived (Theme.qml falls back to Omarchy's
        // foreground, then textOverride), so the rim already tracks the
        // palette. Forcing it to the accent instead would make the chip's
        // outline fight the theme's foreground.
        border.color: Theme.cream

        Text {
            anchors.centerIn: parent
            text: (root.pluginName || "?").charAt(0).toUpperCase()
            color: Theme.bright
            font.family: Theme.font
            font.pixelSize: Math.round(10 * root.s)
            font.bold: true
        }
    }

    Tooltip {
        s: root.s
        placement: "below"
        title: root.pluginName
        show: area.containsMouse
    }
}
