pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Hyprland
import "Singletons"
import "components"
import "surfaces"

/**
 * The pill body. One element carries every state. Width/height driven by `state`
 * (rest, hover/pinned, mixer, calendar) with a no-overshoot easing so surfaces
 * grow out of the pill in place. Surfaces are stacked absolutely and cross-fade.
 *
 * Hover comes from a passive HoverHandler, pin from a passive TapHandler, so
 * neither swallows pointer events from the surfaces stacked above: workspace
 * dots, the clock target, tray icons and the mixer faders get their own clicks
 * and drags.
 */
Item {
    id: pill

    property real s: 1
    property string screenName: ""
    property var barWindow
    property string surface: ""

    /**
     * Tail retention: a closed surface keeps its object tree alive until its
     * own countdown elapses so a quick return is still instant. Every closed
     * surface is tracked by name in `closedAt` and swept independently, so
     * closing one never extends another's tail. When memory saver is on each
     * surface gets a tiered cooldown (heavy/thirsty surfaces evict sooner);
     * when off, closed surfaces stay resident for the whole session and only
     * the explicit `unloadAll` IPC drops them.
     */
    property string prevSurface: ""

    /**
     * Idle (ms) before a closed surface is unloaded, keyed by surface name,
     * scaled from the Flags.unloadSec base (`unloadS` here). The two heaviest
     * surfaces (wallpaper, mixer) keep the shortest tail, the four thirstiest
     * frequent fliers get one generous reset, and everything else — which is
     * every settings sub-surface — drops at the base rather than double it, so
     * walking the whole settings tree costs one tier instead of two.
     */
    readonly property real unloadS: (Flags.memorySaver ? Math.max(10, Flags.unloadSec) : 1e12)
    readonly property var unloadIdleMs: ({
        // heaviest, evict first
        wallpaper:   unloadS * 1000,
        mixer:       unloadS * 1000,
        // thirsty frequent fliers: one generous reset, then reclaim
        clipboard:   unloadS * 2 * 1000,
        media:       unloadS * 2 * 1000,
        calendar:    unloadS * 2 * 1000,
        // everything else: the base tier, so a settings sweep releases as it goes
        default:     unloadS * 1000
    })

    /**
     * Ceiling on how many closed surfaces may stay resident at once. Every tier
     * countdown is independent, so sweeping the whole settings tree in a few
     * seconds used to leave every page it touched alive until its own tail ran
     * out — the burst outruns the countdown it is racing. Past this many, the
     * longest-waiting surface is reclaimed on the next sweep whatever tier it is
     * on. Four covers the re-toggle burst the tail exists for (close a page, hop
     * to another, hop back) without letting a full sweep accumulate.
     *
     * This is a bound, not a large saving. A settings page measures around
     * 0.4 MiB each once its fonts are mapped, so the cap trims a few MiB off a
     * fast sweep; the memory a surface sweep used to appear to cost was almost
     * entirely the one-time font mapping behind it (see Theme.fontJpWeight).
     */
    readonly property int unloadKeepMax: 4

    /**
     * Every surface that has stopped being open, keyed by surface name, with
     * the epoch ms it closed. `surfaceItem` drops the entry when the surface
     * reopens (that *is* the "reset the clock and wait again" of the tail);
     * the sweep timer unloads each entry once its own tier has elapsed.
     */
    property var closedAt: ({})

    onSurfaceChanged: {
        if (pill.prevSurface.length > 0 && pill.prevSurface !== pill.surface)
            pill.scheduleUnload(pill.prevSurface);
        pill.prevSurface = pill.surface;
    }

    Component.onCompleted: {
        Surfaces.register(pill);
        // Seed the dock's mirrors from the resting geometry, matching the
        // change handlers below so the dock never starts at the open size.
        root.pillBarHeight = restSize.height;
        root.pillBarRadius = roundRadius;
    }

    property bool hovered: false
    /**
     * True while a reveal interaction is in flight: the pointer touched the
     * reveal strip and is still over it or the collapsed pill it pulled in.
     * The strip sits in the input mask even when the pill is hidden, so this
     * persists across the strip -> pill transition until the pointer leaves,
     * keeping the mask covering both and the pill collapsed until it is
     * clicked.
     */
    property bool revealSession: false
    property bool pinned: false
    property bool forcePinned: false
    /**
     * Latch held by an explicit Expand click in the media card, so the pill
     * stays grown while the pointer is still inside it.
     *
     * It no longer survives cursor exit. It used to, and with auto-hide off
     * nothing else released it either — not focus loss, which is gated on
     * auto-hide, and not the surface close that Expand itself performs — so
     * expanding the media card left the pill sitting over the desktop until
     * it was tapped. `graceTimer` now releases it with `hoverLatch`.
     */
    property bool expandLatch: false

    readonly property bool held: pinned || forcePinned
    readonly property bool mixerOpen: surface === "mixer"
    readonly property bool calendarOpen: surface === "calendar"
    readonly property bool launcherOpen: surface === "launcher"
    readonly property bool clipboardOpen: surface === "clipboard"
    readonly property bool wallpaperOpen: surface === "wallpaper"
    readonly property bool powerOpen: surface === "power"
    readonly property bool mediaOpen: surface === "media"
    readonly property bool linkOpen: surface === "link"
    readonly property bool weatherOpen: surface === "weather"
    readonly property bool wifiOpen: surface === "wifi"
    readonly property bool btOpen: surface === "bt"
    readonly property bool batteryOpen: surface === "battery"
    readonly property bool sysmonOpen: surface === "sysmon"
    readonly property bool appearanceOpen: surface === "appearance"
    readonly property bool appcatOpen: surface === "appcat"
    readonly property bool displayOpen: surface === "display"
    readonly property bool themeOpen: surface === "theme"
    readonly property bool accentOpen: surface === "accent"
    readonly property bool glassOpen: surface === "glass"
    readonly property bool fontColorOpen: surface === "fontcolor"
    readonly property bool interfaceOpen: surface === "interface"
    readonly property bool fontpickerOpen: surface === "fontpicker"
    readonly property bool pluginsOpen: surface === "plugins"
    readonly property bool updateOpen: surface === "update"
    readonly property bool settingsLike: appearanceOpen || appcatOpen || displayOpen || themeOpen || accentOpen || glassOpen || fontColorOpen || interfaceOpen || fontpickerOpen || pluginsOpen || updateOpen
    readonly property bool hasMedia: Players.list.length > 0

    readonly property var netDevices: (typeof Networking !== "undefined" && Networking && Networking.devices) ? Networking.devices.values : []
    readonly property var wifiDev: netDevices.find(function(d) { return d && d.type === DeviceType.Wifi }) || null
    readonly property bool wifiOn: (typeof Networking !== "undefined" && Networking) ? Networking.wifiEnabled : false
    readonly property var wifiNets: (wifiDev && wifiDev.networks) ? wifiDev.networks.values : []
    readonly property var wifiActive: wifiNets.find(function(n) { return n && n.connected }) || null
    readonly property real wifiLevel: (wifiActive && wifiActive.signalStrength) || 0
    readonly property var btAdapter: (typeof Bluetooth !== "undefined" && Bluetooth) ? Bluetooth.defaultAdapter : null
    readonly property bool btOn: btAdapter ? btAdapter.enabled === true : false
    readonly property bool surfaceOpen: surface.length > 0

    /**
     * A plugin surface — the strip's plugin cells expand the bar into their own
     * content exactly like a native cell ("plugin:omarchy.audio"). The pill
     * treats the whole family as one `plugin` surface; the plugin id is pinned
     * separately so the loader knows which plugin's QML to host. A trailing
     * ":panel" marks the variant a right-click opened: the strip entry itself
     * is left-click content, the plugin's settings/panel surface is the
     * right-click content, and both expand the bar the same way.
     */
    readonly property bool pluginSurfaceOpen: surface.startsWith("plugin:")
    readonly property bool pluginPopupOpen: !!(pluginSurfaceOpen && ldPluginSurface.item && ldPluginSurface.item.popupActive)
    readonly property string pluginSurfaceTarget: pluginSurfaceOpen ? surface.substring(7) : ""
    readonly property bool pluginSurfacePanelMode: pluginSurfaceTarget.indexOf(":panel") >= 0
    readonly property string pluginSurfaceId: {
        const at = pluginSurfaceTarget.indexOf(":panel");
        return at >= 0 ? pluginSurfaceTarget.substring(0, at) : pluginSurfaceTarget;
    }
    readonly property string pluginSurfaceEntryPoint: pluginSurfaceOpen
        ? (pluginSurfacePanelMode ? Plugins.settingsEntryFor(pluginSurfaceId) : Plugins.barEntryFor(pluginSurfaceId))
        : ""

    property bool hoverLatch: false

    /**
     * A strip layout menu is open (some StripCell dropped its card below the
     * pill). The card sits below the pill window, so the pill would otherwise
     * retract the instant the cursor leaves its own body -- the menu would be
     * neither reachable nor clickable. Latched here and un-latched when the
     * last card closes, so `expanded`/`mode` stay "hover" (and the input mask
     * grows to cover the card) for as long as the menu needs the cursor.
     */
    property bool stripMenuOpen: false

    /**
     * False for the first seconds after the shell maps. Hyprland hands pointer
     * focus to a freshly mapped layer surface at the cursor's position, which
     * the window-level HoverHandler reads as a pill hover and latches the pill
     * open (issue #20). Latching only after boot settles filters that spurious
     * enter; a real hover during the window just expands late, harmlessly.
     */
    property bool bootSettled: false

    Timer {
        interval: 3000
        running: true
        onTriggered: pill.bootSettled = true
    }

    readonly property bool expanded: surfaceOpen || held || hoverLatch || expandLatch || stripMenuOpen

    /**
     * First expansion (hover, latch, held, or any surface) marks weather as
     * actually wanted, so its refresh/fetch network work starts only then. The
     * chip itself is always built and renders the cached forecast instantly.
     */
    onExpandedChanged: {
        if (pill.expanded)
            Weather.needed = true;
    }

    /**
     * The collapsed pill becomes a compact top-centre capsule when the "strip"
     * main display is picked: it docks flush against the top screen edge, so
     * its top corners square off while the bottom corners stay rounded — the
     * Dynamic Glacier silhouette. Window reservation and auto-hide behave
     * exactly like the other faces.
     */
    readonly property bool stripBar: Flags.mainDisplay === "strip"

    /**
     * True when this pill sits on the monitor Hyprland currently has focused.
     * Only used to drop the cursor latch on focus loss: `hidden` itself is
     * central and does not key off monitor focus, so transient (OSD/toast)
     * appearances retract on their own even on the focused monitor.
     */
    readonly property bool monFocused: {
        const m = Hyprland.focusedMonitor;
        return m ? m.name === pill.screenName : false;
    }

    /**
     * Auto-hide mode retracts as soon as this monitor loses focus, even if the
     * cursor is still over the strip or pill: a click only expands the pill
     * temporarily, so focus loss (or cursor exit, via graceTimer) is what
     * releases the latch. Outside auto-hide the pill's pin still holds.
     */
    onMonFocusedChanged: if (!monFocused && Flags.autoHide) {
        revealSession = false;
        hoverLatch = false;
        expandLatch = false;
    }

    /**
     * True when a transient overlay owns the pill: an OSD flash (workspace,
     * volume, track, brightness, battery, record), a notification toast, or a
     * quick-record overlay. These pop the pill open without the cursor ever
     * getting involved, so the pill must let them finish and then retract on
     * its own — transients hold the pill up, but they leave no latch behind.
     */
    readonly property bool transientLive: toastActive

/**
     * Whatever is holding the pill up right now, in any mode: a reveal session
     * under the cursor, an expansion (pin, latch or open surface), an in-flight
     * file drop, a live transient overlay (OSD flash, toast, quick-record), or
     * the game bar. Anything here wins over both hide rules below.
     */
    readonly property bool heldOpen: revealSession || expanded || dragActive || transientLive
        || mode === "game"

    /**
     * Cursor-follow: the pointer is on another monitor, so this bar is not where
     * the user is. Read through CursorTrack, which owns the one definition, so
     * the pill's hide gate and the shell's reserved band cannot disagree about
     * whether a monitor is holding a bar. False while the pointer is still
     * unlocated and whenever cursor-follow is off, which leaves the auto-hide
     * rule below behaving exactly as it did.
     */
    readonly property bool offCursor: CursorTrack.offCursor(screenName)

    /**
     * True when the pill should retract off the top edge. Auto-hide retracts
     * once nothing holds the pill open, and cursor-follow retracts on every
     * monitor the pointer is not on. These are OR'd, not alternatives: either
     * one alone retracts the pill, so turning auto-hide on while cursor-follow
     * is already set must still hide the bar. A ternary here made the second
     * setting silently win and the first do nothing. Deliberately
     * ignore raw `hovered`: the reveal session flag (with its 350ms grace) is
     * what keeps the pill up while the cursor is near it, so a cursor sitting on
     * the strip's edge cannot bounce it. The reveal strip still catches the
     * pointer, so a hidden pill slides back in on reach.
     */
    readonly property bool hidden: heldOpen ? false : (Flags.autoHide || offCursor)

    /**
     * The special workspace shown on this pill's monitor, surfaced as a plain word
     * in place of the clock so it is obvious you are looking at the minimized stash
     * or the private space rather than your real desktop. Empty in the normal case.
     */
    readonly property string specialView: {
        var ms = Hyprland.monitors.values;
        for (var i = 0; i < ms.length; i++) {
            if (ms[i] && ms[i].name === pill.screenName) {
                var o = ms[i].lastIpcObject;
                var sw = (o && o.specialWorkspace) ? o.specialWorkspace.name : "";
                if (sw && sw.indexOf("special:") === 0) {
                    var id = sw.slice("special:".length);
                    var sl = Spaces.list;
                    for (var j = 0; j < sl.length; j++)
                        if (sl[j] && sl[j].id === id)
                            return sl[j].name;
                    if (id === "minimized") return "Minimized";
                    if (id === "private") return "Private";
                    if (id === "stash") return "Stash";
                    return id.charAt(0).toUpperCase() + id.slice(1);
                }
                return "";
            }
        }
        return "";
    }
    readonly property bool toastActive: Notifs.popups.length > 0
    readonly property bool osdActive: osd.flashing

    /**
     * A transient OSD (workspace switch, volume, brightness) that starts while
     * a non-critical toast is showing retires that toast permanently instead of
     * covering it and letting it reappear — a covered-and-returned toast reads
     * as a second notification. Critical toasts are never covered or retired:
     * the mode ladder gives them priority over the OSD.
     */
    onOsdActiveChanged: if (osdActive && toastActive && !Notifs.toastCritical) Notifs.clearPopups()


    /**
     * The resting face's base grid: a fixed 160x38, scaled by the monitor
     * factor alone. "UI scale" is the one size control — it moves `s`, so it
     * moves this face and every other surface together. A second pair of
     * width/height multipliers used to sit beside it, which could only ever
     * disagree with the scale they were measured against, and is gone.
     */
    readonly property real restW: 160 * s
    readonly property real restH: 38 * s

    /**
     * The icon cell every strip glyph is drawn in.
     *
     * One number because the cells were three sizes: most were 17, the wifi
     * and bluetooth cells were 15, and the do-not-disturb one 16. A GlyphIcon
     * fills its cell, so a 15 cell drew a visibly smaller glyph next to a 17
     * one -- and WifiGlyph, whose own implicit size is 17*s, was being shrunk
     * to 15 by the cell it sat in. Any per-icon size now belongs in the glyph
     * table, not in the cell.
     */
    readonly property real iconCell: 17 * s

    /**
     * Strip-face geometry: a compact top-centre notch pill. Its width is
     * computed explicitly (not from the row's implicit width) so the media
     * title can be elided to exactly what the budget allows; on a 1920px
     * screen the content lands around 500-600px wide. Lower-priority sections
     * (visualizer, then media) fold away first when the budget tightens.
     */
    readonly property real stripPad: 20 * s
    readonly property real stripGap: 16 * s
    readonly property real stripCap: Math.max(320 * s, Math.min(600 * s, (barWindow ? barWindow.width : 1920 * s) - 60 * s))

    // No strip-face zoom property lives here any more. The width slider used to
    // scale the whole notch (content and box) through a transform, with the
    // layout width multiplied to match, and both halves are gone: the notch now
    // draws at the size `stripFaceW` already measured, and the row is its own
    // size again. Keeping a scale of 1 would have left a transform that cannot
    // do anything but still has to agree with the width it was computed from.
    readonly property real stripArtW: 22 * s
    readonly property real stripMinTitle: 55 * s
    readonly property real stripMaxTitle: 220 * s

    readonly property real stripVizW: (Cava.bars * 1.8 + (Cava.bars - 1) * 1.2) * s

    /** Media-side gaps depend only on the visualizer. */
    readonly property int stripMediaGaps: 1 + (Cava.active ? 1 : 0)

    readonly property bool stripMedia: Players.has && stripRoomForTitle >= stripMinTitle
    readonly property real stripRoomForTitle: stripCap - 2 * stripPad - stripArtW - stripFixedW
        - 4 * stripGap - stripMediaGaps * stripGap
        - (Cava.active ? stripVizW : 0)

    readonly property real stripTitleW: stripMedia ? Math.min(stripMaxTitle, stripRoomForTitle, Math.max(stripMinTitle, stripTitleMetrics.advanceWidth)) : 0
    readonly property real stripFixedW: stripDay.implicitWidth + stripTime.implicitWidth
        + stripWs.implicitWidth + stripLay.implicitWidth + stripBat.implicitWidth

    readonly property real stripFaceW: {
        let w = 2 * stripPad + stripFixedW + 4 * stripGap;
        if (stripMedia) {
            w += stripArtW + stripGap + stripTitleW;
            if (Cava.active) w += stripVizW + stripGap;
            w += stripGap;
        }
        return w;
    }
    readonly property real hoverPad: 20 * s
    readonly property real hoverW: hoverRow.implicitWidth + 2 * hoverPad
    readonly property real hoverH: 58 * s
    readonly property real mixerH: 214 * s
    readonly property real launcherW: 360 * s
    readonly property real launcherH: 332 * s
    readonly property real clipboardW: 360 * s
    readonly property real clipboardH: 332 * s
    readonly property real wallpaperW: 720 * s
    readonly property real wallpaperH: 172 * s
    readonly property real powerW: 330 * s
    readonly property real powerH: 150 * s
    readonly property real mediaW: 470 * s
    readonly property real mediaH: 132 * s
    readonly property real batteryW: 316 * s
    readonly property real wifiW: 272 * s
    readonly property real btW: 286 * s
    readonly property real sysmonW: 392 * s
    readonly property real settingsScale: 0.9
    readonly property real settingsW: 392 * s * settingsScale
    readonly property real fontpickerW: 360 * s * settingsScale
    readonly property real toastW: 342 * s
    readonly property real dragOverW: 300 * s
    readonly property real dragOverH: 126 * s
    readonly property real gameH: 34 * s
    readonly property real gameW: barWindow ? barWindow.width : 1920
    readonly property real restCorner: 18 * s
    readonly property real openCorner: 22 * s

    /**
     * Latch-once lazy load. Every surface sleeps in an inactive Loader until its
     * first open; the size and ame thunks below resolve items through here by
     * surface name. The ordering is the trick: flip `active` before any read of
     * the loader, so the calling binding never has the loader registered as a
     * dep when the flip fires mid-evaluation (that read-then-write would be a
     * binding loop). The write is idempotent and the Loader loads synchronously,
     * so a first open reads the real implicitHeight in the same evaluation and
     * the morph target is exact. When a surface leaves, scheduleUnload starts
     * its own tail; opening it again before the tail fires cancels the drop, so
     * only surfaces that stay closed actually unload.
     */
    function surfaceItem(name) {
        if (!pill.loaders[name])
            return null;
        const ld = pill.loaders[name]();
        if (!ld)
            return null;
        ld.active = true;
        pill.cancelUnload(name);
        return ld.item;
    }

    /**
     * Single source of truth for every morphing surface, keyed by its `surface`
     * string. Each entry owns the surface's target size (a thunk so the geometry
     * it reads registers as a live dep of targetSize) and a thunk resolving the
     * surface item Ame anchors to while it is open (null = Ame falls back to the
     * pill's own hover or wake anchor). `mode`, `targetSize` and `ameSurface` all
     * derive from this, so adding a surface is one entry here plus its Loader —
     * no parallel ternary chains to keep in lockstep.
     */
    readonly property var surfaces: ({
        calendar:  { size: () => { const it = surfaceItem("calendar"); return Qt.size((it.implicitWidth > 0 ? it.implicitWidth : 282 * s) + 36 * s, it.implicitHeight + 32 * s); }, ame: () => surfaceItem("calendar") },
        weather:   { size: () => { const it = surfaceItem("weather"); return Qt.size((it.implicitWidth > 0 ? it.implicitWidth : 282 * s) + 36 * s, it.implicitHeight + 32 * s); }, ame: () => surfaceItem("weather") },
        launcher:  { size: () => { surfaceItem("launcher"); return Qt.size(launcherW, launcherH); }, ame: () => surfaceItem("launcher") },
        clipboard: { size: () => { surfaceItem("clipboard"); return Qt.size(clipboardW, clipboardH); }, ame: () => surfaceItem("clipboard") },
        wallpaper: { size: () => { surfaceItem("wallpaper"); return Qt.size(wallpaperW, wallpaperH); }, ame: () => null },
        power:     { size: () => { surfaceItem("power"); return Qt.size(powerW, powerH); }, ame: () => surfaceItem("power") },
        media:     { size: () => { surfaceItem("media"); return Qt.size(mediaW, mediaH); }, ame: () => surfaceItem("media") },
        mixer:     { size: () => Qt.size(93 * Math.max(4, surfaceItem("mixer").faderCount) * s, mixerH), ame: () => surfaceItem("mixer") },
        link:      { size: () => { const it = surfaceItem("link"); return Qt.size(it.desiredW, it.implicitHeight + 26 * s); }, ame: () => surfaceItem("link") },
        wifi:      { size: () => Qt.size(wifiW, surfaceItem("wifi").implicitHeight + 26 * s), ame: () => surfaceItem("wifi") },
        bt:        { size: () => Qt.size(btW, surfaceItem("bt").implicitHeight + 26 * s), ame: () => surfaceItem("bt") },
        battery:   { size: () => Qt.size(batteryW, surfaceItem("battery").implicitHeight + 26 * s), ame: () => surfaceItem("battery") },
        sysmon:    { size: () => Qt.size(sysmonW, surfaceItem("sysmon").implicitHeight + 33 * s), ame: () => surfaceItem("sysmon") },
        appearance: { size: () => Qt.size(settingsW, surfaceItem("appearance").implicitHeight + 29 * s), ame: () => surfaceItem("appearance") },
        appcat:     { size: () => Qt.size(settingsW, surfaceItem("appcat").implicitHeight + 29 * s), ame: () => surfaceItem("appcat") },
        display:    { size: () => Qt.size(settingsW, surfaceItem("display").implicitHeight + 29 * s), ame: () => surfaceItem("display") },
        theme:      { size: () => Qt.size(settingsW, surfaceItem("theme").implicitHeight + 29 * s), ame: () => surfaceItem("theme") },
        accent:     { size: () => Qt.size(settingsW, surfaceItem("accent").implicitHeight + 29 * s), ame: () => surfaceItem("accent") },
        glass:      { size: () => Qt.size(settingsW, surfaceItem("glass").implicitHeight + 29 * s), ame: () => surfaceItem("glass") },
        fontcolor:  { size: () => Qt.size(settingsW, surfaceItem("fontcolor").implicitHeight + 29 * s), ame: () => surfaceItem("fontcolor") },
        interface:  { size: () => Qt.size(settingsW, surfaceItem("interface").implicitHeight + 29 * s), ame: () => surfaceItem("interface") },
        fontpicker: { size: () => Qt.size(fontpickerW, surfaceItem("fontpicker").implicitHeight + 29 * s), ame: () => surfaceItem("fontpicker") },
        plugins:    { size: () => Qt.size(settingsW, surfaceItem("plugins").implicitHeight + 29 * s), ame: () => surfaceItem("plugins") },
        update:     { size: () => Qt.size(settingsW, surfaceItem("update").implicitHeight + 29 * s), ame: () => surfaceItem("update") },
        plugin:     { size: () => {
                // Omarchy plug-ins render their UIs as popout layer surfaces;
                // there is no embeddable content to morph the pill into, so the
                // pill stays at its strip size and the plugin's window does the
                // work. (Kept as a separate thunk so `surfaceItem` spins up
                // the loader and fills its inject contract before any call.)
                surfaceItem("plugin");
                return pill.restSize;
            }, ame: () => surfaceItem("plugin") }
    })

    /**
     * Loader lookup by surface name, as thunks so the map never pins a loader
     * before it is built. The unload machinery keeps every closed surface
     * resident for its own tiered countdown, then drops it — so opening a
     * surface pays its build cost once, and re-opening within the tail is
     * instant.
     */
    readonly property var loaders: ({
        calendar:   () => ldCalendar,
        weather:    () => ldWeather,
        launcher:   () => ldLauncher,
        clipboard:  () => ldClip,
        wallpaper:  () => ldWall,
        power:      () => ldPower,
        media:      () => ldMedia,
        mixer:      () => ldMixer,
        link:       () => ldLink,
        wifi:       () => ldWifi,
        bt:         () => ldBt,
        battery:    () => ldBattery,
        sysmon:     () => ldSysmon,
        appearance: () => ldAppearance,
        appcat:     () => ldAppcat,
        display:    () => ldDisplay,
        theme:      () => ldTheme,
        accent:     () => ldAccent,
        glass:      () => ldGlass,
        fontcolor:  () => ldFontcolor,
        interface:  () => ldInterface,
        fontpicker: () => ldFontpicker,
        plugins:    () => ldPlugins,
        update:     () => ldUpdate,
        plugin:     () => ldPluginSurface
    })

    /**
     * Arm a closed surface's own tail. Only surfaces that are actually loaded
     * are tracked, so a name can never sit in the map pointing at an inactive
     * loader. Reopening the surface before the tail elapses has already called
     * cancelUnload by the time this could re-fire, so the countdown restarts
     * on the next close — "open again before its tier elapses, stay alive".
     */
    /**
     * Plugin surfaces close under their full surface string ("plugin:audio")
     * but live in the machinery under the bare family name ("plugin"), so every
     * unload call normalizes before it keys anything. Everything else passes
     * through untouched.
     */
    function normSurface(name) {
        return (name && name.length > 7 && name.indexOf("plugin:") === 0) ? "plugin" : name;
    }

    function scheduleUnload(name) {
        // With the saver off the tier is effectively infinite, so nothing would
        // ever be swept on its own; keeping the sweep running would evict purely
        // on the residency cap, which is not what the cap is for.
        if (!Flags.memorySaver)
            return;
        name = pill.normSurface(name);
        if (!name || !Object.prototype.hasOwnProperty.call(pill.loaders, name))
            return;
        const ld = pill.loaders[name]();
        if (!ld || !ld.active)
            return;
        pill.closedAt[name] = Date.now();
        sweepTimer.start();
    }

    function cancelUnload(name) {
        name = pill.normSurface(name);
        if (!name)
            return;
        delete pill.closedAt[name];
        if (Object.keys(pill.closedAt).length === 0)
            sweepTimer.stop();
    }

    /**
     * This surface's own idle window, from the tier map by surface name.
     * Loaders not actually defined (typo'd or removed names) fall through to
     * the full default so they never evict accidentally early.
     */
    function idleFor(name) {
        name = pill.normSurface(name);
        var v = pill.unloadIdleMs[name];
        if (v === undefined)
            v = pill.unloadIdleMs.default;
        return v;
    }

    /**
     * Reclaim one closed surface: tear its loader down and forget the countdown.
     * Returns whether a live loader was actually dropped, so callers can tell a
     * real teardown (worth a GC) from a name that was already inert.
     */
    function dropClosed(name) {
        name = pill.normSurface(name);
        const fn = pill.loaders[name];
        const ld = fn ? fn() : null;
        const wasLive = !!(ld && ld.active);
        if (wasLive)
            ld.active = false;
        delete pill.closedAt[name];
        return wasLive;
    }

    /**
     * Periodic sweep. Each closed surface carries its own timestamp, so every
     * one is dropped independently once its own tier has elapsed; unloading one
     * never shortens or lengthens another's countdown. The list is walked
     * oldest-first so `unloadKeepMax` evicts the surface that has waited longest,
     * which is the one whose remaining tail buys the least.
     */
    Timer {
        id: sweepTimer
        interval: 5000
        repeat: true
        running: false
        onTriggered: {
            var now = Date.now();
            var names = Object.keys(pill.closedAt);
            names.sort(function (a, b) { return pill.closedAt[a] - pill.closedAt[b]; });
            var keeps = false;
            var dropped = false;
            for (var i = 0; i < names.length; i++) {
                const name = names[i];
                // over the cap, or past its own tier: reclaim
                if (i >= pill.unloadKeepMax || now - pill.closedAt[name] >= pill.idleFor(name)) {
                    if (pill.dropClosed(name))
                        dropped = true;
                } else {
                    keeps = true;
                }
            }
            if (dropped)
                Qt.callLater(pill.reapJs);
            if (!keeps)
                sweepTimer.stop();
        }
    }

    /**
     * Detached JS models/closures outlive a Loader teardown until the engine's
     * next major collection. A GC right after an eviction reclaims those
     * wrappers up-front instead of piling into a later spike. Guarded because
     * the `gc` global is not available in every JS environment.
     */
    function reapJs() {
        if (typeof gc === "function")
            gc();
    }

    /**
     * Drop every closed surface now, regardless of how much of its tail is
     * left. The open surface is never in `closedAt`, so it is untouched. This
     * is what the unloadAll IPC routes to every pill.
     */
    function unloadClosedSurfaces() {
        var names = Object.keys(pill.closedAt);
        var dropped = false;
        for (var i = 0; i < names.length; i++) {
            if (pill.dropClosed(names[i]))
                dropped = true;
        }
        sweepTimer.stop();
        if (dropped)
            Qt.callLater(pill.reapJs);
    }

    readonly property string mode: dragActive ? "dragOver"
        : (pluginSurfaceOpen ? "plugin"
        : (surfaceOpen && Object.prototype.hasOwnProperty.call(pill.surfaces, surface) ? surface
        : (Flags.gameMode ? "game"
        : (toastActive && Notifs.toastCritical && !held ? "toast"
        : (toastActive && !held ? "toast"
        : (expanded ? "hover" : "rest"))))))

    /**
     * AppImage drag-install state, live only while a file hovers the resting pill.
     * `dragStage` walks hover -> installing -> done, or bad for a non-AppImage drop.
     */
    property bool dragActive: false
    property string dragName: ""
    property string dragStage: ""

    signal requestSurface(string name)
    /** Morph the bar into a plugin's surface; the id (and optional right-click panel variant) live in the surface string. */
    signal requestPluginSurface(string pluginId, bool settingsMode)
    signal requestClose()

    /**
     * Forward an arrow-key nudge to the open mixer's targeted fader. Returns true
     * when the mixer is open and a fader consumed the step.
     */
    function mixerStep(deltaPct) {
        return (pill.mixerOpen && ldMixer.item) ? ldMixer.item.stepFocused(deltaPct) : false;
    }

    /**
     * Move the open mixer's keyboard focus across the fader row; `dir` is +1
     * (right) or -1 (left). No-op unless the mixer is open.
     */
    function mixerFocusMove(dir) {
        if (pill.mixerOpen && ldMixer.item)
            ldMixer.item.moveFocus(dir);
    }

    /**
     * Resolve which settings-family surface owns keyboard row navigation right
     * now: the category index or one of its morphing sub-surfaces. Returns null
     * when none of them is open.
     */
    function rowNavSurface() {
        if (pill.appearanceOpen)
            return ldAppearance.item;
        if (pill.appcatOpen)
            return ldAppcat.item;
        if (pill.displayOpen)
            return ldDisplay.item;
        if (pill.themeOpen)
            return ldTheme.item;
        if (pill.accentOpen)
            return ldAccent.item;
        if (pill.glassOpen)
            return ldGlass.item;
        if (pill.fontColorOpen)
            return ldFontcolor.item;
        if (pill.interfaceOpen)
            return ldInterface.item;
        if (pill.fontpickerOpen)
            return ldFontpicker.item;
        if (pill.pluginsOpen)
            return ldPlugins.item;
        return null;
    }

    /**
     * Move the focused settings row by `dir` (+1 down, -1 up), carrying the soul
     * seam. Returns true when a settings-family surface is open and consumed it.
     */
    function settingsMove(dir) {
        var nav = pill.rowNavSurface();
        if (!nav)
            return false;
        nav.kbMove(dir);
        return true;
    }

    /**
     * Step the focused settings row's control: a segmented choice cycles by
     * `dir`, a toggle is set on (dir > 0) or off. Returns true when consumed.
     */
    function settingsAdjust(dir) {
        var nav = pill.rowNavSurface();
        if (!nav)
            return false;
        nav.kbAdjust(dir);
        return true;
    }

    /**
     * Activate the focused settings row: a toggle flips, a nav row opens its
     * sub-surface. Returns true when a settings-family surface is open.
     */
    function settingsActivate() {
        var nav = pill.rowNavSurface();
        if (!nav)
            return false;
        nav.kbActivate();
        return true;
    }

    /**
     * Step the open surface back one level when its header bar is clicked: a
     * settings sub-surface returns to its declared `backSurface` (THEME, ACCENT
     * and GLASS fold back into the APPEARANCE sub-index, which and the other
     * categories fold back into the SETTINGS index), and the index or any other
     * surface dismisses to the hover pill. Empty space in the body never
     * triggers this.
     */
    function surfaceBack() {
        const nav = pill.rowNavSurface();
        if (nav && nav.backSurface && nav.backSurface.length > 0) {
            pill.requestSurface(nav.backSurface);
            return;
        }
        pill.requestClose();
    }

    /**
     * Slide the open wallpaper strip's focus by `dir` thumbs; +1 is right (older)
     * and -1 is left (newer). No-op unless the wallpaper surface is open.
     */
    function wallpaperMove(dir) {
        if (pill.wallpaperOpen && ldWall.item)
            ldWall.item.move(dir);
    }

    /**
     * Apply the wallpaper strip's focused thumb through wallpaper.sh. The
     * surface stays open so the pick can be iterated. No-op unless the
     * wallpaper surface is open.
     */
    function wallpaperActivate() {
        if (pill.wallpaperOpen && ldWall.item)
            ldWall.item.activate();
    }

    readonly property bool wallpaperSearching: pill.wallpaperOpen && ldWall.item !== null && ldWall.item.searching

    /** True while the strip is browsing wallhaven; bare keys go into its search. */
    readonly property bool wallpaperWh: pill.wallpaperOpen && ldWall.item !== null && ldWall.item.whSource

    /** True while the wallhaven search field holds keyboard focus, so keys type straight into it. */
    readonly property bool wallpaperWhTyping: pill.wallpaperOpen && ldWall.item !== null && ldWall.item.whTyping

    /**
     * Route a printable keystroke into the wallhaven search field, mirroring
     * the local name filter: focus the field and insert the character. No-op
     * unless the wallpaper surface is open and browsing wallhaven.
     */
    function wallpaperWhType(ch) {
        if (pill.wallpaperOpen && ldWall.item)
            ldWall.item.whTypeChar(ch);
    }

    /**
     * Route a Backspace into the wallhaven field the same way, so a search can
     * be re-edited right after Enter applied a wallpaper. No-op unless the
     * wallpaper surface is open and browsing wallhaven.
     */
    function wallpaperWhBackspace() {
        if (pill.wallpaperOpen && ldWall.item)
            ldWall.item.whBackspace();
    }

    /**
     * Route the first printable keystroke over the open wallpaper strip into
     * the name filter seeded with that character. No-op unless the wallpaper
     * surface is open and not browsing wallhaven.
     */
    function wallpaperType(ch) {
        if (pill.wallpaperOpen && ldWall.item)
            ldWall.item.startSearch(ch);
    }

    readonly property bool wallpaperMenuOpen: pill.wallpaperOpen && ldWall.item !== null && ldWall.item.menuOpen

    /**
     * Move the open wallpaper dropdown's cursor by `dir` rows. No-op unless a
     * dropdown (filter or fit) is open.
     */
    function wallpaperMenuMove(dir) {
        if (pill.wallpaperMenuOpen)
            ldWall.item.menuMove(dir);
    }

    /**
     * Pick the open wallpaper dropdown's currently keyed row. No-op unless a
     * dropdown is open.
     */
    function wallpaperMenuPick() {
        if (pill.wallpaperMenuOpen)
            ldWall.item.menuPick();
    }

    /**
     * Close any open wallpaper dropdown without picking, so Escape backs out
     * of just the menu rather than the whole strip.
     */
    function wallpaperMenuClose() {
        if (pill.wallpaperMenuOpen)
            ldWall.item.menuClose();
    }

    /**
     * Slide the open power surface's keyboard focus by `dir` tiles; +1 is right
     * and -1 is left. No-op unless the power surface is open.
     */
    function powerMove(dir) {
        if (pill.powerOpen && ldPower.item)
            ldPower.item.move(dir);
    }

    /**
     * Enter pressed on the open power surface's focused tile: fires a safe tile
     * at once, latches a destructive tile's heat hold. Returns true when a tile
     * consumed the key. No-op (false) unless the power surface is open.
     */
    function powerPress() {
        return (pill.powerOpen && ldPower.item) ? ldPower.item.pressFocused() : false;
    }

    /**
     * Enter released on the open power surface: drains an unfinished destructive
     * hold so a key let go before the fill completes never confirms.
     */
    function powerRelease() {
        if (pill.powerOpen && ldPower.item)
            ldPower.item.releaseFocused();
    }

    onSurfaceOpenChanged: if (surfaceOpen) {
        pinned = false;
        revealSession = false;
        hoverLatch = false;
        expandLatch = false;
    }

    QtObject {
        id: clock
        readonly property var loc: Qt.locale("en_US")
        readonly property var now: sysClock.date
        readonly property string timeFormat: (Flags.time12h ? "h:mm" : "HH:mm")
            + (Flags.clockSeconds ? ":ss" : "")
            + (Flags.time12h ? " AP" : "")
        readonly property string hhmm: Qt.formatTime(now, timeFormat)
        readonly property string date: loc.toString(now, "ddd d MMM")
        readonly property string weekday: loc.toString(now, "ddd")
    }

    SystemClock {
        id: sysClock
        precision: Flags.clockSeconds ? SystemClock.Seconds : SystemClock.Minutes
    }

    /**
     * Re-sync the clock when the machine wakes from sleep or lid close.
     * SystemClock's internal timer is monotonic, so it does not advance while
     * suspended and the displayed time stays frozen at the pre-sleep minute
     * until that timer drains. systemd-logind broadcasts PrepareForSleep(true)
     * before suspending and PrepareForSleep(false) on wake; on the wake signal
     * we re-enable the clock to force it to re-read the wall clock immediately.
     */
    Process {
        id: sleepWatcher
        running: true
        command: ["dbus-monitor", "--system",
            "type='signal',sender='org.freedesktop.login1',member='PrepareForSleep'"]
        stdout: SplitParser {
            onRead: (line) => {
                if (line.indexOf("boolean false") >= 0) {
                    sysClock.enabled = false;
                    sysClock.enabled = true;
                }
            }
        }
        onExited: () => sleepRespawn.restart()
    }

    Timer {
        id: sleepRespawn
        interval: 2000
        repeat: false
        onTriggered: if (!sleepWatcher.running) sleepWatcher.running = true
    }

    property real morphRadius: (mode === "rest" || mode === "hover" || mode === "game") ? restCorner : openCorner

    /**
     * Rounded to a full stadium: half the bar height rather than the old fixed
     * 18 * s. At uiScale 0.9 that was 16 px on a 36 px bar, so the corners were
     * only just clipped and read as a soft rectangle instead of a rounded bar.
     * Half the height is what makes the ends semicircular, and it tracks the bar
     * through the scale and mode changes on its own instead of needing a
     * constant retuned whenever uiScale moved.
     */
    readonly property real roundRadius: restCorner
    /**
     * Mirror the two metrics the dock needs onto the shell root.
     *
     * These publish the *resting* geometry, not the live `height` and
     * `morphRadius`. The live values are what the pill is animating towards, so
     * publishing those made the dock track the pill mid-morph: opening any
     * surface grew the dock to match, and closing it shrank the dock back. The
     * dock is a fixed-height bar, so it has to be sourced from the resting size
     * or it inherits the pill's expansion.
     *
     * `restSize` is `stripBar` and `roundRadius` is half that height, which is
     * the dock was originally matched against, so the alignment this was added
     * for is unchanged; only the expansion that leaked through is gone.
     *
     * Both are readonly off a static mode table, so they change rarely and the
     * per-frame writes disappear along with the coupling.
     */
    onRestSizeChanged: root.pillBarHeight = restSize.height
    readonly property real restRadius: roundRadius
    onRestRadiusChanged: root.pillBarRadius = restRadius

    /**
     * Target geometry for the non-surface morph modes. Surface sizes come from
     * the `surfaces` descriptor; these are the pill's own modes that have no
     * surface item. Thunks so the properties they read register as live deps of
     * targetSize. osd uses its own content-driven size — the workspace flash
     * fits its dot row (so it stays short even on the wide strip notch) while
     * volume/brightness/record keep their fixed widths. The toast keeps its
     * fixed width and sizes its height to the notification.
     */
    readonly property var modeSize: ({
        toast: () => Qt.size(toastW, toastLoader.item ? toastLoader.item.implicitHeight + 24 * s : restH),
        hover: () => Qt.size(hoverW, hoverH),
        dragOver:    () => Qt.size(dragOverW, dragOverH),
        game:        () => Qt.size(gameW, gameH)
    })

    /**
     * The pill's resting size for the current display mode.
     */
    readonly property size restSize: stripBar
        ? Qt.size(Math.max(restW, stripFaceW), restH)
        : Qt.size(Math.max(restW, restRow.implicitWidth + 36 * s), restH)

    readonly property size targetSize: {
        const sf = surfaces[mode];
        if (sf)
            return sf.size();
        const f = modeSize[mode];
        if (f)
            return f();
        return restSize;
    }
    readonly property real targetW: targetSize.width
    readonly property real targetH: targetSize.height

    width: targetW
    height: targetH

    /**
     * How settled the pill is into its target geometry: 0 while the morph is far
     * away, 1 once it arrives. Content opacities key off this, not their own
     * timers, so a surface fades in as the pill reaches full size, never over a
     * half-grown pill.
     */
    readonly property real morphCloseness: {
        const d = Math.max(Math.abs(width - targetW), Math.abs(height - targetH));
        return 1 - Math.min(1, d / (110 * s));
    }

    /**
     * Gate the soul bead until the hover morph has arrived and its icons exist.
     * Fire it earlier and the bead aims at anchors that aren't laid out yet.
     * Latched so small width changes inside hover (workspace dot growing, tray
     * icons appearing) don't flicker the bead off.
     */
    property bool hoverSoulGate: false
    readonly property bool hoverArrived: mode === "hover" && morphCloseness > 0.55
    onHoverArrivedChanged: if (hoverArrived) hoverSoulGate = true

    /**
     * Rest and hover sit a few dozen pixels apart, so the 420ms morph is nearly
     * all settle tail on that hop and reads sluggish. Both endpoints in the
     * rest/hover pair get the shorter glide; every real surface morph keeps the
     * full duration.
     */
    property string lastMode: "rest"
    property bool hoverHop: false

    onModeChanged: {
        hoverHop = (mode === "hover" || mode === "rest") && (lastMode === "hover" || lastMode === "rest");
        lastMode = mode;
        if (mode !== "hover") {
            hoverSoulGate = false;
            soulTarget = "";
            soulWsIndex = -1;
        }
    }
    onHoverSoulGateChanged: if (hoverSoulGate) kanjiFlashAnim.restart()

    property string soulTarget: ""
    property int soulWsIndex: -1

    property real kanjiFlash: 0

    SequentialAnimation {
        id: kanjiFlashAnim
        NumberAnimation { target: pill; property: "kanjiFlash"; to: 1; duration: 90; easing.type: Easing.OutCubic }
        NumberAnimation { target: pill; property: "kanjiFlash"; to: 0; duration: 320; easing.type: Easing.OutCubic }
    }

    Behavior on width { NumberAnimation { id: morphAnimW; duration: pill.hoverHop ? Motion.glide : Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }
    Behavior on height { NumberAnimation { id: morphAnimH; duration: pill.hoverHop ? Motion.glide : Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }
    Behavior on morphRadius { NumberAnimation { id: morphAnimR; duration: pill.hoverHop ? Motion.glide : Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }

    /**
     * True while any morph axis animates. The body's effect layer (live drop
     * shadow) re-renders its offscreen buffer at every size step, on every
     * monitor, so it is the top per-frame cost of a morph; dropping the shadow
     * mid-flight and restoring it on settle keeps the morph cheap (issue #20).
     */
    readonly property bool morphing: morphAnimW.running || morphAnimH.running || morphAnimR.running

    LiquidGlass {
        id: bud
        readonly property bool shown: pill.mode === "hover" && pill.hasMedia
        property real budR: (budArea.containsMouse ? 15 : 12) * pill.s
        width: budR * 2
        height: budR * 2
        radius: budR
        x: pill.width - budR
        anchors.verticalCenter: parent.verticalCenter
        visible: opacity > 0.01
        opacity: shown ? 1 : 0
        style: "regular"
        legacyOpacity: Flags.pillOpacity
        accent: 0.05
        sheenScale: (budArea.containsMouse ? 1.3 : 1)
        hovered: budArea.containsMouse
        Behavior on budR { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
        Behavior on opacity { NumberAnimation { duration: Motion.standard } }

        Canvas {
            id: budBead
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: 3 * pill.s
            width: 18 * pill.s
            height: 18 * pill.s
            onPaint: {
                const ctx = getContext("2d");
                ctx.reset();
                const c = width / 2;
                const R = (budArea.containsMouse ? 5.2 : 4) * pill.s;
                const hg = ctx.createRadialGradient(c - R * 0.32, c - R * 0.38, 0, c, c, R);
                hg.addColorStop(0, Theme.flameInk);
                hg.addColorStop(0.55, Theme.vermLit);
                hg.addColorStop(0.92, Theme.verm);
                hg.addColorStop(1, Theme.flameEmber);
                ctx.beginPath();
                ctx.arc(c, c, R, 0, 7);
                ctx.fillStyle = hg;
                ctx.fill();
                ctx.beginPath();
                ctx.ellipse(c - R * 0.62, c - R * 0.66, R * 0.6, R * 0.36);
                ctx.fillStyle = "rgba(255,246,240,0.6)";
                ctx.fill();
            }
        }

        MouseArea {
            id: budArea
            anchors.fill: parent
            enabled: bud.shown
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.requestSurface("media")
            onContainsMouseChanged: budBead.requestPaint()
        }
    }

    /**
     * The flagship slab: translucent regular glass — a palette-tinted slab
     * over the transparent window, the exact legacy flat gradient (scaled by
     * the user's own translucency) when glass is off. Hover lifts sheen, an
     * open surface adds a touch more accent to the fill.
     */
    LiquidGlass {
        id: body
        anchors.fill: parent

        /**
         * Corner flatness rides the morph curve so docking into the game bar
         * squares the corners as one continuous shape change instead of a snap.
         * The strip docks flush to the screen edge, so its top corners square
         * off against the edge while the bottom corners stay rounded.
         */
        property real gameFlat: pill.mode === "game" ? 1 : 0
        Behavior on gameFlat { NumberAnimation { duration: Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }
        property real topFlat: (pill.mode === "game" || pill.stripBar) ? 1 : 0
        Behavior on topFlat { NumberAnimation { duration: Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }

        radius: pill.morphRadius
        topLeftRadius: pill.morphRadius * (1 - topFlat)
        topRightRadius: pill.morphRadius * (1 - topFlat)
        bottomLeftRadius: pill.morphRadius * (1 - gameFlat)
        bottomRightRadius: pill.morphRadius * (1 - gameFlat)

        style: "regular"
        legacyOpacity: Flags.pillOpacity
        accent: 0.05
        veil: 0.06
        // Sit on the theme's own background rather than the generated card
        // ramp, so the pill's interior is the desktop's colour.
        themeBackgroundFill: true
        sheenScale: pill.mode === "hover" ? 1.35 : 1
        hovered: pill.mode === "hover"
        pressed: pill.dragActive
        active: pill.surfaceOpen

        /**
         * The live drop shadow keeps an offscreen render of the whole body on
         * every monitor. Drag it off entirely while the pill is auto-hidden
         * off-screen (nobody sees the shadow there) — the layer's FBO and the
         * per-frame update only exist while the pill is actually visible.
         */
        layer.enabled: !pill.morphing && !pill.hidden
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, Theme.shadowOpacity)
            shadowBlur: 0.7
            shadowVerticalOffset: 3 * pill.s
        }
    }

    /**
     * Rest anchor for Ame: the 時 kanji centre. The idle outline condenses into
     * the bead here before it moves.
     */
    readonly property point wakePoint: {
        void pill.width;
        void pill.height;
        return restClock.mapToItem(pill, restClock.width / 2, restClock.height / 2);
    }

    /**
     * Bead target while hovered. soulTarget is a sticky key written by the hover
     * sources: the bead parks on the last focused dot or icon and glides to the
     * next, so crossing a gap between targets doesn't snap it back to the active
     * workspace. Pill geometry is voided so the anchor follows the hover morph,
     * the point stays live.
     */
    readonly property point soulPoint: {
        void pill.width;
        void pill.height;
        const drop = 12 * pill.s;
        const native = pill.iconFor(soulTarget);
        if (native)
            return native.mapToItem(pill, native.width / 2, native.height + drop * 0.55);
        if (soulTarget === "ws" && soulWsIndex >= 0) {
            void ws.activeName;
            void ws.width;
            const p = ws.mapToItem(pill, ws.slotCenterX(soulWsIndex), ws.height / 2);
            return Qt.point(p.x, p.y + drop);
        }
        return ws.mapToItem(pill, ws.activeDotPoint.x, ws.activeDotPoint.y + drop);
    }

    /**
     * Which open surface owns Ame's anchor. Each surface exports its own
     * `ameForm`/`amePoint`; the pill picks the open surface's `ame` from the
     * descriptor and maps it. Null = nothing open (or a surface with no anchor,
     * e.g. wallpaper), so Ame falls back to the pill's own hover/wake anchor.
     */
    readonly property var ameSurface: (surfaceOpen && surfaces[mode] !== undefined)
        ? surfaces[mode].ame() : null

    Ame {
        id: ame
        anchors.fill: parent
        s: pill.s
        heat: (pill.powerOpen && ldPower.item) ? ldPower.item.holdProgress : 0
        wake: pill.wakePoint
        wickDir: pill.powerOpen ? 1 : -1
        form: pill.ameSurface ? pill.ameSurface.ameForm
            : (pill.mode === "hover" && pill.hoverSoulGate ? "soul" : "off")
        point: pill.ameSurface
            ? Qt.point(pill.ameSurface.x + pill.ameSurface.amePoint.x,
                       pill.ameSurface.y + pill.ameSurface.amePoint.y)
            : (pill.mode === "hover" ? pill.soulPoint : pill.wakePoint)
    }

    /**
     * Extra input width past the pill's right edge while the media bud sticks
     * out there, so the window mask covers the bud's outer half. pill.hovered is
     * fed by a window-level HoverHandler in shell.qml: pointer events only exist
     * inside the input mask, so "window hovered" means "pointer over the pill (or
     * bud)". That sidesteps the per-item hover flicker the child MouseAreas and
     * the centred width morph would otherwise cause.
     */
    readonly property real inputPadRight: bud.shown ? bud.budR + 2 * s : 0

    onHoveredChanged: {
        if (hovered && pill.mode !== "game") {
            if (!Flags.autoHide && Flags.expandTo === "media" && pill.hasMedia
                && !pill.surfaceOpen && !pill.dragActive
                && bootSettled && !toastActive) {
                /* expandTo "media" with auto-hide off: a hover grows the pill
                 * into the player itself instead of the icon face. Auto-hide
                 * still reveals the normal pill; a click opens the player
                 * (TapHandler below). Game mode never hands the bar to the
                 * player, or the exit chip would be buried under it. */
                pill.requestSurface("media");
            } else if (Flags.autoHide && !revealSession && !expanded && !surfaceOpen) {
                revealSession = true;
                revealTimer.stop();
            } else if (bootSettled && !revealSession && !toastActive) {
                /* A toast owns the pill; hovering it must not latch an expansion
                 * underneath, or the pill stays open once the toast is dismissed. */
                hoverLatch = true;
                graceTimer.stop();
            }
        } else {
            if (!pinned && !surfaceOpen && !revealSession)
                hoverLatch = false;
            graceTimer.restart();
            revealTimer.start();
        }
    }

    Timer {
        id: graceTimer
        interval: 300
        onTriggered: {
            if (pill.morphCloseness < 0.95) {
                graceTimer.restart();
                return;
            }
            pill.hoverLatch = false;
            // Only ever reached from the not-hovered branch of
            // `onHoveredChanged`, so this is "the pointer settled outside"
            // and not a timer that happens to expire.
            pill.expandLatch = false;
        }
    }

    /**
     * Ends a reveal session once the pointer has left the reveal strip and the
     * collapsed pill (and nothing else holds the pill open). The interval is a
     * grace window so the strip -> pill handoff never drops the session mid-move.
     */
    Timer {
        id: revealTimer
        interval: 350
        onTriggered: {
            if (!pill.hovered && !pill.pinned && !pill.surfaceOpen)
                pill.revealSession = false;
        }
    }

    TapHandler {
        enabled: !pill.surfaceOpen && pill.mode !== "game"
        gesturePolicy: TapHandler.WithinBounds
        onTapped: {
            if (pill.expandLatch) {
                pill.expandLatch = false;
                pill.hoverLatch = false;
                return;
            }
            if (Flags.expandTo === "media" && pill.hasMedia) {
                pill.requestSurface("media");
            } else if (Flags.autoHide) {
                pill.hoverLatch = !pill.hoverLatch;
            } else {
                pill.pinned = !pill.pinned;
            }
        }
    }

    /**
     * Right-click toggles the media player from anywhere on the pill: on the
     * collapsed pill it pops the now-playing surface open, and on the open
     * media surface it dismisses back to the clock. Other surfaces are left to
     * their own clicks and the modal backdrop.
     */
    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: (!pill.surfaceOpen || pill.mediaOpen) && pill.mode !== "game"
        gesturePolicy: TapHandler.WithinBounds
        onTapped: {
            if (pill.mediaOpen)
                pill.requestClose();
            else
                pill.requestSurface("media");
        }
    }

    property var installQueue: []

    function localPath(url) {
        var s = String(url);
        if (s.indexOf("file://") === 0)
            s = s.substring(7);
        return decodeURIComponent(s);
    }

    readonly property var dropExt: /\.(appimage|deb|rpm|flatpakref|zip|tgz|txz|tbz2|ttf|otf|png|jpe?g|webp)$|\.(pkg\.)?tar\.(gz|xz|bz2|zst)$/i

    function droppablePaths(urls) {
        var out = [];
        for (var i = 0; i < urls.length; i++)
            if (pill.dropExt.test(String(urls[i])))
                out.push(pill.localPath(urls[i]));
        return out;
    }

    function dropLabel(urls) {
        var p = pill.localPath(urls.length ? urls[0] : "");
        return p.substring(p.lastIndexOf("/") + 1).replace(pill.dropExt, "");
    }

    property bool installedAny: false
    property bool installedApp: false
    property bool installFailed: false
    property string installKind: "app"
    property string installAction: "new"
    property string installLine: ""
    property string installProto: ""
    property string installPct: ""
    property int installSeconds: 0

    function runNextInstall() {
        if (pill.installQueue.length === 0) {
            pill.dragStage = pill.installedAny ? "done" : "fail";
            (pill.installedAny ? dropDoneTimer : dropBadTimer).restart();
            return;
        }
        var next = pill.installQueue.shift();
        pill.dragName = next.substring(next.lastIndexOf("/") + 1).replace(pill.dropExt, "");
        pill.installLine = "";
        pill.installProto = "";
        pill.installPct = "";
        installProc.command = ["bash", Config.hyprPath("scripts", "app-install.sh"), "install", next];
        installProc.running = true;
    }

    /**
     * Streams installer stdout instead of collecting it: slow backends (flatpak
     * runtime pulls, pacman) narrate their steps, and the drop face mirrors the
     * newest line live. The machine-readable result is the one tab-separated
     * kind-prefixed line, fished out of the stream as it passes.
     */
    Process {
        id: installProc
        stdout: SplitParser {
            onRead: (data) => {
                var seg = data.split("\r").pop().replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "").trim();
                if (seg.length === 0)
                    return;
                if (/^(app|native|font|wallpaper)\t/.test(seg)) {
                    pill.installProto = seg;
                } else {
                    pill.installLine = seg;
                    var pct = seg.match(/(\d{1,3})\s*%/);
                    if (pct && Number(pct[1]) <= 100)
                        pill.installPct = pct[1] + "%";
                }
            }
        }
        onExited: (exitCode) => {
            if (exitCode === 0 && pill.installProto.length > 0) {
                pill.installedAny = true;
                var parts = pill.installProto.split("\t");
                pill.installKind = parts[0];
                pill.installAction = parts[2];
                if (parts[0] === "app" || parts[0] === "native")
                    pill.installedApp = true;
                if (parts[0] === "font" && parts.length >= 4)
                    droppedFont.source = "file://" + parts[3];
            } else {
                pill.installFailed = true;
            }
            pill.runNextInstall();
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: pill.dragStage === "installing"
        onTriggered: pill.installSeconds++
    }

    /**
     * Registers a just-dropped font in this running process; the fontconfig
     * cache alone only reaches apps started later. Ready -> the font picker's
     * family list refreshes and the new face shows up without a restart.
     */
    FontLoader {
        id: droppedFont
        onStatusChanged: if (status === FontLoader.Ready) Theme.refreshFonts()
    }

    Timer {
        id: dropDoneTimer
        interval: 1100
        onTriggered: {
            pill.dragActive = false;
            pill.dragStage = "";
            if (pill.installedApp)
                pill.requestSurface("launcher");
        }
    }

    Timer {
        id: dropBadTimer
        interval: 1300
        onTriggered: {
            pill.dragActive = false;
            pill.dragStage = "";
        }
    }

    /**
     * Shared drop lifecycle. Entered during a drag (either over the pill itself
     * or over the auto-hide reveal strip in shell.qml), dropped at release.
     * Extracted so the hidden pill's reveal strip can hand drops straight into
     * the same install flow the resting pill uses.
     */
    function dropEntered(urls) {
        pill.dragActive = true;
        pill.dragStage = pill.droppablePaths(urls).length > 0 ? "hover" : "bad";
        pill.dragName = pill.dropLabel(urls);
    }

    function dropExited() {
        if (pill.dragStage === "hover" || pill.dragStage === "bad") {
            pill.dragActive = false;
            pill.dragStage = "";
        }
    }

    function dropDropped(urls) {
        var files = pill.droppablePaths(urls);
        if (files.length === 0) {
            pill.dragActive = true;
            pill.dragStage = "bad";
            pill.dragName = pill.dropLabel(urls);
            dropBadTimer.restart();
            return;
        }
        pill.dragActive = true;
        pill.dragStage = "installing";
        pill.installedAny = false;
        pill.installedApp = false;
        pill.installFailed = false;
        pill.installKind = "app";
        pill.installAction = "new";
        pill.installSeconds = 0;
        pill.installQueue = files;
        pill.runNextInstall();
    }

    /**
     * File drops land only on the resting pill; an open surface turns the pill
     * into a fullscreen modal that swallows the drag before it can start.
     * app-install.sh routes each drop by type (apps install, fonts land in the
     * font dir, images become the wallpaper), anything else flashes a rejection.
     */
    DropArea {
        anchors.fill: parent
        enabled: !pill.surfaceOpen && pill.dragStage !== "installing" && pill.dragStage !== "done"
        keys: ["text/uri-list"]
        onEntered: (drag) => {
            drag.acceptProposedAction();
            pill.dropEntered(drag.urls);
        }
        onExited: pill.dropExited()
        onDropped: (drop) => {
            drop.acceptProposedAction();
            pill.dropDropped(drop.urls);
        }
    }

    /**
     * Drop-zone face: corner brackets frame a stage glyph and label that walk
     * from "drop to install" through the spinner to a checkmark. Shares the morph
     * fade of the other pill faces, so it grows in as the pill reaches its size.
     */
    Item {
        id: dragOverView
        anchors.fill: parent
        anchors.margins: 11 * pill.s
        enabled: pill.mode === "dragOver"
        opacity: pill.mode === "dragOver" ? Math.pow(pill.morphCloseness, 1.2) : 0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }

        readonly property color accent: (pill.dragStage === "bad" || pill.dragStage === "fail") ? "#e0533f" : Theme.vermLit
        readonly property real brLen: 15 * pill.s
        readonly property real brThick: 2 * pill.s

        Repeater {
            model: [[0, 0], [1, 0], [0, 1], [1, 1]]
            delegate: Item {
                id: corner
                required property var modelData
                readonly property bool rightSide: modelData[0] === 1
                readonly property bool bottomSide: modelData[1] === 1
                x: rightSide ? dragOverView.width - dragOverView.brLen : 0
                y: bottomSide ? dragOverView.height - dragOverView.brLen : 0
                width: dragOverView.brLen
                height: dragOverView.brLen

                Rectangle {
                    width: dragOverView.brLen
                    height: dragOverView.brThick
                    radius: dragOverView.brThick / 2
                    color: dragOverView.accent
                    anchors.top: corner.bottomSide ? undefined : parent.top
                    anchors.bottom: corner.bottomSide ? parent.bottom : undefined
                    anchors.left: corner.rightSide ? undefined : parent.left
                    anchors.right: corner.rightSide ? parent.right : undefined
                }
                Rectangle {
                    width: dragOverView.brThick
                    height: dragOverView.brLen
                    radius: dragOverView.brThick / 2
                    color: dragOverView.accent
                    anchors.top: corner.bottomSide ? undefined : parent.top
                    anchors.bottom: corner.bottomSide ? parent.bottom : undefined
                    anchors.left: corner.rightSide ? undefined : parent.left
                    anchors.right: corner.rightSide ? parent.right : undefined
                }
            }
        }

        Column {
            anchors.centerIn: parent
            width: parent.width - 44 * pill.s
            spacing: 7 * pill.s

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 26 * pill.s
                height: 26 * pill.s

                GlyphIcon {
                    id: dragGlyph
                    anchors.fill: parent
                    stroke: 2
                    color: dragOverView.accent
                    name: (pill.dragStage === "bad" || pill.dragStage === "fail") ? "close"
                        : (pill.dragStage === "installing" ? "reboot"
                        : (pill.dragStage === "done" ? "check" : "download"))

                    RotationAnimation on rotation {
                        running: pill.dragStage === "installing"
                        loops: Animation.Infinite
                        from: 0
                        to: 360
                        duration: 900
                    }
                    onNameChanged: if (pill.dragStage !== "installing") rotation = 0
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: pill.dragStage === "bad" ? "Can't install this"
                    : (pill.dragStage === "fail" ? "Install failed"
                    : (pill.dragStage === "installing" ? ("Installing"
                        + (pill.installPct.length > 0 ? " " + pill.installPct : "")
                        + (pill.installSeconds >= 3 ? "  " + Math.floor(pill.installSeconds / 60) + ":" + String(pill.installSeconds % 60).padStart(2, "0") : ""))
                    : (pill.dragStage === "done" ? (pill.installFailed ? "Installed, some failed"
                        : (!pill.installedApp && pill.installKind === "wallpaper" ? "Wallpaper set"
                        : (!pill.installedApp && pill.installKind === "font" ? "Font installed"
                        : (pill.installAction === "updated" ? "Updated"
                        : (pill.installAction === "reinstalled" ? "Reinstalled" : "Installed")))))
                    : "Drop to install")))
                color: Theme.cream
                font.family: Theme.font
                font.pixelSize: 13 * pill.s
                font.weight: Font.Medium
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: pill.dragStage === "installing" && pill.installLine.length > 0 ? pill.installLine : pill.dragName
                color: Theme.subtle
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                elide: Text.ElideMiddle
                maximumLineCount: 1
            }
        }
    }

    /**
     * Game-mode face: the pill docks into a flush top bar carrying only the clock
     * and, when something plays, the current track. Everything else the desktop
     * usually shows is deliberately gone.
     */
    Item {
        id: gameBar
        anchors.fill: parent
        enabled: pill.mode === "game"
        opacity: pill.mode === "game" ? Math.pow(pill.morphCloseness, 1.2) : 0
        visible: opacity > 0.01

        Behavior on opacity { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 18 * pill.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9 * pill.s
            opacity: Players.has ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 26 * pill.s
                height: 26 * pill.s
                radius: 7 * pill.s
                color: Theme.tileBg
                clip: true
                Image {
                    id: artImg
                    anchors.fill: parent
                    source: Players.artUrl
                    sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }
                /** No art from the player: the source's own app icon stands in. */
                Image {
                    anchors.centerIn: parent
                    width: parent.width - 8 * pill.s
                    height: parent.height - 8 * pill.s
                    source: Players.appIconFor(Players.active)
                    sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    visible: artImg.status !== Image.Ready && status === Image.Ready
                }
            }
            Column {
                anchors.verticalCenter: parent.verticalCenter
                AltText {
                    text: Players.title
                    maxWidth: 220 * pill.s
                    font.family: Theme.font
                    font.pixelSize: 12.5 * pill.s
                    font.weight: Font.Medium
                }
                AltText {
                    text: Players.artist
                    maxWidth: 220 * pill.s
                    visible: text.length > 0
                    font.family: Theme.font
                    font.pixelSize: 10.5 * pill.s
                }
            }
        }

        AltText {
            anchors.centerIn: parent
            text: clock.hhmm
            font.family: Theme.font
            font.pixelSize: 16 * pill.s
            font.weight: Font.DemiBold
            font.features: ({ "tnum": 1 })
        }

        /**
         * Volume/brightness/mic feedback stays visible while gaming as a compact
         * chip on the bar's right, since the full OSD face is parked behind
         * game mode in the mode ladder. Notifications stay suppressed.
         */
        Rectangle {
            id: exitChip
            anchors.right: parent.right
            anchors.rightMargin: 14 * pill.s
            anchors.verticalCenter: parent.verticalCenter
            width: 26 * pill.s
            height: 26 * pill.s
            radius: 8 * pill.s
            color: exitHover.hovered ? Theme.frameBg : Qt.alpha(Theme.tileBg, 0.45)
            border.width: 1
            border.color: exitHover.hovered ? Qt.alpha(Theme.onGlow, 0.5) : Theme.border
            Behavior on color { ColorAnimation { duration: Motion.fast } }

            GlyphIcon {
                anchors.centerIn: parent
                width: 15 * pill.s
                height: 15 * pill.s
                name: "gamepad"
                color: exitHover.hovered ? Theme.vermLit : Theme.iconDim
                stroke: 1.7
            }
            HoverHandler {
                id: exitHover
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Flags.gameMode = false
            }
            Tooltip {
                s: pill.s
                placement: "below"
                align: "right"
                title: "Exit game mode"
                desc: "Restore the desktop"
                show: exitHover.hovered
            }
        }

        Row {
            anchors.right: exitChip.left
            anchors.rightMargin: 9 * pill.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9 * pill.s
            opacity: osd.flashing && (osd.kind === "volume" || osd.kind === "brightness" || osd.kind === "mic") ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }

            GlyphIcon {
                anchors.verticalCenter: parent.verticalCenter
                width: 14 * pill.s
                height: 14 * pill.s
                name: osd.kind === "brightness" ? "sun"
                    : (osd.kind === "mic" ? (osd.micMuted ? "mic-off" : "mic")
                    : (osd.muted ? "speaker-off" : "speaker"))
                color: (osd.kind === "volume" && osd.muted) || (osd.kind === "mic" && osd.micMuted) ? Theme.dim : Theme.iconDim
                stroke: 1.7
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 64 * pill.s
                height: 3 * pill.s
                radius: 1.5 * pill.s
                color: Theme.threadBg

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width * (osd.kind === "brightness" ? osd.brightness
                        : (osd.kind === "mic" ? osd.micVolume : osd.volume))
                    radius: parent.radius
                    color: (osd.kind === "volume" && osd.muted) || (osd.kind === "mic" && osd.micMuted) ? Theme.vermDim : Theme.vermLit
                    Behavior on width { NumberAnimation { duration: Motion.fast } }
                }
            }

            AltText {
                anchors.verticalCenter: parent.verticalCenter
                text: osd.kind === "mic"
                    ? (osd.micMuted ? "off" : Math.round(osd.micVolume * 100) + "%")
                    : Math.round((osd.kind === "brightness" ? osd.brightness : osd.volume) * 100) + "%"
                font.family: Theme.font
                font.pixelSize: 10.5 * pill.s
                font.weight: Font.DemiBold
                font.features: ({ "tnum": 1 })
            }
        }
    }

    Item {
        id: rest
        anchors.fill: parent
        opacity: ((pill.expanded && !pill.pluginPopupOpen) || pill.dragActive || pill.mode === "game" || pill.mode === "toast") ? 0 : Math.pow(pill.morphCloseness, 1.5)
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: pill.mode === "rest" ? Motion.fast : Math.round(260 * Motion.mult) } }

        /**
         * Strip face: one compact pill of media + status hanging from the top
         * edge. Media art and title lead, then a live cava spark, the red
         * recording chip, and finally weekday, time, workspace, layout and
         * battery. Sections fold (visualizer, then media) as the width budget
         * tightens; the row is centred so the pill hugs the screen top like a
         * notch. Width is pill.stripFaceW, not the row's implicit width, so the
         * elided title never inflates the pill.
         *
         * The active-workspace number is served by the hover `ws` instance
         * (Phase 4 dedupe): it is always alive, so the number is current the
         * moment this mode is shown, and its `enabled: hover.live` only gates
         * the dot MouseAreas, never its hyprctl watcher.
         */
        Row {
            id: stripFace
            // Hides while a surface is open: this is the resting bar, and in
            // strip mode it is far wider than the card-sized body a surface
            // morphs the pill into, so leaving it up overflows the pill and
            // covers the surface.
            visible: pill.specialView === "" && pill.stripBar && (!pill.surfaceOpen || pill.pluginPopupOpen)
            anchors.centerIn: parent
            spacing: pill.stripGap

            Rectangle {
                id: stripArt
                anchors.verticalCenter: parent.verticalCenter
                visible: pill.stripMedia
                width: pill.stripArtW
                height: pill.stripArtW
                radius: 5 * pill.s
                color: Theme.tileBg
                clip: true
                Image {
                    id: stripArtImg
                    anchors.fill: parent
                    source: Players.artUrl
                    sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }
                /** No art from the player: the source's own app icon stands in. */
                Image {
                    id: stripArtIcon
                    anchors.centerIn: parent
                    width: parent.width - 8 * pill.s
                    height: parent.height - 8 * pill.s
                    source: Players.appIconFor(Players.active)
                    sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    visible: stripArtImg.status !== Image.Ready && status === Image.Ready
                }
            }

            AltText {
                id: stripTitle
                anchors.verticalCenter: parent.verticalCenter
                visible: pill.stripMedia
                text: Players.title
                maxWidth: pill.stripTitleW
                font.family: Theme.font
                font.pixelSize: 12.5 * pill.s
                font.weight: Font.Medium
            }

            MusicBars {
                id: stripViz
                anchors.verticalCenter: parent.verticalCenter
                visible: pill.stripMedia && Cava.active
                s: pill.s
                span: 14
            }

            AltText {
                id: stripDay
                anchors.verticalCenter: parent.verticalCenter
                text: clock.weekday
                font.family: Theme.font
                font.pixelSize: 12 * pill.s
                font.weight: Font.DemiBold
            }
            AltText {
                id: stripTime
                anchors.verticalCenter: parent.verticalCenter
                text: clock.hhmm
                font.family: Theme.font
                font.pixelSize: 17 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            AltText {
                id: stripWs
                anchors.verticalCenter: parent.verticalCenter
                text: ws.activeWs
                font.family: Theme.font
                font.pixelSize: 12 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            AltText {
                id: stripLay
                anchors.verticalCenter: parent.verticalCenter
                text: kbLayout.code
                font.family: Theme.font
                font.pixelSize: 12 * pill.s
                font.weight: Font.DemiBold
            }
            Row {
                id: stripBat
                anchors.verticalCenter: parent.verticalCenter
                visible: Battery.present
                spacing: 4 * pill.s
                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Battery.charging
                    width: 11 * pill.s
                    height: 11 * pill.s
                    name: "bolt"
                    color: Battery.low ? Theme.vermLit : Theme.dim
                    stroke: 1.6
                }
                AltText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Battery.pct + "%"
                    font.family: Theme.font
                    font.pixelSize: 12 * pill.s
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
        }

        TextMetrics {
            id: stripTitleMetrics
            text: Players.title
            font.family: Theme.font
            font.pixelSize: 12.5 * pill.s
            font.weight: Font.Medium
        }

        Row {
            id: restRow
            visible: !pill.stripBar
            anchors.centerIn: parent
            spacing: 9 * pill.s
            Item {
                id: restClock
                /**
                 * This slot is shared by the clock icon and the
                 * music waveform — exactly one is drawn at a time. When neither
                 * is (clockIcon off, visualiser idle) the item is hidden
                 * outright, so the Row drops it *and* its spacing. Only zeroing
                 * the width would leave the Row's 9px gap behind and leave the
                 * time sitting a few pixels right of centre.
                 */
                readonly property bool slotUsed: barsOn || Flags.clockIcon
                visible: pill.specialView === "" && Flags.mainDisplay === "minimal" && slotUsed
                anchors.verticalCenter: parent.verticalCenter
                width: clockGlyph.width
                height: clockGlyph.height

                /** Audio leaving the speakers flips the clock face over to the live waveform. */
                readonly property bool barsOn: Flags.musicViz && Cava.active

                GlyphIcon {
                    id: clockGlyph
                    anchors.centerIn: parent
                    opacity: (Flags.clockIcon && !restClock.barsOn) ? 1 : 0
                    visible: opacity > 0
                    width: pill.iconCell
                    height: pill.iconCell
                    name: "clock"
                    color: Theme.cream
                    stroke: 1.7
                    Behavior on opacity { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }
                }

                MusicBars {
                    id: musicBars
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: clockGlyph.bottom
                    s: pill.s
                    /** Culled (not just faded) while the waveform is off, so the
                     *  per-bar easing anims don't keep ticking at 60fps invisibly. */
                    visible: restClock.barsOn
                    opacity: restClock.barsOn ? 1 : 0
                    scale: restClock.barsOn ? 1 : 0.7
                    Behavior on opacity { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }
                    Behavior on scale { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }
                }
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "minimal"
                anchors.verticalCenter: parent.verticalCenter
                text: clock.hhmm
                font.family: Theme.font
                font.pixelSize: 16 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "classic"
                anchors.verticalCenter: parent.verticalCenter
                text: clock.date
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                font.weight: Font.DemiBold
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "classic"
                anchors.verticalCenter: parent.verticalCenter
                text: clock.hhmm
                font.family: Theme.font
                font.pixelSize: 16 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "system"
                anchors.verticalCenter: parent.verticalCenter
                text: clock.weekday
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                font.weight: Font.DemiBold
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "system"
                anchors.verticalCenter: parent.verticalCenter
                text: clock.hhmm
                font.family: Theme.font
                font.pixelSize: 15 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "system"
                    && ws.activeWs !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: ws.activeWs
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
            }
            AltText {
                visible: pill.specialView === "" && Flags.mainDisplay === "system"
                anchors.verticalCenter: parent.verticalCenter
                text: kbLayout.code
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                font.weight: Font.DemiBold
            }
            Row {
                visible: pill.specialView === "" && Flags.mainDisplay === "system"
                    && Battery.present
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3 * pill.s
                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Battery.charging
                    width: 10 * pill.s
                    height: 10 * pill.s
                    name: "bolt"
                    color: Battery.low ? Theme.vermLit : Theme.dim
                    stroke: 1.6
                }
                AltText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Battery.pct + "%"
                    font.family: Theme.font
                    font.pixelSize: 11 * pill.s
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
            AltText {
                visible: pill.specialView !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: pill.specialView
                font.family: Theme.font
                font.pixelSize: 16 * pill.s
                font.weight: Font.DemiBold
            }
        }
    }

    KbLayout {
        id: kbLayout
    }

    Item {
        id: hover
        anchors.fill: parent
        opacity: pill.mode === "hover" ? Math.pow(pill.morphCloseness, 1.2) : 0
        visible: true
        Behavior on opacity { NumberAnimation { duration: pill.mode === "hover" ? Motion.fast : 40 } }

        readonly property bool live: pill.mode === "hover"

        Row {
            id: hoverRow
            anchors.centerIn: parent
            spacing: 20 * pill.s

            Workspaces {
                id: ws
                anchors.verticalCenter: parent.verticalCenter
                width: implicitWidth
                screenName: pill.screenName
                s: pill.s
                gap: 8 * pill.s
                enabled: hover.live
                onHoverIndexChanged: if (hoverIndex >= 0) {
                    pill.soulTarget = "ws";
                    pill.soulWsIndex = hoverIndex;
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 22 * pill.s
                color: Theme.hair
            }

            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: hoverClock.implicitWidth
                height: hoverClock.implicitHeight

                Column {
                    id: hoverClock
                    anchors.centerIn: parent
                    spacing: 2 * pill.s
                    AltText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: clock.hhmm
                        font.family: Theme.font
                        font.pixelSize: 18 * pill.s
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                    }
                    AltText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: clock.date
                        letterSpacing: 1.6 * pill.s
                        font.family: Theme.font
                        font.pixelSize: 8.5 * pill.s
                        font.weight: Font.Medium
                        font.capitalization: Font.AllUppercase
                    }
                }

                MouseArea {
                    anchors.centerIn: parent
                    width: hoverClock.implicitWidth + 22 * pill.s
                    height: hoverClock.implicitHeight + 10 * pill.s
                    enabled: hover.live
                    cursorShape: Qt.PointingHandCursor
                    onClicked: pill.requestSurface("calendar")
                }

                HoverHandler {
                    id: clockTip
                }
                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: "Calendar"
                    desc: "Date and agenda"
                    show: clockTip.hovered && hover.live
                }
                // better: tooltip calendar
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 22 * pill.s
                color: Theme.hair
            }

            Row {
                id: statusRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12 * pill.s

                Repeater {
                    id: stripCells
                    model: StripLayout.resolved

                    delegate: StripCell {
                        required property var modelData

                        anchors.verticalCenter: statusRow.verticalCenter

                        kind: modelData ? modelData.kind : ""
                        cellId: modelData ? modelData.id : ""
                        pluginId: modelData ? modelData.id : ""
                        cellComponent: pill.cellComponentFor(modelData)
                        s: pill.s
                        hoverLive: hover.live
                        barHeightOverride: pill.height
                        barWidthOverride: pill.width
                    }
                }
            }
        }
    }


    // Native strip cells: one movable unit per Component. Each root
    // exposes `cellPresent` -- whether it wants to paint right now. The
    // StripCell slot tracks that flag instead of the item's `visible`,
    // because the Loader mirrors its own visibility back onto the loaded
    // item, so `item.visible` can never drive the parent.
    Component {
        id: cellTray
                Row {
                    spacing: 12 * pill.s
                    property bool cellPresent: true

                                    MinimizedTray {
                                        id: minimized
                                        anchors.verticalCenter: parent.verticalCenter
                                        s: pill.s
                                        screenName: pill.screenName
                                        enabled: hover.live
                                        visible: count > 0
                                    }
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: minimized.count > 0
                                        width: 1
                                        height: pill.iconCell
                                        color: Theme.hair
                                        opacity: 0.7
                                    }
                                    Tray {
                                        anchors.verticalCenter: parent.verticalCenter
                                        s: pill.s
                                        barWindow: pill.barWindow
                                        enabled: hover.live
                                    }
                }
    }

    Component {
        id: cellWeather
                Item {
                    id: weatherGlance
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Weather.ready && !Plugins.surfaceDisabled("weather")
                    property bool cellPresent: Weather.ready && !Plugins.surfaceDisabled("weather")
                    width: weatherRow.implicitWidth
                    height: weatherRow.implicitHeight

                    Row {
                        id: weatherRow
                        anchors.centerIn: parent
                        spacing: 5 * pill.s

                        GlyphIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: pill.iconCell
                            height: pill.iconCell
                            name: Weather.glyphFor(Weather.codeNow, Weather.isDay)
                            color: Theme.iconDim
                            stroke: 1.8
                        }

                        AltText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Weather.tempNow + "°"
                            font.family: Theme.font
                            font.pixelSize: 12.5 * pill.s
                            font.weight: Font.Medium
                            font.features: { "tnum": 1 }
                        }
                    }

                    MouseArea {
                        id: weatherArea
                        anchors.centerIn: parent
                        width: weatherRow.implicitWidth + 12 * pill.s
                        height: weatherRow.implicitHeight + 8 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("weather")
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "Weather"
                        desc: "Forecast and conditions"
                        show: weatherArea.containsMouse
                    }
                    // better: tooltip weather
                }
    }

    Component {
        id: cellDnd
                Item {
                    id: dndIcon
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Flags.dnd
                    property bool cellPresent: Flags.dnd
                    width: pill.iconCell
                    height: pill.iconCell

                    Shape {
                        id: dndShape

                        width: 16
                        height: 16
                        scale: pill.s
                        transformOrigin: Item.TopLeft
                        x: dndShape.boundingRect.width > 0
                           ? dndIcon.width / 2 - (dndShape.boundingRect.x + dndShape.boundingRect.width / 2) * pill.s
                           : (dndIcon.width - 16 * pill.s) / 2
                        y: dndShape.boundingRect.height > 0
                           ? dndIcon.height / 2 - (dndShape.boundingRect.y + dndShape.boundingRect.height / 2) * pill.s
                           : (dndIcon.height - 16 * pill.s) / 2
                        preferredRendererType: Shape.CurveRenderer

                        ShapePath {
                            strokeColor: Theme.vermLit
                            strokeWidth: 1.5
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            joinStyle: ShapePath.RoundJoin
                            startX: 5.2; startY: 12.2
                            PathLine { x: 12.2; y: 12.2 }
                            PathLine { x: 12.2; y: 7.2 }
                            PathCubic {
                                control1X: 12.2; control1Y: 5.4
                                control2X: 11.2; control2Y: 4.0
                                x: 9.5; y: 3.5
                            }
                        }
                        ShapePath {
                            strokeColor: Theme.vermLit
                            strokeWidth: 1.5
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            startX: 6.8; startY: 13.6
                            PathLine { x: 9.2; y: 13.6 }
                        }
                        ShapePath {
                            strokeColor: Theme.vermLit
                            strokeWidth: 1.6
                            fillColor: "transparent"
                            capStyle: ShapePath.RoundCap
                            startX: 3.2; startY: 2.8
                            PathLine { x: 13.0; y: 13.4 }
                        }
                    }
                }
    }

    Component {
        id: cellWifi
                    Item {
                        id: wifiIcon
                        anchors.verticalCenter: parent.verticalCenter
                        visible: pill.wifiDev !== null && !Plugins.surfaceDisabled("wifi")
                        property bool cellPresent: pill.wifiDev !== null && !Plugins.surfaceDisabled("wifi")
                        width: pill.iconCell
                        height: pill.iconCell

                        WifiGlyph {
                            anchors.centerIn: parent
                            s: pill.s
                            level: pill.wifiLevel
                            on: pill.wifiOn
                            stroke: 1.7
                        }

                        MouseArea {
                            id: wifiArea
                            anchors.fill: parent
                            anchors.margins: -6 * pill.s
                            hoverEnabled: true
                            enabled: hover.live
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (e) => {
                                if (e.button === Qt.RightButton) {
                                    if (typeof Networking !== "undefined" && Networking)
                                        Networking.wifiEnabled = !Networking.wifiEnabled;
                                    return;
                                }
                                pill.requestSurface("wifi");
                            }
                            onContainsMouseChanged: if (containsMouse) pill.soulTarget = "wifi"
                        }

                        Tooltip {
                            s: pill.s
                            placement: "below"
                            title: "Wi-Fi"
                            desc: "Right-click to toggle"
                            show: wifiArea.containsMouse
                        }
                        // better: tooltip wifi
                    }
    }

    Component {
        id: cellBt
                    Item {
                        id: btIcon
                        anchors.verticalCenter: parent.verticalCenter
                        visible: pill.btAdapter !== null && !Plugins.surfaceDisabled("bt")
                        property bool cellPresent: pill.btAdapter !== null && !Plugins.surfaceDisabled("bt")
                        width: pill.iconCell
                        height: pill.iconCell

                        GlyphIcon {
                            anchors.fill: parent
                            name: "bluetooth"
                            color: btArea.containsMouse ? Theme.cream
                                : (pill.btOn ? Theme.iconDim : Qt.alpha(Theme.iconDim, 0.4))
                            stroke: 1.7
                        }

                        MouseArea {
                            id: btArea
                            anchors.fill: parent
                            anchors.margins: -6 * pill.s
                            hoverEnabled: true
                            enabled: hover.live
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (e) => {
                                if (e.button === Qt.RightButton) {
                                    if (pill.btAdapter)
                                        pill.btAdapter.enabled = !pill.btAdapter.enabled;
                                    return;
                                }
                                pill.requestSurface("bt");
                            }
                            onContainsMouseChanged: if (containsMouse) pill.soulTarget = "bt"
                        }

                        Tooltip {
                            s: pill.s
                            placement: "below"
                            title: "Bluetooth"
                            desc: "Right-click to toggle"
                            show: btArea.containsMouse
                        }
                        // better: tooltip bt
                    }
    }

    Component {
        id: cellBattery
                    Item {
                        id: batteryIcon
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Battery.present
                        property bool cellPresent: Battery.present
                        width: battPct.implicitWidth
                        height: pill.iconCell

                        AltText {
                            id: battPct
                            anchors.centerIn: parent
                            text: Battery.pct + "%"
                            font.family: Theme.font
                            font.pixelSize: 13 * pill.s
                            font.weight: Battery.charging ? Font.DemiBold : Font.Medium
                            font.features: { "tnum": 1 }
                        }

                        MouseArea {
                            id: batteryArea
                            anchors.fill: parent
                            anchors.margins: -6 * pill.s
                            hoverEnabled: true
                            enabled: hover.live
                            cursorShape: Qt.PointingHandCursor
                            onClicked: pill.requestSurface("battery")
                            onContainsMouseChanged: if (containsMouse) pill.soulTarget = "battery"
                        }

                        Tooltip {
                            s: pill.s
                            placement: "below"
                            title: "Battery"
                            desc: "Battery status and settings"
                            show: batteryArea.containsMouse
                        }
                        // better: tooltip battery
                    }
    }

    Component {
        id: cellInbox
                Item {
                    id: inboxIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    property bool cellPresent: true

                    GlyphIcon {
                        anchors.fill: parent
                        name: "inbox"
                        color: inboxArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    Rectangle {
                        visible: Notifs.unread > 0
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: -2 * pill.s
                        anchors.rightMargin: -2 * pill.s
                        width: 5 * pill.s
                        height: 5 * pill.s
                        radius: width / 2
                        color: Theme.flameGlow
                    }

                    MouseArea {
                        id: inboxArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("link")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "inbox"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "Notifications"
                        desc: "Inbox and notification history"
                        show: inboxArea.containsMouse
                    }
                    // better: tooltip inbox
                }
    }

    Component {
        id: cellMixer
                Item {
                    id: mixerIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    visible: !Plugins.surfaceDisabled("mixer")
                    property bool cellPresent: !Plugins.surfaceDisabled("mixer")

                    GlyphIcon {
                        anchors.fill: parent
                        name: "mixer"
                        color: mixerArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: mixerArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("mixer")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "mixer"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "Audio"
                        desc: "Volume and output devices"
                        show: mixerArea.containsMouse
                    }
                    // better: tooltip mixer
                }
    }

    Component {
        id: cellSysmon
                Item {
                    id: sysmonIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    property bool cellPresent: true

                    GlyphIcon {
                        anchors.fill: parent
                        name: "monitor"
                        color: sysmonArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: sysmonArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("sysmon")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "sysmon"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "System monitor"
                        desc: "CPU, memory, disk and network"
                        show: sysmonArea.containsMouse
                    }
                    // better: tooltip sysmon
                }
    }

    Component {
        id: cellWallpaper
                Item {
                    id: wallpaperIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    visible: !Plugins.surfaceDisabled("wallpaper")
                    property bool cellPresent: !Plugins.surfaceDisabled("wallpaper")

                    GlyphIcon {
                        anchors.fill: parent
                        name: "wallpaper"
                        color: wallpaperArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: wallpaperArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("wallpaper")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "wallpaper"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "Wallpaper"
                        desc: "Change the background"
                        show: wallpaperArea.containsMouse
                    }
                    // better: tooltip wallpaper
                }
    }

    Component {
        id: cellClipboard
                Item {
                    id: clipboardIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    visible: !Plugins.surfaceDisabled("clipboard")
                    property bool cellPresent: !Plugins.surfaceDisabled("clipboard")

                    GlyphIcon {
                        anchors.fill: parent
                        name: "clipboard"
                        color: clipboardArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: clipboardArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("clipboard")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "clipboard"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "Clipboard"
                        desc: "Clipboard history"
                        show: clipboardArea.containsMouse
                    }
                    // better: tooltip clipboard
                }
    }

    Component {
        id: cellLauncher
                Item {
                    id: launcherIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    visible: !Plugins.surfaceDisabled("launcher")
                    property bool cellPresent: !Plugins.surfaceDisabled("launcher")

                    GlyphIcon {
                        anchors.fill: parent
                        name: "app-window"
                        color: launcherArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: launcherArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("launcher")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "launcher"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        title: "Launcher"
                        desc: "Apps and commands"
                        show: launcherArea.containsMouse
                    }
                    // better: tooltip launcher
                }
    }

    Component {
        id: cellAppearance
                Item {
                    id: appearanceIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    visible: !Plugins.surfaceDisabled("appearance")
                    property bool cellPresent: !Plugins.surfaceDisabled("appearance")

                    GlyphIcon {
                        anchors.fill: parent
                        name: "cog"
                        // Scale only, no stroke offset: the gear's teeth are
                        // drawn to the same 24-unit box as every other glyph and
                        // land heavier than its neighbours at this size, so it is
                        // scaled rather than stroked thinner. One compensation
                        // instead of two is what keeps it from drifting again.
                        scale: 0.86
                        transformOrigin: Item.Center
                        color: appearanceArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: appearanceArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("appearance")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "appearance"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        align: "right"
                        title: "Settings"
                        desc: "Appearance, panels and plugins"
                        show: appearanceArea.containsMouse
                    }
                    // better: tooltip appearance
                }
    }

    Component {
        id: cellPower
                Item {
                    id: powerIcon
                    anchors.verticalCenter: parent.verticalCenter
                    width: pill.iconCell
                    height: pill.iconCell
                    visible: !Plugins.surfaceDisabled("power")
                    property bool cellPresent: !Plugins.surfaceDisabled("power")

                    GlyphIcon {
                        anchors.fill: parent
                        name: "shutdown"
                        color: powerArea.containsMouse ? Theme.cream : Theme.iconDim
                        stroke: 1.7
                    }

                    MouseArea {
                        id: powerArea
                        anchors.fill: parent
                        anchors.margins: -6 * pill.s
                        hoverEnabled: true
                        enabled: hover.live
                        cursorShape: Qt.PointingHandCursor
                        onClicked: pill.requestSurface("power")
                        onContainsMouseChanged: if (containsMouse) pill.soulTarget = "power"
                    }

                    Tooltip {
                        s: pill.s
                        placement: "below"
                        align: "right"
                        title: "Power"
                        desc: "Lock, restart, suspend, shut down"
                        show: powerArea.containsMouse
                    }
                    // better: tooltip power
                }
    }

    // Close every open strip layout menu at once (Escape).
    function closeStripMenus() {
        if (stripCells.count === 0) return;
        for (let i = 0; i < stripCells.count; i++) {
            const d = stripCells.itemAt(i);
            if (d) d.closeMenu();
        }
    }

    // Resolve a native cell slot by its id, for soul anchoring. The cell ids
    // live inside their Components now, so soulPoint cannot name them; it asks
    // the strip's delegates instead.
    function iconFor(target) {
        if (!target || stripCells.count === 0) return null;
        for (let i = 0; i < stripCells.count; i++) {
            const d = stripCells.itemAt(i);
            if (d && d.cellId === target) return d.nativeItem;
        }
        return null;
    }

    function cellComponentFor(e) {
        if (!e || e.kind !== "cell") return null;
        switch (e.id) {
        case "tray": return cellTray;
        case "weather": return cellWeather;
        case "dnd": return cellDnd;
        case "wifi": return cellWifi;
        case "bt": return cellBt;
        case "battery": return cellBattery;
        case "inbox": return cellInbox;
        case "mixer": return cellMixer;
        case "sysmon": return cellSysmon;
        case "wallpaper": return cellWallpaper;
        case "clipboard": return cellClipboard;
        case "launcher": return cellLauncher;
        case "appearance": return cellAppearance;
        case "power": return cellPower;
        }
        return null;
    }

    /**
     * Morphing surfaces, one tail-unloaded Loader each (see surfaceItem). Eager,
     * they dominated startup and per-monitor RAM; now a surface is built
     * synchronously on its first open, kept for one private tiered countdown
     * after it stops being open, then dropped — so nothing is retained for surfaces
     * the user never opens, and closed ones don't linger past their own tail. Each
     * loader fills the pill so the PillSurface inside anchors exactly as it did as a
     * direct child.
     */

    Loader {
        id: ldMixer
        active: false
        anchors.fill: parent
        sourceComponent: Mixer {
            s: pill.s
            open: pill.mixerOpen
            morphCloseness: pill.morphCloseness
        }
    }

    Loader {
        id: ldCalendar
        active: false
        anchors.fill: parent
        sourceComponent: Calendar {
            s: pill.s
            open: pill.calendarOpen
            morphCloseness: pill.morphCloseness
        }
    }

    Loader {
        id: ldWeather
        active: false
        anchors.fill: parent
        sourceComponent: WeatherSurface {
            s: pill.s
            open: pill.weatherOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldPluginSurface
        active: false
        anchors.fill: parent
        sourceComponent: PluginHostSurface {
            s: pill.s
            open: pill.pluginSurfaceOpen
            morphCloseness: pill.morphCloseness
            pluginId: pill.pluginSurfaceId
            barHeightOverride: pill.y + pill.height
            entryPoint: pill.pluginSurfaceEntryPoint
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldLauncher
        active: false
        anchors.fill: parent
        sourceComponent: Launcher {
            s: pill.s
            open: pill.launcherOpen
            morphCloseness: pill.morphCloseness
            // Submenu requested by a `menu` IPC call. Bound rather than pushed
            // so a plain `launcher` call (no route) still opens at the
            // remembered submenu.
            route: pill.menuRoute
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldClip
        active: false
        anchors.fill: parent
        sourceComponent: Clipboard {
            s: pill.s
            open: pill.clipboardOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldWall
        active: false
        anchors.fill: parent
        sourceComponent: Wallpaper {
            s: pill.s
            open: pill.wallpaperOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldPower
        active: false
        anchors.fill: parent
        sourceComponent: Power {
            s: pill.s
            open: pill.powerOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldMedia
        active: false
        anchors.fill: parent
sourceComponent: Media {
            s: pill.s
            open: pill.mediaOpen
            morphCloseness: pill.morphCloseness
            topFlat: (pill.mode === "game" || pill.stripBar) ? 1 : 0
            pinned: pill.held
            onRequestClose: pill.requestClose()
            onRequestPin: pill.forcePinned = !pill.held
            onRequestExpand: {
                pill.requestClose();
                pill.hoverLatch = true;
                pill.expandLatch = true;
            }
        }
    }

    Loader {
        id: ldLink
        active: false
        anchors.fill: parent
        sourceComponent: Link {
            s: pill.s
            open: pill.linkOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldWifi
        active: false
        anchors.fill: parent
        sourceComponent: WifiSurface {
            s: pill.s
            open: pill.wifiOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldBt
        active: false
        anchors.fill: parent
        sourceComponent: BtSurface {
            s: pill.s
            open: pill.btOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldBattery
        active: false
        anchors.fill: parent
        sourceComponent: BatterySurface {
            s: pill.s
            open: pill.batteryOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldSysmon
        active: false
        anchors.fill: parent
        sourceComponent: SysmonSurface {
            s: pill.s
            open: pill.sysmonOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
        }
    }

    Loader {
        id: ldAppearance
        active: false
        anchors.fill: parent
        sourceComponent: Appearance {
            s: pill.s * pill.settingsScale
            open: pill.appearanceOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldAppcat
        active: false
        anchors.fill: parent
        sourceComponent: AppearanceSub {
            s: pill.s * pill.settingsScale
            open: pill.appcatOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldDisplay
        active: false
        anchors.fill: parent
        sourceComponent: DisplaySurface {
            s: pill.s * pill.settingsScale
            open: pill.displayOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldTheme
        active: false
        anchors.fill: parent
        sourceComponent: ThemeSurface {
            s: pill.s * pill.settingsScale
            open: pill.themeOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldAccent
        active: false
        anchors.fill: parent
        sourceComponent: AccentSurface {
            s: pill.s * pill.settingsScale
            open: pill.accentOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldGlass
        active: false
        anchors.fill: parent
        sourceComponent: GlassSurface {
            s: pill.s * pill.settingsScale
            open: pill.glassOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldFontcolor
        active: false
        anchors.fill: parent
        sourceComponent: FontColorSurface {
            s: pill.s * pill.settingsScale
            open: pill.fontColorOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldInterface
        active: false
        anchors.fill: parent
        sourceComponent: InterfaceSurface {
            s: pill.s * pill.settingsScale
            open: pill.interfaceOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldFontpicker
        active: false
        anchors.fill: parent
        sourceComponent: FontPicker {
            s: pill.s * pill.settingsScale
            open: pill.fontpickerOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldPlugins
        active: false
        anchors.fill: parent
        sourceComponent: PluginsSurface {
            s: pill.s * pill.settingsScale
            open: pill.pluginsOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldUpdate
        active: false
        anchors.fill: parent
        sourceComponent: UpdateSurface {
            s: pill.s * pill.settingsScale
            open: pill.updateOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    /**
     * OSD state controller only. The visible OSD now lives in its own
     * decoupled popup (surfaces/OsdPopup.qml); this instance stays hidden and
     * just feeds the game-mode volume chip and toast-retire logic.
     */
    Osd {
        id: osd
        s: pill.s
        screenName: pill.screenName
        suppressed: pill.surfaceOpen || pill.held
        expanded: pill.expanded
        visible: false
        enabled: false
    }

    Loader {
        id: toastLoader
        active: pill.toastActive
        anchors.fill: parent
        anchors.topMargin: 12 * pill.s
        anchors.leftMargin: 16 * pill.s
        anchors.rightMargin: 16 * pill.s
        anchors.bottomMargin: 12 * pill.s
        enabled: pill.mode === "toast"
        opacity: pill.mode === "toast" ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity {
            NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard }
        }

        sourceComponent: Item {
            implicitHeight: toastContent.implicitHeight

            Toast {
                id: toastContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                s: pill.s
                live: pill.mode === "toast"
                notif: Notifs.popups.length > 0 ? Notifs.popups[Notifs.popups.length - 1] : null
            }

            AltText {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: Notifs.popups.length > 1
                text: "+" + (Notifs.popups.length - 1)
                font.family: Theme.font
                font.pixelSize: 9 * pill.s
                font.weight: Font.DemiBold
            }
        }
    }

}
