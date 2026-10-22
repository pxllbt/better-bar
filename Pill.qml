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

    /**
     * The ShellRoot that owns this pill.
     *
     * Injected, not reached for by name. `Pill` is instantiated directly in
     * shell.qml rather than inside a delegate, so QML's creation context gives
     * it no ids from that file: `id: root` there is invisible here. The four
     * `root.pillBarHeight` / `root.pillBarRadius` writes below therefore threw a
     * ReferenceError every time, which is why the dock never received the pill's
     * resting bar height or corner radius and had to guess its own.
     *
     * Named `hostRoot` so the assignment site reads `hostRoot: root` without the
     * right-hand side resolving to the property being assigned.
     */
    required property var hostRoot
    property var barWindow
    property var barAnchorItem: null
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
        // clipboard: immediate teardown on close so native input fields do not linger
        clipboard:   0,
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
        pill.hostRoot.pillBarHeight = restSize.height;
        pill.hostRoot.pillBarRadius = roundRadius;
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

    /** True while any monitor has a fullscreen client — the media surface
     *  stays closed over a game to avoid popping up during gameplay. */
    readonly property bool anyFullscreen: hostRoot.anyFullscreen

    /**
     * The floating media island: in strip mode the now-playing card hovers
     * *above* the bar instead of replacing it.
     *
     * Why this is strip-only, and why it had to be fixed at all:
     *
     * The card used to take over the pill's identity — same rect, same input
     * mask, same surface slot. In the centred pill that is the whole point of a
     * dynamic island and it reads beautifully. Across a full-width strip it
     * breaks two things at once:
     *
     *  1. The bar becomes unclickable. While the card holds the pill rect, the
     *     window's input mask *is* the card, so the weather, wifi and battery
     *     cells sit outside the mask and swallow nothing. You cannot reach the
     *     strip without first dismissing the card that the strip summoned.
     *  2. The card can never come back. Every trigger for re-opening it lived
     *     on an element that the card itself hides — the strip face row goes
     *     invisible, the window-level HoverHandler is disabled while a surface
     *     is open, and `onPositionChanged` only fires on movement. So the card
     *     opened once and then the pointer had to leave the bar completely and
     *     re-enter to get it again. This is the "it just open 1 time then now
     *     its gone again" report, and it is a symptom of (1), not a separate
     *     bug.
     *
     * Floating decouples them: the card gets its own rect and its own mask
     * region, the strip stays fully alive and clickable, and "cursor is in the
     * bar while media plays" becomes a statement about geometry that cannot get
     * stuck.
     *
     * The centred pill keeps the morph, because there the island *is* the pill
     * and nothing is stolen from it.
     */
    readonly property bool mediaFloats: false

    /** Air between the strip and the island's underside. */
    readonly property real islandGap: 9 * s
    readonly property real islandW: mediaW
    readonly property real islandH: mediaH
    /** Island rect in pill coordinates; shell.qml reads these for the input mask. */
    readonly property real islandX: (pill.width - islandW) / 2
    readonly property real islandY: pill.height + islandGap
    readonly property bool linkOpen: surface === "link"
    readonly property bool weatherOpen: surface === "weather"
    readonly property bool wifiOpen: surface === "wifi"
    readonly property bool btOpen: surface === "bt"
    readonly property bool batteryOpen: surface === "battery"
    readonly property bool sysmonOpen: surface === "sysmon"
    readonly property bool profileOpen: surface === "profile"
    readonly property bool modulesOpen: surface === "modules"
    readonly property bool screensOpen: surface === "screens"
    readonly property bool appearanceOpen: surface === "appearance"
    readonly property bool appcatOpen: surface === "appcat"
    readonly property bool displayOpen: surface === "display"
    readonly property bool themeOpen: surface === "theme"
    readonly property bool accentOpen: surface === "accent"
    readonly property bool glassOpen: surface === "glass"
    readonly property bool fontColorOpen: surface === "fontcolor"
    readonly property bool fontpickerOpen: surface === "fontpicker"
    readonly property bool pluginsOpen: surface === "plugins"
    readonly property bool updateOpen: surface === "update"
    readonly property bool keybindsOpen: surface === "keybinds"
    readonly property bool lockstyleOpen: surface === "lockstyle"
    readonly property bool settingsLike: appearanceOpen || appcatOpen || displayOpen || modulesOpen || themeOpen || accentOpen || glassOpen || fontColorOpen || fontpickerOpen || pluginsOpen || updateOpen || lockstyleOpen || keybindsOpen || profileOpen
    /**
     * Real media is on screen: a player that is not idle and has a title.
     *
     * This is what "there is something to show" means — the player detail in
     * the pill, the strip's title, the card's own rows.
     */
    readonly property bool mediaContent: Players.has
        && (Players.playing || (Flags.mediaAlways && Players.title.length > 0))
        && !Players.isIdle(Players.active) && Players.title.trim().length > 0
    /**
     * The media *entry* is available.
     *
     * `Flags.mediaAlways` used to be unreachable: this predicate demanded
     * `Players.has`, so the moment the last player exited, every media control
     * vanished with it — which is the one thing "Always show media" promises
     * not to do. An entry you can only find while something is playing is not
     * an entry; it is a notification of the music.
     *
     * So the flag keeps the entry alive on its own terms: the bud stays on the
     * bar, hovering it still opens the player, and the card it opens can say
     * "Nothing playing" instead of the control disappearing. With the flag off
     * this is exactly the old predicate — media, or nothing.
     */
    readonly property bool hasMedia: Flags.mediaAlways || pill.mediaContent

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
        interval: 1200
        running: true
        onTriggered: {
            pill.bootSettled = true;
            if (Players.isActualMedia && !pill.recastActive && !pill.surfaceOpen && !pill.pluginSurfaceOpen && !Flags.gameMode && pill.mode !== "game" && !pill.toastActive) {
                pill.surfaceDismissLatch = false
                pill.requestSurface("media");
            }
        }
    }

    readonly property bool expanded: surfaceOpen || held || hoverLatch || expandLatch || stripMenuOpen

    /**
     * Drives the resting agent chip's breath. Separate from the workspace
     * strip's own tick because that one only exists while the pill is expanded,
     * and this chip has to keep beating at rest — that is the whole reason it
     * exists. Only runs while something is actually waiting, so an idle bar pays
     * nothing for it.
     */
    property int agentTick: 0
    Timer {
        interval: 90
        repeat: true
        running: Agents.urgent > 0
        triggeredOnStart: true
        onTriggered: pill.agentTick += 1
    }

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
     * The NOTCH face: the classic resting content, cut INTO the top edge of
     * the screen instead of floating in it.
     *
     * The capsule hangs below the top edge with a band of desktop above it and
     * rounds all four corners. The notch does the opposite: its top edge is
     * square and MEETS the screen border, and only its bottom corners stay
     * rounded, so the bar reads as a bite taken out of the screen rather than
     * a bubble sitting in front of it. It runs the full width of the monitor,
     * which is what makes that square top read as an edge.
     *
     * It is the SAME content as the classic face -- clock, date, time, badge,
     * media bud, and the one recording chip. The notch changes the box, not
     * the bar.
     */
    readonly property bool notchBar: Flags.mainDisplay === "notch"

    /**
     * The notch's width: the CONTENT's width, not the monitor's.
     *
     * The notch is a tab in the middle of the top edge, not a band across
     * the whole screen -- it is the classic capsule's width with its top
     * corners squared off and its margin cancelled. A full-width band was
     * the first attempt and it read as a divider across the desktop, not as
     * a bar.
     */
    readonly property real notchW: Math.max(restRow.implicitWidth, 140 * pill.s)
        + 2 * pill.notchPad + pill.budSlot

    /**
     * The notch's own inset and row spacing.
     *
     * A notch is a tab cut into the screen, not a floating capsule, so it can
     * sit tighter than the capsule does: a smaller inset at each end, and
     * less air between the items. The capsule keeps its own numbers, because
     * a floating pill needs the air to read as a separate object.
     */
    readonly property real notchPad: 3 * s
    readonly property real notchSpacing: 4 * s

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
        || mode === "game" || (pill.recastActive && !osdActive)

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
    /**
     * Whether a special workspace (the scratchpad, the Minimized stash) takes
     * the bar off the screen.
     *
     * The NOTCH is exempt. A notch is the bar's SHAPE rather than an object
     * floating in front of the screen: it is cut INTO the top edge. Hiding it
     * would not tidy the desktop up, it would leave a hole where the bar was,
     * and the bar would come back as a different shape when you left the
     * workspace -- so the setting would mean "a notch, except not on the
     * workspaces where you would look for it". The notch stays a notch.
     *
     * The word itself (Scratchpad, Minimized) still replaces the clock in the
     * notch, so the state is still said out loud; only the shape is kept.
     */
    readonly property bool specialHidden: Flags.hideOnSpecial && activeSpecial.length > 0 && !pill.notchBar
    readonly property bool hidden: heldOpen ? false : (Flags.autoHide || offCursor || specialHidden)

    /**
     * The special workspace shown on this pill's monitor, surfaced as a plain word
     * in place of the clock so it is obvious you are looking at the minimized stash
     * or the private space rather than your real desktop. Empty in the normal case.
     */
    property string activeSpecial: ""

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!event || !event.name) return;
            if (event.name === "activespecial") {
                var d = String(event.data || "");
                var comma = d.indexOf(",");
                var spName = comma >= 0 ? d.substring(0, comma) : d;
                var monName = comma >= 0 ? d.substring(comma + 1) : "";
                if (monName === "" || monName === pill.screenName) {
                    if (spName.indexOf("special:") === 0) {
                        var id = spName.slice("special:".length);
                        pill.activeSpecial = id === "scratchpad" ? "Scratchpad" : (id.charAt(0).toUpperCase() + id.slice(1));
                    } else {
                        pill.activeSpecial = "";
                    }
                }
            } else if (event.name === "activespecialv2") {
                var d2 = String(event.data || "");
                var parts = d2.split(",");
                var name2 = parts.length > 1 ? parts[1] : "";
                var mon2 = parts.length > 2 ? parts[2] : "";
                if (mon2 === "" || mon2 === pill.screenName) {
                    if (name2.indexOf("special:") === 0) {
                        var id2 = name2.slice("special:".length);
                        pill.activeSpecial = id2 === "scratchpad" ? "Scratchpad" : (id2.charAt(0).toUpperCase() + id2.slice(1));
                    } else if (name2 === "") {
                        pill.activeSpecial = "";
                    }
                }
            }
        }
    }

    readonly property string specialView: {
        if (pill.activeSpecial.length > 0)
            return pill.activeSpecial;
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
                    if (id === "scratchpad") return "Scratchpad";
                    return id.charAt(0).toUpperCase() + id.slice(1);
                }
                return "";
            }
        }
        return "";
    }
    readonly property bool recastRecording: typeof Recast !== "undefined" && Recast.recording
    // The chip stays visible across the paused state and countdown too: a paused
    // recording is still an active capture, and dropping the chip made it look stopped.
    readonly property bool recastActive: Flags.pillShowRecorder && typeof Recast !== "undefined" && (Recast.recording || Recast.paused || Recast.countdownPending)

    /**
     * Whether a REC face may draw at all.
     *
     * Nine slots already gate on `!Recast.recording`, so they all step aside for
     * the recording chip. The chip had no reciprocal: it drew unconditionally
     * whenever a recording was live, even while an OSD flash or a toast owned
     * the pill face. Switching workspaces while recording fires exactly that --
     * the workspace OSD takes the face and the REC face keeps drawing over it,
     * which reads as a second pill offset from the first. They do not animate
     * together because only one of them is part of the face the transient drives.
     *
     * Kept as one property so the strip copy and the rest-row copy cannot drift
     * apart again -- they did once, and that is how the doubled face started.
     */
    /**
     * The recording chip yields to NOTHING.
     *
     * The special view (the Minimized stash, the scratchpad) and a recording
     * used to EXCLUDE each other, and the exclusion was total:
     *
     *   - the resting row hides itself while a recording runs,
     *   - the special word stands down for a recording,
     *   - and the chip used to stand down for the special view.
     *
     * So with a minimized-window stash active and a recording running, every
     * element of the pill hid at once: the date, the time, the badge, the
     * clock, the special word, the chip. The pill was an empty outline for
     * the whole take -- no REC, no countdown, no elapsed count.
     *
     * The OSD and the toast are separate layer surfaces drawn ON TOP of the
     * pill, and they are not opaque, so yielding to them had the same effect:
     * the pill went blank with a translucent notification over the hole.
     *
     * A recording is the more important thing to say, so the chip does not
     * yield to any of them.
     */
    readonly property bool recastFaceVisible: recastActive
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

    /**
     * The room the media bud needs at the pill's right edge.
     *
     * The bud is a child of the pill, not of the resting row, so it does not
     * make the row any wider -- it has to be given space of its own or it
     * hangs over the right edge of the capsule. It used to be positioned at
     * `pill.width - budR`, which put its RIGHT edge `budR` past the pill's
     * right edge: the disc sat half outside the bar, on the desktop, looking
     * like a widget that had escaped rather than part of the bar.
     *
     * The numbers below are the whole geometry of the resting face, and they
     * are three because the pill's two ends have to match:
     *
     *   restPad   the capsule's inset at both ends of the row. The left end
     *             and the disc's right end share this number, so the bar is
     *             symmetric instead of trailing air on one side.
     *   budGap    the air between the row and the disc -- the disc's
     *             neighbour, so this is a hair, not a margin.
     *   budRestW  the disc's width.
     *
     * The disc does NOT grow on hover any more. It used to swell from 24*s
     * to 30*s, and a swell that changes a layout has to be paid for out of
     * one of the gaps around it -- which is why the gap the disc sits in was
     * never allowed to be small, and why the bar kept a slot wider than the
     * disc it was reserving room for. The bud now answers the pointer with
     * the album art swelling inside the glass and the sheen catching the
     * light, and the bubble keeps its size, so the gap beside it is exactly
     * what it says it is at every moment.
     */
    readonly property real restPad: 5 * s
    readonly property real budInset: restPad
    readonly property real budRestW: 24 * s
    readonly property real budGap: 3 * s
    /**
     * The room the pill reserves for the media bud: the hair of air between
     * the row and the disc, plus the disc itself.
     *
     * It is a CONSTANT rather than the bud's live width, because a slot sized
     * to the live width would make the pill resize the moment the pointer
     * touched the bud, and the bud would chase its own edge.
     */
    readonly property real budSlot: (bud.shown ? budGap + budRestW : 0)

    /**
     * How far left of the pill's centre the resting content sits.
     *
     * The disc owns the pill's right edge, so a CENTRED row pushes half of
     * the reserve out of the left side as dead space -- which is how the bar
     * used to open with a third of a pill's width of nothing before its
     * first glyph. Half the slot is exactly that much, so the row stands
     * flush-left inside the capsule's inset while the group as a whole
     * (row, gap, disc) stays centred on the screen.
     */
    readonly property real restFaceOffset: (bud.shown ? -budSlot / 2 : 0)

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

     /* Strip-face geometry: a compact top-centre notch pill. Its width is
     * computed explicitly (not from the row's implicit width) so the media
     * title can be elided to exactly what the budget allows; on a 1920px
     * screen the content lands around 500-600px wide. Lower-priority sections
     * (visualizer, then media) fold away first when the budget tightens.
     */
    /**
     * The notch's inset at each end, and the gap between its sections.
     *
     * Both were 20*s and 16*s, which is a bar that opens with eighteen pixels
     * of nothing before its first tile and holds its sections a full gap
     * apart. The resting face runs on 5*s, and the expanded faces now run on
     * the same order of magnitude rather than four times it: the notch still
     * reads as a bar with room in it, and it no longer reads as a bar with
     * two empty ends.
     *
     * `stripPad` is also the notch's title budget, so shrinking it gives the
     * media title more room to breathe, not less.
     */
    readonly property real stripPad: 10 * pill.s
    readonly property real stripGap: 16 * s
    readonly property bool stripHover: stripFaceMouse.containsMouse
    property bool ghostStripHover: false
    readonly property real stripCap: Math.max(480 * s, Math.min(850 * s, (barWindow ? barWindow.width : 1920 * s) - 80 * s))

    // No strip-face zoom property lives here any more. The width slider used to
    // scale the whole notch (content and box) through a transform, with the
    // layout width multiplied to match, and both halves are gone: the notch now
    // draws at the size `stripFaceW` already measured, and the row is its own
    // size again. Keeping a scale of 1 would have left a transform that cannot
    // do anything but still has to agree with the width it was computed from.
    readonly property real stripArtW: 22 * s
    readonly property real stripMinTitle: 55 * s
    readonly property real stripMaxTitle: 280 * s

    readonly property real stripVizW: (Cava.bars * 1.8 + (Cava.bars - 1) * 1.2) * s

    /** Media-side gaps depend only on the visualizer. */
    readonly property int stripMediaGaps: 1 + (Cava.active ? 1 : 0)

    // Media is the one section that should not vanish merely because the budget
    // cannot fit a full-width title: a partial title and the album art still
    // read as media. The full title still gets the min-width preference when
    // none is playing, so an idle bar is not steadily crowded.
    //
    // Two questions, kept apart on purpose:
    //
    //   stripMedia      — is there a track to describe? The title, the
    //     visualiser and the hairline that go with it answer to this.
    //   stripMediaEntry — is the media *entry* on the bar? The album-art tile
    //     is the click target that opens the player, and the always-media flag
    //     keeps it on screen with no track at all: an entry that disappears
    //     with its content is not an entry.
    readonly property bool stripMedia: Players.has
        && (Players.playing || (Flags.mediaAlways && Players.title.length > 0))
        && !Players.isIdle(Players.active) && Players.title.trim().length > 0
        && stripRoomForTitle > 0
    readonly property bool stripMediaEntry: Flags.mediaAlways || pill.stripMedia
    readonly property real stripRoomForTitle: stripCap - 2 * stripPad - stripArtW - stripFixedW
        - 4 * stripGap - stripMediaGaps * stripGap
        - (Cava.active ? stripVizW : 0)

    readonly property real stripTitleW: stripMedia ? Math.min(stripMaxTitle, Math.max(stripMinTitle, stripTitleMetrics.advanceWidth + 4 * s)) : 0
    readonly property real stripFixedW: stripDay.implicitWidth + stripTime.implicitWidth
        + stripWs.implicitWidth + stripLay.implicitWidth + (Battery.present ? stripBat.implicitWidth : 0)
        + (Updater.omarchyUpdateAvailable ? stripUpdate.implicitWidth : 0)

    readonly property real stripFaceW: {
        if (pill.recastActive)
            return Math.max(156 * s, stripRecordingFace.implicitWidth + 24 * s);
        if (pill.specialView !== "")
            return Math.max(144 * s, stripSpecialFace.implicitWidth + 24 * s);
        let neededW = stripFace ? stripFace.implicitWidth + 2 * stripPad : 0;
        let contentW = (stripFace && stripFace.implicitWidth > 0) ? stripFace.implicitWidth : (stripFixedW + (stripMediaEntry ? stripArtW + stripGap : 0) + (stripMedia ? 100 * s : 0));
        return Math.min(stripCap, Math.max(contentW + 2 * stripPad, neededW));
    }
    /**
     * The expanded face's inset at its left end.
     *
     * It was 20*s, so the expanded bar opened with eighteen pixels of empty
     * capsule before the logo, in a bar whose far end held a disc four
     * pixels from the edge. The expanded face now runs on the same inset
     * order as the resting one: the content stands where the resting row
     * stands, the disc keeps the right corner, and the bar reads as one
     * group from end to end.
     */
    readonly property real hoverPad: 8 * s
    /**
     * The corner of the bar the media bud keeps in the hover face as well.
     *
     * The disc holds the pill's right edge in this face too, so the reserve
     * here is the gap plus the disc -- at rest and at its largest -- plus the
     * disc's inset. The same corner of the bar, measured from a wider face.
     */
    readonly property real hoverBudReserve: bud.shown
        ? budGap + budRestW + budInset
        : 0
    /**
     * The expanded face's width: its content, its own padding, and the
     * disc's corner.
     *
     * The content used to be CENTRED in a bar that was mostly the disc's
     * reserve, so half of that reserve came out as dead air on the LEFT of
     * the expanded bar -- nearly forty pixels of nothing before the first
     * glyph. The content now stands flush-left inside the face's own
     * padding, which is the same rule the resting face follows.
     */
    readonly property real hoverW: hoverRow.implicitWidth + hoverPad
        + (bud.shown ? hoverBudReserve : hoverPad)
    /**
     * How far left of the centre the expanded row stands.
     *
     * Half the difference between the face's own padding and the disc's
     * corner: the same arithmetic as the resting face, with the expanded
     * face's larger padding.
     */
    readonly property real hoverFaceOffset: bud.shown
        ? (hoverPad - hoverBudReserve) / 2
        : 0
    readonly property real hoverH: 58 * s
    readonly property real mixerH: 214 * s
    readonly property real launcherW: 360 * s
    readonly property real launcherH: 332 * s
    readonly property real clipboardW: 360 * s
    readonly property real clipboardH: 332 * s
    readonly property real wallpaperW: 720 * s
    readonly property real wallpaperH: 172 * s
    readonly property real powerW: 414 * s
    readonly property real powerH: 150 * s
    readonly property real mediaW: 520 * s
    /**
     * Nominal height of the media card — the FALLBACK, not the real thing.
     *
     * The card measures itself: Media.qml sums its own rows and publishes the
     * total as `implicitHeight`, and the surfaces map below sizes the card
     * from that value. This number only covers the very first frame, before
     * the loader has built the surface — `surfaceItem()` returns null on the
     * first evaluation, exactly as the calendar and weather entries above
     * handle it. It is the card's height with its artist line showing, which
     * is the shape it opens in.
     */
    readonly property real mediaH: 166 * s
    readonly property real batteryW: 316 * s
    readonly property real wifiW: 272 * s
    readonly property real btW: 286 * s
    readonly property real sysmonW: 392 * s
    readonly property real settingsScale: 0.9
    readonly property real settingsW: 392 * s * settingsScale
    readonly property real profileW: 620 * s * settingsScale
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
     * surface name.
     *
     * Activation is DEFERRED, and that is load-bearing. Every caller of this
     * function is a thunk inside `targetSize`'s (or `ameSurface`'s) binding, and
     * those bindings read `ld.item` -- which is a dependency of them, because it
     * goes from null to non-null when the loader turns on. Assigning
     * `ld.active = true` here therefore wrote a property the very same binding
     * read, and Qt logged "Binding loop detected for property targetSize" on
     * every first open of a surface.
     *
     * So the flip is queued with Qt.callLater and this call returns whatever is
     * there right now -- null on a first open. The binding completes without
     * writing anything, and re-evaluates on its own once the item appears,
     * because `ld.item` legitimately changed *after* the binding finished. That
     * is a dependency, not a loop. The cost is one extra layout pass on a first
     * open, which is invisible against the morph itself.
     *
     * The write is idempotent and the Loader loads synchronously, so a second
     * open within the same tick reads the real item. When a surface leaves,
     * scheduleUnload starts its own tail; opening it again before the tail fires
     * cancels the drop, so only surfaces that stay closed actually unload.
     */
    function surfaceItem(name) {
        if (!pill.loaders[name])
            return null;
        const ld = pill.loaders[name]();
        if (!ld)
            return null;
        if (!ld.active) {
            Qt.callLater(function () {
                if (!ld.active) {
                    ld.active = true;
                    pill.cancelUnload(name);                }
            });
        }
        return ld.item;
    }

    /**
     * Null-safe height for a settings surface's size entry.
     *
     * `surfaceItem()` returns null on the very first evaluation of the size map,
     * before the loader has created its item, and a settings surface opens as the
     * default page — so the unguarded `surfaceItem("appearance").implicitHeight`
     * threw once per boot at startup. Baseline measured it 2 runs in 3. The
     * answer is the same fallback the other map entries already carry: a nominal
     * height that renders one honest frame, after which the real item binds and
     * the size becomes live. A size entry is a thunk, so it re-evaluates.
     */
    function settingsSurfaceH(name) {
        const it = surfaceItem(name);
        return it ? it.implicitHeight + 29 * s : 260 * s;
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
        calendar:  { size: () => { const it = surfaceItem("calendar"); if (!it) return Qt.size(282 * s + 36 * s, 260 * s + 32 * s); return Qt.size((it.implicitWidth > 0 ? it.implicitWidth : 282 * s) + 36 * s, it.implicitHeight + 32 * s); }, ame: () => surfaceItem("calendar") },
        weather:   { size: () => { const it = surfaceItem("weather"); if (!it) return Qt.size(282 * s + 36 * s, 260 * s + 32 * s); return Qt.size((it.implicitWidth > 0 ? it.implicitWidth : 282 * s) + 36 * s, it.implicitHeight + 32 * s); }, ame: () => surfaceItem("weather") },
        launcher:  { size: () => { surfaceItem("launcher"); return Qt.size(launcherW, launcherH); }, ame: () => surfaceItem("launcher") },
        clipboard: { size: () => { surfaceItem("clipboard"); return Qt.size(clipboardW, clipboardH); }, ame: () => surfaceItem("clipboard") },
        wallpaper: { size: () => { surfaceItem("wallpaper"); return Qt.size(wallpaperW, wallpaperH); }, ame: () => null },
        power:     { size: () => { surfaceItem("power"); return Qt.size(powerW, powerH); }, ame: () => surfaceItem("power") },
        media:     { size: () => { const it = surfaceItem("media"); if (!it) return Qt.size(mediaW, mediaH); const h = it.implicitHeight; return Qt.size(mediaW, h > 0 ? h : mediaH); }, ame: () => surfaceItem("media") },
        mixer:     { size: () => { const it = surfaceItem("mixer"); return Qt.size(93 * Math.max(4, it ? it.faderCount : 4) * s, mixerH); }, ame: () => surfaceItem("mixer") },
        link:      { size: () => { const it = surfaceItem("link"); return Qt.size(it ? it.desiredW : 360 * s, (it ? it.implicitHeight : 240 * s) + 26 * s); }, ame: () => surfaceItem("link") },
        wifi:      { size: () => { const it = surfaceItem("wifi"); return Qt.size(wifiW, (it ? it.implicitHeight : 260 * s) + 26 * s); }, ame: () => surfaceItem("wifi") },
        bt:        { size: () => { const it = surfaceItem("bt"); return Qt.size(btW, (it ? it.implicitHeight : 260 * s) + 26 * s); }, ame: () => surfaceItem("bt") },
        battery:   { size: () => { const it = surfaceItem("battery"); return Qt.size(batteryW, (it ? it.implicitHeight : 240 * s) + 26 * s); }, ame: () => surfaceItem("battery") },
        sysmon:    { size: () => { const it = surfaceItem("sysmon"); return Qt.size(sysmonW, (it ? it.implicitHeight : 260 * s) + 33 * s); }, ame: () => surfaceItem("sysmon") },
        // The monitor-layout surface is a settings surface (SettingsSeg rows
        // need the settings scale), so it is sized like the others rather than
        // like the dials; its own content drives the height.
        screens:   { size: () => Qt.size(settingsW, settingsSurfaceH("screens")), ame: () => surfaceItem("screens") },
        appearance: { size: () => Qt.size(settingsW, settingsSurfaceH("appearance")), ame: () => surfaceItem("appearance") },
        appcat:     { size: () => Qt.size(settingsW, settingsSurfaceH("appcat")), ame: () => surfaceItem("appcat") },
        display:    { size: () => Qt.size(settingsW, settingsSurfaceH("display")), ame: () => surfaceItem("display") },
        modules:    { size: () => Qt.size(settingsW, settingsSurfaceH("modules")), ame: () => surfaceItem("modules") },
        profile:    { size: () => Qt.size(profileW, settingsSurfaceH("profile")), ame: () => surfaceItem("profile") },
        theme:      { size: () => Qt.size(settingsW, settingsSurfaceH("theme")), ame: () => surfaceItem("theme") },
        accent:     { size: () => Qt.size(settingsW, settingsSurfaceH("accent")), ame: () => surfaceItem("accent") },
        glass:      { size: () => Qt.size(settingsW, settingsSurfaceH("glass")), ame: () => surfaceItem("glass") },
        fontcolor:  { size: () => Qt.size(settingsW, settingsSurfaceH("fontcolor")), ame: () => surfaceItem("fontcolor") },
        fontpicker: { size: () => Qt.size(fontpickerW, settingsSurfaceH("fontpicker")), ame: () => surfaceItem("fontpicker") },
        plugins:    { size: () => Qt.size(settingsW, settingsSurfaceH("plugins")), ame: () => surfaceItem("plugins") },
        update:     { size: () => Qt.size(settingsW, settingsSurfaceH("update")), ame: () => surfaceItem("update") },
        keybinds:   { size: () => Qt.size(settingsW, settingsSurfaceH("keybinds")), ame: () => surfaceItem("keybinds") },
        lockstyle:  { size: () => Qt.size(settingsW, settingsSurfaceH("lockstyle")), ame: () => surfaceItem("lockstyle") },
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
        screens:    () => ldScreens,
        appearance: () => ldAppearance,
        appcat:     () => ldAppcat,
        display:    () => ldDisplay,
        modules:    () => ldModules,
        profile:    () => ldProfile,
        theme:      () => ldTheme,
        accent:     () => ldAccent,
        glass:      () => ldGlass,
        fontcolor:  () => ldFontcolor,
        fontpicker: () => ldFontpicker,
        plugins:    () => ldPlugins,
        update:     () => ldUpdate,
        keybinds:   () => ldKeybinds,
        lockstyle:  () => ldLockstyle,
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
        name = pill.normSurface(name);
        if (name === "clipboard") {
            // Reclaim clipboard surface immediately on close so native input fields do not linger
            pill.dropClosed("clipboard");
            return;
        }
        // With the saver off the tier is effectively infinite, so nothing would
        // ever be swept on its own; keeping the sweep running would evict purely
        // on the residency cap, which is not what the cap is for.
        if (!Flags.memorySaver)
            return;
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

    /**
     * The face the bar is showing.
     *
     * A notch is a shape, not a face and not a width. The shape is
     * `topFlat` -- square top corners, flush against the screen edge -- and
     * it holds for every mode while the display is set to notch, so the bar
     * can expand into the hover face with its workspace dots and its status
     * cells and still read as a tab cut into the top edge.
     *
     * What must not happen is the notch pinning the RESTING face while it is
     * expanded. The resting face fades out on hover, and the hover face only
     * draws while it is the mode, so pinning the mode to "rest" in a notch
     * left both faces hidden: hovering the bar made it go completely blank,
     * with only the clock slot and the waveform still drawing. The face
     * follows the state like every other display; the setting controls the
     * shape, not which face is allowed to speak.
     */
    readonly property string mode: dragActive ? "dragOver"
        : (Flags.gameMode ? "game"
        : (pluginSurfaceOpen ? "plugin"
        : (surfaceOpen && Object.prototype.hasOwnProperty.call(pill.surfaces, surface) ? surface
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

    property bool surfaceDismissLatch: false

    onSurfaceOpenChanged: {
        if (surfaceOpen) {
            pinned = false;
            revealSession = false;
            hoverLatch = false;
            expandLatch = false;
        } else {
            surfaceDismissLatch = true;
        }
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
    onRestSizeChanged: pill.hostRoot.pillBarHeight = restSize.height
    readonly property real restRadius: roundRadius
    onRestRadiusChanged: pill.hostRoot.pillBarRadius = restRadius

    /**
     * Target geometry for the non-surface morph modes. Surface sizes come from
     * the `surfaces` descriptor; these are the pill's own modes that have no
     * surface item. Thunks so the properties they read register as live deps of
     * targetSize. osd uses its own content-driven size — the workspace flash
     * fits its dot row (so it stays short even on the wide strip notch) while
     * volume/brightness/record keep their fixed widths. The toast keeps its
     * fixed width and sizes its height to the notification.
     */
    readonly property real minFaceW: {
        switch (Flags.mainDisplay) {
            case "minimal": return 76 * s;
            case "classic": return 130 * s;
            case "system":  return 150 * s;
            // The notch's own resting face is the monitor's width, so this is
            // only the floor for the faces that borrow the resting width.
            case "notch":   return 320 * s;
            default:        return 120 * s;
        }
    }

    readonly property var modeSize: ({
        toast: () => Qt.size(toastLoader.item ? Math.max(200 * s, Math.min(380 * s, toastLoader.item.implicitWidth + 32 * s)) : 240 * s, toastLoader.item ? toastLoader.item.implicitHeight + 24 * s : restH),
        hover: () => Qt.size(hoverW, hoverH),
        dragOver:    () => Qt.size(dragOverW, dragOverH),
        game:        () => Qt.size(gameW, gameH)
    })

    /**
     * The resting face's width: its content, the capsule's inset at both
     * ends, and the room the media bud takes on the right.
     *
     * The face used to add a flat 24*s of padding and the bud's slot on top
     * of it, and the row was CENTRED in the result. That is what put all of
     * the bud's reserve on the LEFT as dead space: the resting pill opened
     * with thirty-odd pixels of nothing before its first glyph and trailed
     * another ten after the disc. The padding is now the inset at each end
     * (`restPad`), the row sits flush-left inside it, and the only space
     * between the row and the disc is the gap that was always meant to be
     * there. The two ends of the capsule now carry the same inset.
     */
    readonly property size restSize: stripBar
        ? Qt.size(stripFaceW, restH)
        : Qt.size(pill.notchBar ? pill.notchW
              : Math.max(minFaceW, (pill.recastFaceVisible && !pill.stripBar
              ? recastRestRow.implicitWidth
              : restRow.implicitWidth) + 2 * pill.restPad + pill.budSlot), restH)

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

    /**
     * AMBIENT AURA — the showpiece.
     *
     * A soft accent glow that blooms behind the pill and *listens* to whatever
     * is on the speakers, using the full cava spectrum rather than a single
     * loudness number: a bass hit widens the whole bloom, while the individual
     * band pools shimmer across the bar so the glow moves *within* a track
     * instead of pulsing as one mass. Silence puts it completely to sleep —
     * zero opacity, zero repaints.
     *
     * Two modes, because it must respect `Flags.reduceMotion`:
     *   - default: one gradient plus per-band pools, repainted per cava frame.
     *     The canvas is the pill's own size (~460×34), so a frame is a handful
     *     of small radial fills — cheap, and only ever while audio is active.
     *   - reduced motion: a single static bloom modulated purely by opacity,
     *     which the compositor owns, so nothing shimmers at all.
     *
     * In both modes the tint is the live accent, so a theme swap carries the
     * glow with it, and `Flags.auraIntensity` scales every alpha the canvas
     * paints — 0 turns the aura off without touching the visualizer.
     */
    Item {
        id: aura
        anchors.fill: parent
        // Decoration, not a hit target: it must never eat a click that belongs
        // to one of the pill's children.
        enabled: false
        visible: (aura.intensity > 0 && Cava.active) && opacity > 0.005
        /** Shimmer needs repainting; a calm bloom does not. */
        readonly property bool shimmer: !Flags.reduceMotion && Cava.active

        /** 0..1, clamped, straight from the flag — every painted alpha scales by it. */
        readonly property real intensity: Math.max(0, Math.min(1, Flags.auraIntensity))

        /**
         * The current frame's loudest band, floored so a quiet passage reads as
         * a present-but-calm room glow instead of the pill looking naked.
         */
        readonly property real auraLevel: {
            var peak = 0;
            for (var i = 0; i < Cava.bars; i++)
                if ((Cava.levels[i] || 0) > peak)
                    peak = Cava.levels[i];
            return Math.min(1, Math.max(0.10, peak * 1.15));
        }

        opacity: (aura.intensity > 0 && Flags.musicViz && Cava.active)
            ? (aura.shimmer ? 1 : aura.auraLevel)
            : 0
        Behavior on opacity { NumberAnimation { duration: Math.round(260 * Motion.mult); easing.type: Easing.OutQuad } }

        /** The glow's tint: the live accent, so it tracks every theme change. */
        readonly property color glowColor: Theme.vermLit

        function repaint() {
            if (aura.visible && aura.shimmer)
                auraCanvas.requestPaint();
        }

        Canvas {
            id: auraCanvas
            anchors.fill: parent
            smooth: true

            onPaint: {
                var ctx = getContext("2d");
                var c = aura.glowColor;
                var k = aura.intensity;
                var w = width, h = height;
                if (w < 2 || h < 2)
                    return;

                var cx = w / 2, cy = h / 2;
                var rx = Math.max(w / 2, 1);
                var ry = Math.max(h / 2, 1);
                var n = Cava.bars;
                var lvl = aura.auraLevel;

                /** Quiet-passage alphas still smear a visible haze. */
                var calm = aura.shimmer ? (0.35 + 0.65 * lvl) : 1;
                var blur = aura.shimmer ? 0.35 + 0.65 * lvl : 1;

                ctx.clearRect(0, 0, w, h);

                // Base elliptical bloom, shaped to the slab so the glow pools
                // under the bar's long edges instead of forming a circle.
                var g = ctx.createRadialGradient(cx, cy, 0, cx, cy, rx);
                g.addColorStop(0.00, Qt.rgba(c.r, c.g, c.b, 0.55 * k * calm));
                g.addColorStop(0.50, Qt.rgba(c.r, c.g, c.b, 0.18 * k * blur));
                g.addColorStop(1.00, Qt.rgba(c.r, c.g, c.b, 0.0));
                ctx.save();
                ctx.translate(cx, cy);
                ctx.scale(1, ry / rx);
                ctx.translate(-cx, -cy);
                ctx.fillStyle = g;
                ctx.fillRect(0, 0, w, h);
                ctx.restore();

                // Per-band pools. Each is a small radial fill clipped to the
                // vertical span it can touch, so a frame is a handful of cheap
                // fills rather than a full-canvas blur.
                for (var i = 0; i < n; i++) {
                    var v = Cava.levels[i] || 0;
                    if (v <= 0.015)
                        continue;
                    var bx = w * (i + 0.5) / n;
                    var br = rx * (0.16 + 0.40 * v);
                    var ba = Math.pow(v, 1.6) * 0.55 * k;
                    if (ba < 0.01)
                        continue;
                    var pg = ctx.createRadialGradient(bx, cy, 0, bx, cy, br);
                    pg.addColorStop(0.00, Qt.rgba(c.r, c.g, c.b, ba));
                    pg.addColorStop(1.00, Qt.rgba(c.r, c.g, c.b, 0.0));
                    ctx.save();
                    ctx.fillStyle = pg;
                    ctx.fillRect(bx - br, 0, br * 2, h);
                    ctx.restore();
                }
            }

            /**
             * The painted pixels depend on the tint and the canvas size; the
             * loudness is applied by the parent's opacity when shimmering is
             * off. So size changes always repaint, while shimmer mode repaints
             * per cava frame through `aura.repaint()`.
             */
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
        }

        Connections {
            target: Cava
            function onLevelsChanged() { aura.repaint(); }
        }

        // A theme swap changes glowColor, which is baked into the painted
        // pixels rather than tinted by a layer, so it needs its own repaint.
        Connections {
            target: Theme
            function onVermLitChanged() { if (aura.visible) auraCanvas.requestPaint(); }
        }

        Component.onCompleted: if (aura.visible) auraCanvas.requestPaint()
    }

    LiquidGlass {
        id: bud
        /* The media bud is the bar's entry point to the player, and an entry
         * that disappears with its content is not an entry.
         *
         * It used to need a live player, so the last player to exit took the
         * control with it and the only way back was to start audio again. The
         * always-media setting is the user's promise that the entry outlives
         * the music, and playing media keeps the bud on even with the setting
         * off.
         *
         * It shows at rest as well as on hover: the resting pill is exactly
         * where the entry has to be findable, and a control that only appears
         * once you are already looking for the bar is a control nobody finds.
         */
        readonly property bool shown: (pill.mode === "hover" || Players.justStarted) && (Flags.mediaAlways || Players.playing)
        /* The bubble does not change size. It used to swell from 24*s to 30*s
         * under the pointer, and a swell is a layout change: it has to be
         * paid for out of the gap beside the disc, which is why that gap was
         * never allowed to be a hair, and why the bar kept a slot wider than
         * the disc it was holding room for. The bud answers the pointer from
         * the inside now -- the album art swells within the glass and the
         * sheen catches the light -- so the bubble keeps its size and the
         * hair beside it stays a hair. */
        property real budR: 12 * pill.s
        width: budR * 2
        height: budR * 2
        radius: budR
        /* The bud sits at the pill's right edge, except in strip mode where it
         * moves next to the media title. The strip's media cell is at the far
         * *left* of the bar, so a disc pinned to the right edge was the single
         * hardest target on screen to find — the one element that means "media"
         * sitting as far from the media as the layout allowed, which is most of
         * why "the media thing" kept being reported as missing.
         *
         * `mapToItem`, not `stripTitle.x`: the title lives inside the strip's
         * own Row, so its raw x is in that Row's coordinates and would place the
         * disc against the left edge of the pill instead of after the title.
         *
         * The strip's row keeps a slot for the bead (see `stripBudSlot`), so
         * the disc lands in the gap the row makes for it rather than on top of
         * the visualiser that follows the title. */
        readonly property real stripBudX: {
            void pill.width;
            void pill.height;
            void stripFace.x;
            void stripTitle.x;
            void stripTitle.width;
            if (!pill.stripBar || !stripTitle || stripTitle.width <= 0)
                return -1;
            return stripTitle.mapToItem(pill, 0, 0).x + stripTitle.width + 10 * pill.s;
        }
        /* Anchored on its RIGHT edge, against the capsule's inset, so the
         * disc never leaves a hole at the right end of the bar and never
         * needs a slot wider than itself: the hair of air in front of it is
         * `budGap`, and the pill reserves the disc's width on top of that. */
        x: stripBudX >= 0 ? stripBudX : (pill.width - pill.budInset - bud.width)
        anchors.verticalCenter: parent.verticalCenter
        visible: opacity > 0.01
        opacity: shown ? 1 : 0
        style: "regular"
        legacyOpacity: Flags.pillOpacity
        accent: 0.05
        /* The bud is a piece of the pill, so it must be built from the same
         * material: `themeBackgroundFill` sits it on the desktop's own surface
         * colour rather than a generated card ramp, and `veil` is the body's own
         * readability lift. Without both the bud drifted to a different tint
         * from the bar beside it — visible the moment the theme changed, and
         * invisible in a screenshot of the pill alone. */
        veil: 0.06
        themeBackgroundFill: true
        sheenScale: (budArea.containsMouse ? 1.3 : 1)
        hovered: budArea.containsMouse
        Behavior on opacity { NumberAnimation { duration: Motion.standard } }

        // The same media disc the media surface uses, scaled into the pill. It
        // is the entry point, not a second now-playing card.
        MediaDisc {
            id: mediaBudDisc
            anchors.centerIn: parent
            width: 18 * pill.s
            height: 18 * pill.s
            s: pill.s
            spinning: budArea.containsMouse || (Players.has && Players.playing)
            coverUrl: Players.has && Players.artUrl ? Players.artUrl : ""
            /* The disc answers the pointer too: its rim takes the theme's
             * accent under the cursor, so the bud says "this is live" without
             * anything beside it having to move. */
            hovered: budArea.containsMouse
            /* The hover answer, moved inside the glass. The bubble itself keeps
             * its size so that nothing beside it has to move -- the art
             * swells instead, which is the half of the disc the eye is
             * actually looking at. 18*s inside a 24*s bubble leaves room for
             * it: the swollen art is still inside the glass. */
            scale: budArea.containsMouse ? 1.15 : 1
            Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
        }

        MouseArea {
            id: budArea
            anchors.fill: parent
            enabled: bud.shown
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.requestSurface("media")

            /* Hover opens the player too, but only on a dwell. A bare
             * onEntered would fire when the pointer sweeps across the bar on its
             * way somewhere else, which is a player nobody asked for; 260ms is
             * past a pass-through and short enough to feel like a hover.
             *
             * The guards all live in mediaEnter()/mediaLeave() so the bud, the
             * strip art and the strip title cannot disagree about when the
             * player appears. */
            onEntered: pill.mediaEnter()
            onExited: pill.mediaLeave()
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
        property real topFlat: (pill.mode === "game" || pill.notchBar) ? 1 : 0
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
        layer.enabled: !pill.hidden
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
        if (soulTarget === "profile")
            return osMark.mapToItem(pill, osMark.width / 2, osMark.height + drop * 0.55);
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
    /**
     * One media-entry contract, shared by every element that means "media".
     *
     * The bud, the strip's album art and the strip's track title all hand their
     * hover to `mediaEnter()`/`mediaLeave()`, so there is exactly one dwell and
     * one guard set for "the pointer means media". This used to be per-site
     * logic, and the two available answers were both wrong: a pill-wide hover
     * opened the player when you pointed at the *weather* cell (one setting
     * hijacking navigation across the whole bar), and a bud-only hover left a
     * 21px disc as the sole target in a bar 500px wide.
     *
     * The result is one rule: hover the media — its art, its title, or its disc
     * — and the player arrives after a short dwell. Hover anything else and the
     * pill is just the pill. Nothing playing means no media to enter, so the
     * rule has nothing to fire on.
     */
    function mediaEnter() {
        if (pill.mode === "game" || pill.surfaceOpen || pill.dragActive || !pill.bootSettled)
            return;
        surfaceDismissLatch = false;
        pill.requestSurface("media");
    }

    function mediaLeave() {
        mediaHoverDwell.stop();
    }

    Timer {
        id: mediaHoverDwell
        interval: 260
        onTriggered: {
            // Re-checked at fire time, not only at entry: a surface can open, a
            // drag can start, or game mode can arm during the dwell.
            if (pill.mode === "game" || pill.surfaceOpen || pill.dragActive
                || !pill.hasMedia)
                return;
            pill.requestSurface("media");
        }
    }

    readonly property real inputPadRight: bud.shown ? bud.budR + 2 * s : 0

    /**
     * MEDIA AUTO-DISMISS — the card is for what is playing, the bud is the
     * entry point. Those are two different jobs and only one of them should be
     * persistent.
     *
     * The card used to stay open forever. Open it while a track plays, let the
     * track end, and the pill held a surface reading "Nothing playing" over the
     * desktop until something else was clicked — the one state where a media
     * card is actively wrong, left on screen indefinitely.
     *
     * So it closes itself a beat after playback stops, and re-opening on a new
     * track is instant because a restart cancels the pending dismiss.
     *
     * The bud is deliberately untouched by this: the bud's own visibility
     * comes from the always-media setting and from playback, never from the
     * card being open. So whatever this timer does to the card, the way back
     * into the player stays on the bar — the entry outlives the thing it
     * opens, which is the whole point of the setting. A user who wants the
     * card to persist across a pause still has the media surface's own open
     * state; this only fires once *nothing* is playing, which is the state
     * the card cannot say anything useful about.
     */
    Timer {
        id: mediaAutoDismiss
        interval: 2600
        onTriggered: {
            // `Players.has`, not `Players.playing`: a paused track is still media
            // worth looking at, so the card holds for it. It is the no-player
            // state — the one reading "Nothing playing" — that has nothing to
            // say and must not sit over the desktop.
            if (pill.mediaOpen && !Players.has && pill.mode !== "game")
                pill.requestClose();
        }
    }

    /** Only ever armed while the card is actually open. */
    onMediaOpenChanged: {
        if (!mediaOpen)
            mediaAutoDismiss.stop();
        else if (!Players.has)
            mediaAutoDismiss.restart();
    }

    Connections {
        target: Players
        function onPlayingChanged() {
            if (Players.isActualMedia) {
                mediaAutoDismiss.stop();
                pill.surfaceDismissLatch = false
                /* The card ANNOUNCES the media, and it announces it ONCE. A
                 * pause is not a start, so pressing play again is a resume, not
                 * a new thing happening. */
                if (!Players.justStarted)
                    return;
                if (!pill.mediaOpen && !pill.recastActive && !pill.surfaceOpen && !pill.pluginSurfaceOpen && !Flags.gameMode && !pill.anyFullscreen && pill.mode !== "game" && !pill.toastActive) {
                    pill.requestSurface("media");
                }
            } else if (pill.mediaOpen && !Players.has) {
                mediaAutoDismiss.restart();
            }
        }
        function onTitleChanged() {
            if (!Players.justStarted || pill.mediaOpen)
                return;
            if (Players.isActualMedia && !pill.recastActive && !pill.surfaceOpen && !pill.pluginSurfaceOpen && !Flags.gameMode && !pill.anyFullscreen && pill.mode !== "game" && !pill.toastActive) {
                pill.surfaceDismissLatch = false
                pill.requestSurface("media");
            }
        }
    }

    /**
     * Should the media island be showing right now?
     *
     * One predicate, deliberately not event-driven. Every hover signal that
     * *could* re-show the card is produced by an element the card suppresses:
     * the strip face row's visibility, the window-level HoverHandler, and
     * `onPositionChanged` (which needs movement). An event-driven version is
     * therefore correct exactly once — on the entry that opened it — and then
     * has no path back. That asymmetry is the whole bug, so the condition is
     * polled instead: the state is a fact about geometry, and geometry does not
     * stop reporting because something moved on top of it.
     *
     * `surfaceDismissLatch` is the only thing that can say no, which is what
     * makes an explicit dismissal (right-click, Escape) stick instead of
     * springing back under the pointer that asked for it. It clears on hover
     * entry, so "come back later" always works.
     */
    function checkMediaHover() {
        if (pill.hasMedia && Players.playing && !pill.expandLatch && !pill.hoverLatch
            && !pill.surfaceOpen && !pill.dragActive
            && !surfaceDismissLatch
            && bootSettled && !toastActive && !pill.recastActive) {
            pill.requestSurface("media");
            return true;
        }
        return false;
    }

    /**
     * The re-show watchdog.
     *
     * Runs only in the exact state the user describes — pointer in the bar,
     * media exists, nothing dismissed — so it is idle the rest of the time and
     * costs one property read per tick. It exists to cover the gap between
     * "the island closed" and "the pointer moves again": without it the card
     * cannot return until the pointer leaves the bar entirely, because no hover
     * event is generated by an island that is not there to generate one.
     */
    Timer {
        id: mediaShowWatch
        interval: 160
        repeat: true
        running: pill.hovered && pill.hasMedia && !pill.surfaceDismissLatch
            && !Flags.gameMode && pill.mode !== "game" && !pill.dragActive
        onTriggered: pill.checkMediaHover()
    }

    onHoveredChanged: {
        if (hovered && pill.mode !== "game") {
            /* Re-entering the bar always re-arms the island. The latch is the
             * "the user dismissed this on purpose" memory and it is scoped to
             * one visit: leaving clears it (below), and so does arriving, so
             * stepping away and back always gets the card. */
            surfaceDismissLatch = false;
            islandDismiss.stop();
            if (pill.checkMediaHover()) {
                // hovering resting pill expands directly to media card
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
            /* The floating island is bound to the bar's hover, not the card's.
             * Its own leave-guard is off while floating precisely so gliding from
             * the island down onto the strip is a *reach for the bar's cells*,
             * not a dismissal — so this is the only place that can close it.
             * The delay matches the card's own so a step past the bar's edge and
             * back does not strobe. */
            if (pill.mediaFloats && !pinned && !hoverLatch && !expandLatch && !revealSession)
                islandDismiss.restart();
        }
    }

    /**
     * Closing grace for the floating island. Armed only by hover *exit*, so a
     * re-entry inside the window cancels it and the island survives.
     */
    Timer {
        id: islandDismiss
        interval: 200
        onTriggered: {
            if (pill.mediaFloats && !pill.hovered && !pill.pinned && !pill.dragActive
                && pill.mode !== "game")
                pill.requestClose();
        }
    }

    Timer {
        id: graceTimer
        interval: 220
        onTriggered: {
            if (!pill.pinned) {
                pill.hoverLatch = false;
                pill.expandLatch = false;
            }
            if (!pill.hovered && !pill.pinned && pill.mediaOpen) {
                pill.surfaceDismissLatch = true;
                pill.requestClose();
            }
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
            /* The media takeover needs the same guard the hover path gives it
             * (the expandTo branch above): `!Flags.autoHide && !pill.stripBar`.
             * Without it a click on the auto-hidden strip opened the media
             * surface instead of expanding the pill, and the hoverLatch toggle --
             * the only expand entry point while a reveal session holds the pill
             * -- was dead whenever something was playing. In strip mode the tap
             * expands the pill, like every other click on it.
             *
             * The tap asks for the media card only when there is media to show
             * (`mediaContent`), not merely because the entry is on the bar: a
             * click on a resting pill should pin the pill, not open a card that
             * has nothing to say. */
            if (Flags.expandTo === "media" && pill.mediaContent
                && !Flags.autoHide && !pill.stripBar) {
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
            if (pill.mediaOpen) {
                pill.surfaceDismissLatch = true;
                pill.requestClose();
            } else {
                pill.surfaceDismissLatch = false;
                pill.requestSurface("media");
            }
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
        /**
         * The resting face hands the pill to an open surface by fading out.
         *
         * `!pill.mediaFloats` is the whole floating-island design: an island is
         * *not* the pill taking over, it is the pill keeping its face while a
         * card hovers above it. Fading `rest` here took the strip down with it —
         * and because `rest.visible` follows this opacity, the subtree went
         * `visible: false`, not merely transparent. So the bar's cells were not
         * just dim while the island was up, they were *gone*, which is what made
         * "reach the weather cell" impossible.
         *
         * This was the real cause behind the binding looking correct and the
         * row still not rendering: `stripFace.visible` was true, its parent was
         * not.
         */
        opacity: ((pill.expanded && !pill.pluginPopupOpen && !pill.mediaFloats) || pill.dragActive || pill.mode === "game" || pill.mode === "toast") ? 0 : Math.pow(pill.morphCloseness, 1.5)
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

        // Invisible hover overlay for the strip face — triggers pulse effects and media auto-show
        MouseArea {
            id: stripFaceMouse
            anchors.fill: parent
            anchors.margins: -8 * pill.s
            hoverEnabled: true
            z: -1
            enabled: !Flags.gameMode
            onContainsMouseChanged: {
                if (ws) ws.pulseMode = containsMouse;
                if (containsMouse && !pill.surfaceOpen) {
                    pill.checkMediaHover();
                }
            }
            onPositionChanged: {
                if (!pill.surfaceOpen) {
                    pill.checkMediaHover();
                }
            }
        }

        Row {
            id: stripFace
            visible: pill.specialView === "" && !pill.recastActive && pill.stripBar && (!pill.surfaceOpen || pill.pluginPopupOpen || pill.mediaFloats) && !Flags.gameMode
            anchors.centerIn: parent
            spacing: pill.stripGap

            Rectangle {
                id: stripArt
                anchors.verticalCenter: parent.verticalCenter
                visible: pill.stripMediaEntry
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
                /* Nothing playing and no artwork to show: the tile is still the
                 * entry that opens the player, so it carries the media glyph
                 * rather than sitting there as a blank square. */
                GlyphIcon {
                    anchors.centerIn: parent
                    width: parent.width - 9 * pill.s
                    height: parent.height - 9 * pill.s
                    name: "music"
                    color: Theme.faint
                    visible: stripArtImg.status !== Image.Ready && stripArtIcon.status !== Image.Ready
                }

                MouseArea {
                    id: stripArtMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.MiddleButton) {
                            if (Players.active && Players.active.canTogglePlaying)
                                 Players.active.togglePlaying();
                        } else {
                            pill.requestSurface("media");
                        }
                    }
                    onWheel: (wheel) => {
                        if (Players.active && Players.active.volume !== undefined) {
                            var delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                            Players.active.volume = Math.max(0.0, Math.min(1.0, Players.active.volume + delta));
                        }
                    }
                    /* The album art is the largest thing on the strip that means
                     * media, so it carries the same hover contract as the bud. */
                    onEntered: pill.mediaEnter()
                    onExited: pill.mediaLeave()
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

                MouseArea {
                    id: stripTitleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.MiddleButton) {
                            if (Players.active && Players.active.canTogglePlaying)
                                Players.active.togglePlaying();
                        } else {
                            pill.requestSurface("media");
                        }
                    }
                    onWheel: (wheel) => {
                        if (Players.active && Players.active.volume !== undefined) {
                            var delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                            Players.active.volume = Math.max(0.0, Math.min(1.0, Players.active.volume + delta));
                        }
                    }
                    /* The track title is the other half of the same target, so
                     * hovering it enters media exactly as the art and the disc
                     * do. */
                    onEntered: pill.mediaEnter()
                    onExited: pill.mediaLeave()
                }

                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: Players.title || "Media"
                    desc: (Players.artist.length > 0 ? Players.artist + (Players.serviceLabel.length > 0 ? " · " + Players.serviceLabel : "") : (Players.serviceLabel || "Scroll: volume · Middle: pause"))
                    show: stripTitleMouse.containsMouse || stripArtMouse.containsMouse
                }
            }

            /* The media bud rides next to the strip's title, so the row keeps a
             * slot for it: without the spacer the bead would land on the
             * visualiser and the hairline that follow the title. The slot is
             * a fixed width so hovering the bud — which makes it grow — never
             * reflows the bar under the pointer.
             *
             * It is only that wide when the bud IS riding there. With no
             * track to sit after, the bud falls back to the pill's right
             * corner -- and this slot stayed 40*s wide anyway, so the row
             * carried a fist of empty capsule in the middle of the bar with
             * nothing in it. The room is handed to the corner slot below
             * instead, so the bar reserves the bud once, where the bud is. */
            Item {
                id: stripBudSlot
                anchors.verticalCenter: parent.verticalCenter
                width: (pill.stripBar && bud.shown && bud.stripBudX >= 0) ? 40 * pill.s : 0
                height: 1
            }

            MusicBars {
                id: stripViz
                anchors.verticalCenter: parent.verticalCenter
                visible: pill.stripMedia && Cava.active
                s: pill.s
                span: 14
            }
            Rectangle {
                visible: pill.stripMedia
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 14 * pill.s
                color: Theme.hair
            }

            AltText {
                id: stripDay
                anchors.verticalCenter: parent.verticalCenter
                text: clock.weekday
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 12 * pill.s
                font.weight: Font.DemiBold
                scale: pill.stripHover ? 1.05 : 1
                Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
            }
            AltText {
                id: stripTime
                anchors.verticalCenter: parent.verticalCenter
                text: clock.hhmm
                color: Theme.bright
                font.family: Theme.font
                font.pixelSize: 17 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            AltText {
                id: stripWs
                anchors.verticalCenter: parent.verticalCenter
                text: ws.activeWs
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: 12 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                scale: pill.stripHover ? 1.1 : 1
                Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
            }
            AltText {
                id: stripLay
                anchors.verticalCenter: parent.verticalCenter
                text: kbLayout.code
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 12 * pill.s
                font.weight: Font.DemiBold

                MouseArea {
                    id: stripLayMouse
                    anchors.fill: parent
                    anchors.margins: -4 * pill.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: kbLayout.cycle()
                }

                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: "Keyboard layout"
                    desc: "Click to cycle layout (" + kbLayout.code + ")"
                    show: stripLayMouse.containsMouse
                }
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
                    scale: 1
                    SequentialAnimation on scale {
                        running: Battery.charging
                        loops: Animation.Infinite
                        NumberAnimation { to: 1.15; duration: 600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
                    }
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
            Item {
                id: stripUpdate
                visible: Updater.omarchyUpdateAvailable
                anchors.verticalCenter: parent.verticalCenter
                width: 16 * pill.s
                height: 16 * pill.s

                GlyphIcon {
                    anchors.centerIn: parent
                    width: 13 * pill.s
                    height: 13 * pill.s
                    name: "refresh"
                    color: Theme.accent
                    stroke: 1.8
                }

                MouseArea {
                    id: stripUpdateMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (Updater.omarchyUpdateAvailable) {
                            Updater.runOmarchyUpdate();
                        } else {
                            pill.requestSurface("update");
                        }
                    }
                }

                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: "Omarchy update available"
                    desc: "Click to run omarchy-update"
                    show: stripUpdateMouse.containsMouse
                }
            }

            /**
             * The room the media bud takes when it cannot ride next to the
             * title.
             *
             * With no track to sit after, the bud falls back to the pill's
             * right corner -- and the row's last items ran straight under it:
             * the disc painted itself over the keyboard layout. This is that
             * room, at the end of the row, where the disc actually is, and
             * the slot above gives its width back at the same time. One
             * reserve, never two.
             *
             * The number is the disc's own width plus its inset, less the
             * notch's own padding: what is left over once the notch's end
             * and the disc's corner have each taken their share.
             */
            Item {
                id: stripCornerSlot
                anchors.verticalCenter: parent.verticalCenter
                width: (pill.stripBar && bud.shown && bud.stripBudX < 0)
                    ? (budRestW + budInset - stripPad)
                    : 0
                height: 1
            }
        }

        /* Floating visualizer: when music is playing but the strip budget can't
         * afford the full media-title block, the spark still deserves a place to
         * live instead of blinking out. This item is centered over the rest of the
         * strip face so the bars sit in the middle of the bar, not pushed to one
         * edge by the trailing day/time/workspace/battery row. Cava.active is only
         * true while audio is actually playing, so with nothing sounding the pills
         * stays empty. */
        Item {
            id: stripVizFloat
            anchors.centerIn: stripFace
            visible: stripFace.visible && Cava.active && Flags.musicViz && !pill.stripMedia
            width: stripVizFloatBars.width
            height: stripVizFloatBars.height
            MusicBars {
                id: stripVizFloatBars
                anchors.centerIn: parent
                s: pill.s
                span: 14
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
            id: stripSpecialFace
            visible: !pill.recastActive && pill.specialView !== "" && (!pill.surfaceOpen || pill.pluginPopupOpen || pill.mediaFloats)
            anchors.centerIn: parent
            spacing: 8 * pill.s

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 18 * pill.s
                height: 18 * pill.s
                radius: 5 * pill.s
                color: Qt.alpha(Theme.accent, 0.18)
                border.width: 1
                border.color: Qt.alpha(Theme.accent, 0.45)

                GlyphIcon {
                    anchors.centerIn: parent
                    width: 11 * pill.s
                    height: 11 * pill.s
                    name: "bookmark"
                    color: Theme.accent
                    stroke: 1.8
                }
            }

            AltText {
                id: stripSpecialLabel
                anchors.verticalCenter: parent.verticalCenter
                text: pill.specialView
                font.family: Theme.font
                font.pixelSize: 13 * pill.s
                font.weight: Font.Bold
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 5 * pill.s
                height: 5 * pill.s
                radius: 2.5 * pill.s
                color: Theme.accent
            }
        }

        // Wrapped in an Item because a Row cannot take centerIn/fill anchors on
        // its children — doing so makes QML drop the Row's layout entirely
        // ("Row will not function"), which scattered the chip's contents.
        Item {
            id: stripRecordingBox
            /* No surface/popup gate: a live recording is the one state that must
             * always be readable, including while a surface is open or the pill
             * is morphing between faces.
             *
             * Strip-mode only. The resting face has its OWN mirror of this
             * chip (`recastRestRow`, gated `!pill.stripBar`), because the
             * resting row hides itself the moment a recording starts
             * (`!pill.recastActive`) and this chip is what takes its place --
             * without the mirror, the normal pill showed an EMPTY capsule for
             * the whole take: no REC, no countdown, no elapsed count. The two
             * gates have to be exact opposites, or BOTH render in strip mode
             * and the pill draws a second REC face over the first. */
            visible: pill.recastFaceVisible
            /* The chip takes the row's place when the bar is recording, so it
             * stands where the row stands: flush-left inside the capsule's
             * inset, with the disc on its right. Centred in the pill it would
             * sit half-way into the disc's reserve. */
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: pill.stripBar ? 0 : pill.restFaceOffset
            anchors.verticalCenter: parent.verticalCenter
            width: stripRecordingFace.implicitWidth
            height: stripRecordingFace.implicitHeight

            Row {
                id: stripRecordingFace
                anchors.centerIn: parent
                spacing: 8 * pill.s

                Rectangle {
                    width: 18 * pill.s
                    height: 18 * pill.s
                    radius: 9 * pill.s
                    color: Qt.rgba(0.95, 0.18, 0.22, 0.22)
                    border.width: 1
                    border.color: Qt.rgba(0.95, 0.22, 0.28, 0.6)

                    Rectangle {
                        anchors.centerIn: parent
                        width: 7 * pill.s
                        height: 7 * pill.s
                        radius: 3.5 * pill.s
                        color: Recast.countdownPending ? Theme.accent : (Recast.paused ? "#ff9f0a" : "#ff3b30")

                        opacity: (Recast.recording && !Recast.paused && (Recast._tick % 2 === 1)) ? 0.35 : 1.0
                        Behavior on opacity {
                            NumberAnimation { duration: 250 }
                        }
                    }
                }

                Text {
                    text: Recast.countdownPending ? "STARTING" : (Recast.paused ? "PAUSED" : "REC")
                    font.family: Theme.font
                    font.pixelSize: 11 * pill.s
                    font.weight: Font.Black
                    color: Recast.countdownPending ? Theme.accent : (Recast.paused ? "#ff9f0a" : "#ff453a")
                    height: 18 * pill.s
                    verticalAlignment: Text.AlignVCenter
                }

                Text {
                    id: stripRecordingTimer
                    text: Recast.countdownPending ? Recast.formattedCountdown : Recast.formattedTime
                    font.family: Theme.font
                    font.pixelSize: 12.5 * pill.s
                    font.weight: Font.Bold
                    color: Theme.cream
                    height: 18 * pill.s
                    verticalAlignment: Text.AlignVCenter
                }
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -4 * pill.s
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function (mouse) {
                    if (mouse.button === Qt.RightButton) {
                        pill.requestPluginSurface("pix.recast", true);
                    } else {
                        Recast.toggleRecording();
                    }
                }
            }
        }

        /**
          * Agent needs you — the strip face's copy of the badge.
          *
          * The workspace strip already carries the badge, but that strip only
          * exists while the pill is expanded (the `hover` face fades to 0 at
          * rest). That is the wrong place for the one signal that is supposed
          * to interrupt you: you would have to already be looking at the bar to
          * find out that something was waiting. So `waiting` gets a chip on the
          * resting pill in whichever face it happens to be using.
          *
          * Only `waiting` qualifies. A `working` agent is not news, and a badge
          * for it would sit on the bar all day training you to ignore the chip.
          *
          * Suppressed while recasting, because both are centred in the same
          * face and a recording is the louder claim on that space.
          *
          * Wrapped in an Item for the same reason the recording chip is: a Row
          * drops its layout entirely if you anchor its children.
          */
        Item {
            id: stripAgentBox
            visible: !pill.recastActive && pill.stripBar && Agents.urgent > 0
            anchors.centerIn: parent
            width: stripAgentFace.implicitWidth
            height: stripAgentFace.implicitHeight

            Row {
                id: stripAgentFace
                anchors.centerIn: parent
                spacing: 8 * pill.s

                Rectangle {
                    id: agentChip
                    width: 18 * pill.s
                    height: 18 * pill.s
                    radius: 9 * pill.s
                    color: Qt.rgba(0.95, 0.18, 0.22, 0.22)
                    border.width: 1
                    border.color: Qt.rgba(0.95, 0.22, 0.28, 0.6)

                    // The same breath the workspace badge uses, so the two read
                    // as one signal rather than two unrelated decorations.
                    readonly property real beat: 0.5 + 0.5 * Math.sin(pill.agentTick * 0.85)
                    opacity: 0.45 + 0.55 * agentChip.beat
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                    Text {
                        anchors.centerIn: parent
                        text: "!"
                        color: Theme.vermLit
                        font.family: Theme.font
                        font.pixelSize: 11 * pill.s
                        font.weight: Font.Bold
                    }
                }
            }
        }

        Row {
            id: restRow
            visible: !pill.stripBar && opacity > 0.01
            opacity: (pill.mode === "rest" && !pill.recastActive) ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            /**
             * The row is NOT centred in the pill.
             *
             * The media bud owns the pill's right edge, so a centred row
             * would push half of the bud's reserve out of the LEFT side as
             * dead space -- which is exactly what the bar used to do: it
             * opened with a third of a pill's width of nothing before the
             * waveform. The row sits flush-left inside the capsule's inset
             * instead, and the offset below is what puts it there: the
             * content group (row, gap, disc) stays centred on the screen,
             * while the row itself starts at the inset.
             *
             * The offset is written from the bud's reserve rather than from
             * the pill's live width, because the pill's width animates during
             * a morph and the row must not drift while it does.
             */
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: pill.restFaceOffset
            anchors.verticalCenter: parent.verticalCenter
            /**
             * The row's rhythm.
             *
             * Nine scaled pixels between every pair of items was nine pixels
             * of nothing between the waveform and the date, again between the
             * date and the divider, again between the divider and the time.
             * Five is enough for two pieces of information to sit apart and
             * little enough that the bar reads as ONE group of information
             * rather than five things standing on a shelf.
             */
            spacing: pill.notchBar ? pill.notchSpacing : 5 * pill.s
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
                visible: !pill.recastActive && (pill.specialView === "" || pill.notchBar)
                    && (Flags.mainDisplay === "system" ? barsOn : slotUsed)
                // The Row measures implicit widths; an Item placed by a
                // bound width would otherwise report zero (notch-width).
                implicitWidth: width
                anchors.verticalCenter: parent.verticalCenter
                /**
                 * The slot is as big as the LARGER of the two things that
                 * live in it. It used to be exactly the clock glyph's box,
                 * which is narrower than seven spectrum bars, so the bars
                 * hung out of their own slot and into the date beside them
                 * -- and in the notch, where there is no slack at all, they
                 * were the first thing to go missing.
                 *
                 * The size is the MAXIMUM of the two, so it never changes:
                 * the bar does not grow when the music starts and shrink
                 * when it stops. It only ever has room for both.
                 */
                width: Math.max(clockGlyph.width, musicBars.width)
                height: Math.max(clockGlyph.height, musicBars.height)

                /**
                 * Audio leaving the speakers flips the clock face over to the
                 * live waveform.
                 *
                 * The waveform used to be tied to a MOMENT -- the five seconds
                 * after a track started -- and to a PLAYER. Both were wrong. A
                 * bar that is open hides the resting row, so the "open" half
                 * of the old condition could never be seen; and a moment is
                 * not a state, so the one thing the bar is best at -- saying
                 * what is playing RIGHT NOW -- lasted five seconds and then
                 * went back to a clock.
                 *
                 * It is a state now: audio is coming out of the machine, so
                 * the bar shows the audio. `Cava.active` is the honest
                 * signal, because cava watches the default sink and hears
                 * anything at all -- a game, a video, a call -- not only what
                 * an MPRIS player is willing to admit to. The player check
                 * stays as a second door, not a gate: with no player at all
                 * the audio is still real.
                 */
                readonly property bool barsOn: Flags.musicViz && Cava.active && (Players.playing || !Players.has)

                GlyphIcon {
                    id: clockGlyph
                    anchors.centerIn: parent
                    opacity: (Flags.clockIcon && !restClock.barsOn) ? 1 : 0
                    visible: opacity > 0
                    width: pill.iconCell
                    height: pill.iconCell
                    name: "clock"
                    color: Theme.accent
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
                visible: !pill.recastActive && pill.specialView === "" && Flags.mainDisplay === "minimal"
                anchors.verticalCenter: parent.verticalCenter
                text: clock.hhmm
                color: Theme.bright
                font.family: Theme.font
                font.pixelSize: 16 * pill.s
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
            /**
             * The date and the time, as one group.
             *
             * They used to be two children of the row with a hairline between
             * them, and the hairline was not free: it cost a divider PLUS a
             * full row gap on each side, so the pair spent as much space on
             * the gap around the rule as the rule itself. The rule is gone.
             *
             * The separation is now made of air and of type. The date is a
             * small dim label; the time is a large bright one; and the two
             * stand a whole gap apart inside their own group, which keeps
             * them reading as two readings of the moment rather than one
             * run-together string -- "Wed 21 Oct" and "7:21 PM" are still two
             * things, and the bar is narrower for it.
             */
            Row {
                id: restDateTime
                // The notch shows the CLASSIC content. It is a different box,
                // not a different bar -- so the date and the time come with it.
                visible: !pill.recastActive
                    && (Flags.mainDisplay === "classic" || pill.notchBar)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 9 * pill.s
                AltText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: clock.date
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 11 * pill.s
                    font.weight: Font.Medium
                }
                AltText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: clock.hhmm
                    color: Theme.bright
                    font.family: Theme.font
                    font.pixelSize: 15.5 * pill.s
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }
            }
            Rectangle {
                id: restWsBadge
                visible: !pill.recastActive && ws && ws.activeWs !== ""
                // See restClock: a Row measures implicit widths, and this
                // badge is placed by an explicit width.
                implicitWidth: width
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(18 * pill.s, restWsText.implicitWidth + 10 * pill.s)
                height: 17 * pill.s
                radius: 8.5 * pill.s
                color: Qt.alpha(Theme.accent, 0.14)
                border.width: 1
                border.color: Qt.alpha(Theme.accent, 0.32)

                Text {
                    id: restWsText
                    anchors.centerIn: parent
                    text: ws ? ws.activeWs : "1"
                    color: Theme.accent
                    font.family: Theme.font
                    font.pixelSize: 10 * pill.s
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }

                MouseArea {
                    id: wsBadgeMouse
                    anchors.fill: parent
                    anchors.margins: -4 * pill.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        pill.hoverLatch = !pill.hoverLatch;
                    }
                }

                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: "Workspace " + (ws ? ws.activeWs : "1")
                    desc: "Click to toggle control center"
                    show: wsBadgeMouse.containsMouse && pill.mode === "rest"
                }
            }
            /**
             * The weekday and the time, as one group.
             *
             * The same treatment the classic face gives its date: the pair
             * stands a whole gap apart inside a group of its own, so the
             * row's tighter rhythm never squeezes the two readings together.
             */
            Row {
                id: restWeekTime
                visible: !pill.recastActive && pill.specialView === "" && Flags.mainDisplay === "system"
                anchors.verticalCenter: parent.verticalCenter
                spacing: 9 * pill.s
                AltText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: clock.weekday
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 11 * pill.s
                    font.weight: Font.DemiBold
                }
                AltText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: clock.hhmm
                    color: Theme.bright
                    font.family: Theme.font
                    font.pixelSize: 15 * pill.s
                    font.weight: Font.DemiBold
                    font.features: { "tnum": 1 }
                }
            }
            AltText {
                visible: !pill.recastActive && pill.specialView === "" && Flags.mainDisplay === "system"
                    && ws.activeWs !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: ws.activeWs
                color: Theme.accent
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
            }
            AltText {
                visible: !pill.recastActive && pill.specialView === "" && Flags.mainDisplay === "system"
                anchors.verticalCenter: parent.verticalCenter
                text: kbLayout.code
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 11 * pill.s
                font.weight: Font.DemiBold

                MouseArea {
                    id: sysLayMouse
                    anchors.fill: parent
                    anchors.margins: -4 * pill.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: kbLayout.cycle()
                }

                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: "Keyboard layout"
                    desc: "Click to cycle layout (" + kbLayout.code + ")"
                    show: sysLayMouse.containsMouse
                }
            }
            Row {
                visible: !pill.recastActive && pill.specialView === "" && Flags.mainDisplay === "system"
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
                visible: !pill.recastActive && pill.specialView !== "" && !pill.notchBar
                anchors.verticalCenter: parent.verticalCenter
                text: pill.specialView
                font.family: Theme.font
                font.pixelSize: 16 * pill.s
                font.weight: Font.DemiBold
            }

            Item {
                // The mirror of stripRecordingBox's gate. That one is
                // `recastActive && stripBar`; without the `!stripBar` half
                // here both render at once in strip mode and the pill draws a
                // second REC face over the first -- the doubled, offset
                // outline you see while recording.
                visible: false
                anchors.verticalCenter: parent.verticalCenter
                width: recastRestRow.implicitWidth
                height: recastRestRow.implicitHeight

                Row {
                    id: recastRestRow
                    anchors.centerIn: parent
                    spacing: 8 * pill.s

                    Rectangle {
                        width: 18 * pill.s
                        height: 18 * pill.s
                        radius: 9 * pill.s
                        color: Qt.rgba(0.95, 0.18, 0.22, 0.22)
                        border.width: 1
                        border.color: Qt.rgba(0.95, 0.22, 0.28, 0.6)

                        Rectangle {
                            anchors.centerIn: parent
                            width: 7 * pill.s
                            height: 7 * pill.s
                            radius: 3.5 * pill.s
                            color: Recast.countdownPending ? Theme.accent : (Recast.paused ? "#ff9f0a" : "#ff3b30")

                            opacity: (Recast.recording && !Recast.paused && (Recast._tick % 2 === 1)) ? 0.35 : 1.0
                            Behavior on opacity {
                                NumberAnimation { duration: 250 }
                            }
                        }
                    }

                    Text {
                        text: Recast.countdownPending ? "STARTING" : (Recast.paused ? "PAUSED" : "REC")
                        font.family: Theme.font
                        font.pixelSize: 11 * pill.s
                        font.weight: Font.Black
                        color: Recast.countdownPending ? Theme.accent : (Recast.paused ? "#ff9f0a" : "#ff453a")
                        height: 18 * pill.s
                        verticalAlignment: Text.AlignVCenter
                    }

                    Text {
                        text: Recast.countdownPending ? Recast.formattedCountdown : Recast.formattedTime
                        font.family: Theme.font
                        font.pixelSize: 12.5 * pill.s
                        font.weight: Font.Bold
                        color: Theme.cream
                        height: 18 * pill.s
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4 * pill.s
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: function (mouse) {
                        if (mouse.button === Qt.RightButton) {
                            pill.requestPluginSurface("pix.recast", true);
                        } else {
                            Recast.toggleRecording();
                        }
                    }
                }
            }

            /**
              * Agent needs you — this face's copy of the badge, and the one you
              * will actually see, since the workspace strip it also appears on
              * only exists while the pill is expanded.
              *
              * Two faces means two copies of the chip, but they are not showing
              * at once: this row is `!pill.stripBar` and the other chip is
              * `pill.stripBar`. Keeping them in their own faces is what lets
              * each stay simple — a centred chip in this row would sit right on
              * top of the clock, so this one is appended and let the Row lay it
              * out after everything else.
              *
              * Only `waiting` earns a chip. A working agent is not news, and a
              * badge for it would sit on the bar all day teaching you to ignore
              * the one thing that does matter.
              */
            Rectangle {
                id: restAgentChip
                anchors.verticalCenter: parent.verticalCenter
                visible: Agents.urgent > 0
                // See restClock: the Row measures implicit widths.
                implicitWidth: width
                width: 18 * pill.s
                height: 18 * pill.s
                radius: 9 * pill.s
                color: Qt.rgba(0.95, 0.18, 0.22, 0.22)
                border.width: 1
                border.color: Qt.rgba(0.95, 0.22, 0.28, 0.6)

                readonly property real beat: 0.5 + 0.5 * Math.sin(pill.agentTick * 0.85)
                opacity: 0.45 + 0.55 * restAgentChip.beat
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Text {
                    anchors.centerIn: parent
                    text: "!"
                    color: Theme.vermLit
                    font.family: Theme.font
                    font.pixelSize: 11 * pill.s
                    font.weight: Font.Bold
                }
            }
            Item {
                id: restUpdate
                visible: Updater.omarchyUpdateAvailable
                // See restClock: the Row measures implicit widths.
                implicitWidth: width
                anchors.verticalCenter: parent.verticalCenter
                width: 16 * pill.s
                height: 16 * pill.s

                GlyphIcon {
                    anchors.centerIn: parent
                    width: 13 * pill.s
                    height: 13 * pill.s
                    name: "refresh"
                    color: Theme.accent
                    stroke: 1.8
                }

                MouseArea {
                    id: restUpdateMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (Updater.omarchyUpdateAvailable) {
                            Updater.runOmarchyUpdate();
                        } else {
                            pill.requestSurface("update");
                        }
                    }
                }

                Tooltip {
                    s: pill.s
                    placement: "below"
                    title: "Omarchy update available"
                    desc: "Click to run omarchy-update"
                    show: restUpdateMouse.containsMouse
                }
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
            /* Flush-left inside the expanded face's own padding, for the same
             * reason the resting row is: the disc keeps the right corner, and
             * a centred row would push half of that reserve out of the left
             * side as dead air. */
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: pill.hoverFaceOffset
            anchors.verticalCenter: parent.verticalCenter
            /**
             * The gap between the expanded face's sections.
             *
             * Sixteen scaled pixels put a fourteen-pixel void between the
             * logo and the workspace dots, which is the one place the
             * expanded bar read as two things rather than one. Eleven is
             * still a clear section break at this size and it stops the
             * middle of the bar looking empty.
             */
            spacing: 11 * pill.s

            OsMark {
                id: osMark
                anchors.verticalCenter: parent.verticalCenter
                s: pill.s
                enabled: hover.live
                onActivated: pill.requestSurface("profile")
                onContainsMouseChanged: if (containsMouse) pill.soulTarget = "profile"
            }

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
                id: hoverClockBox
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
                        color: Theme.bright
                        font.family: Theme.font
                        font.pixelSize: 18 * pill.s
                        font.weight: Font.DemiBold
                        font.features: { "tnum": 1 }
                    }
                    AltText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: clock.date
                        color: Theme.dim
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
                        hostPill: pill
                        s: pill.s
                        hoverLive: hover.live
                        barHeightOverride: pill.height
                        barWidthOverride: pill.width
                    }
                }

                // Ghost strip: dimmed icons for disabled-but-compatible plugins,
                // revealed on hover at the end of the strip for one-tap enabling.
                Item {
                    visible: pill.stripBar
                    width: pill.ghostStripHover ? ghostRow.implicitWidth + 12 * pill.s : 0
                    height: 17 * pill.s
                    anchors.verticalCenter: statusRow.verticalCenter

                    Behavior on width { NumberAnimation { duration: Motion.fast } }

                    Row {
                        id: ghostRow
                        anchors.left: parent.left
                        spacing: 6 * pill.s

                         Repeater {
                            model: StripLayout.disabledBarWidgets

                            delegate: Item {
                                required property var modelData
                                required property int index

                                width: 17 * pill.s
                                height: 17 * pill.s

                                GlyphIcon {
                                    id: ghostIcon
                                    anchors.centerIn: parent
                                    width: 11 * pill.s
                                    height: 11 * pill.s
                                    name: Plugins.iconFor(modelData.id)
                                    color: Theme.iconDim
                                    stroke: 1.5 * pill.s
                                    opacity: 0.5
                                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Plugins.openOrEnable(modelData.id);
                                    }
                                    onContainsMouseChanged: {
                                        ghostIcon.opacity = containsMouse ? 0.8 : 0.5;
                                    }
                                }

                                Tooltip {
                                    s: pill.s
                                    placement: "below"
                                    title: modelData.name || modelData.id
                                    desc: "Click to enable"
                                }
                            }
                        }

                        // Broken plugins: the retry ghost belongs beside the
                        // disabled-plugin ghosts, not inside the media bud.
                         Repeater {
                            model: Plugins.brokenPlugins

                            delegate: Item {
                                required property var modelData
                                required property int index

                                width: 17 * pill.s
                                height: 17 * pill.s

                                GlyphIcon {
                                    id: brokenGhostIcon
                                    anchors.centerIn: parent
                                    width: 11 * pill.s
                                    height: 11 * pill.s
                                    name: Plugins.iconFor(modelData.id)
                                    color: Theme.verm
                                    stroke: 1.5 * pill.s
                                    opacity: 0.5
                                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                                }

                                GlyphIcon {
                                    anchors.centerIn: parent
                                    width: 8 * pill.s
                                    height: 8 * pill.s
                                    name: "close"
                                    color: Theme.vermLit
                                    stroke: 1.2 * pill.s
                                    opacity: 0.7
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Plugins.reloadPlugin(modelData.id)
                                    onContainsMouseChanged: {
                                        brokenGhostIcon.opacity = containsMouse ? 0.8 : 0.5;
                                    }
                                }

                                Tooltip {
                                    s: pill.s
                                    placement: "below"
                                    title: modelData.name || modelData.id
                                    desc: Plugins.health[modelData.id] ? (Plugins.health[modelData.id].lastError || "Failed to load — click to retry") : "Click to reload"
                                }
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8 * pill.s
                        hoverEnabled: true
                        z: -1
                        onContainsMouseChanged: pill.ghostStripHover = containsMouse
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
                        id: inboxGlyph
                        anchors.fill: parent
                        name: Flags.dnd ? "dnd" : "inbox"
                        color: Flags.dnd ? Theme.verm : (inboxArea.containsMouse ? Theme.cream : Theme.iconDim)
                        stroke: 1.7
                        /**
                         * A new notification makes the bell give a bounce.
                         * The count is watched rather than the icon: the
                         * glyph itself does not change when one arrives, so
                         * without this the only sign of a new notification
                         * was a dot that had already been there.
                         */
                        property int lastUnread: Notifs.unread
                        onLastUnreadChanged: inboxGlyph.pulse()
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
                    visible: Flags.pillShowSysmon
                    property bool cellPresent: Flags.pillShowSysmon

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
                    visible: Flags.pillShowWallpaper && !Plugins.surfaceDisabled("wallpaper")
                    property bool cellPresent: Flags.pillShowWallpaper && !Plugins.surfaceDisabled("wallpaper")

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
                    visible: Flags.pillShowLauncher && !Plugins.surfaceDisabled("launcher")
                    property bool cellPresent: Flags.pillShowLauncher && !Plugins.surfaceDisabled("launcher")

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
                    visible: Flags.pillShowPower && !Plugins.surfaceDisabled("power")
                    property bool cellPresent: Flags.pillShowPower && !Plugins.surfaceDisabled("power")

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
            barAnchorItem: pill.barAnchorItem
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

    /**
     * Media host: the pill rect in centred mode, a floating island in strip
     * mode.
     *
     * Geometry is written rather than anchored, because the two states are
     * genuinely different rects — one shares the pill's exact box, the other
     * sits above it — and `anchors.fill` cannot be un-applied once bound. The
     * four Behaviors turn the swap into the peel-away motion: the card leaves
     * the bar upward while the bar underneath stays exactly where it was.
     *
     * Deliberately not `scale`-based: shrinking the card would scale its text
     * and icons, which reads as blur rather than as motion.
     */
    Item {
        id: mediaHost
        anchors.fill: parent

        Loader {
            id: ldMedia
            active: false
            anchors.fill: parent
sourceComponent: Media {
                s: pill.s
                open: pill.mediaOpen
                /* The floating island is not part of the pill's morph, so it gets
                 * its own openness. Without this the card would inherit the
                 * strip's unchanged morphCloseness, which never crosses the
                 * threshold its own fade keys off, and it would appear fully
                 * drawn while still sliding. */
                morphCloseness: pill.mediaFloats ? islandCloseness : pill.morphCloseness
                floats: pill.mediaFloats
                /* Rounded on every corner up here: the island hangs off the top
                 * edge, so squaring its top to meet the screen edge would be
                 * squaring it against nothing. */
                topFlat: (pill.mode === "game") ? 1 : 0
                onRequestClose: pill.requestClose()
                onRequestExpand: {
                    pill.surfaceDismissLatch = true;
                    pill.pinned = true;
                    pill.hoverLatch = true;
                    pill.expandLatch = true;
                    pill.requestClose();
                }
            }
        }
    }

    /**
     * Openness of the floating island, independent of the pill's morph.
     *
     * Straight off `mediaFloats` with a Behaviour: in strip mode the pill's own
     * morphCloseness never moves (the strip does not change size), so the card
     * needs a curve of its own or it would snap to fully drawn mid-slide.
     */
    property real islandCloseness: pill.mediaFloats ? 1 : 0
    Behavior on islandCloseness {
        NumberAnimation { duration: Motion.morph; easing.type: Easing.OutCubic }
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
        id: ldScreens
        active: false
        anchors.fill: parent
        sourceComponent: ScreensSurface {
            s: pill.s * pill.settingsScale
            open: pill.screensOpen
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


    Loader {
        id: ldLockstyle
        active: false
        anchors.fill: parent
        sourceComponent: LockStyleSurface {
            s: pill.s * pill.settingsScale
            open: pill.lockstyleOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldKeybinds
        active: false
        anchors.fill: parent
        sourceComponent: KeybindsSurface {
            s: pill.s * pill.settingsScale
            open: pill.keybindsOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }

    Loader {
        id: ldProfile
        active: false
        anchors.fill: parent
        sourceComponent: Profile {
            s: pill.s * pill.settingsScale
            open: pill.profileOpen
            morphCloseness: pill.morphCloseness
            onRequestClose: pill.requestClose()
            onRequestSurface: (name) => pill.requestSurface(name)
        }
    }


    Loader {
        id: ldModules
        active: false
        anchors.fill: parent
        sourceComponent: ModulesSurface {
            s: pill.s * pill.settingsScale
            open: pill.modulesOpen
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
