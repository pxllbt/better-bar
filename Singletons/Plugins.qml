import QtQuick
import Quickshell
import Quickshell.Io
pragma Singleton

/**
 * Omarchy plugin inventory and lifecycle, driven from Better Bar.
 *
 * The Omarchy host shell is the single owner of plugin state: it holds the
 * registry, the services and the IPC targets. Nothing here mutates plugin
 * files or re-implements discovery. Every call goes through the same two doors
 * the `omarchy plugin` CLI uses, so behaviour cannot drift from the terminal:
 *
 *   omarchy-shell shell listPlugins | setPluginEnabled | enablePlugin
 *                               | rescanPlugins | summon | hide | toggle
 *   omarchy plugin add <url> --yes | clone <id> | update <id> --yes
 *                               | remove <id> --yes
 *
 * `add`/`clone`/`update`/`remove` have no host IPC equivalent (they are file
 * operations on ~/.config/omarchy/plugins), so those shell out to the CLI with
 * the prompting flags already supplied, which keeps them non-interactive and
 * safe to drive from a panel.
 *
 * Placement matters for bar-widgets: `enablePlugin` is what puts a widget in
 * the Omarchy bar layout, and since Better Bar replaced that bar (it is docked
 * off-screen at y=-26), an enabled bar-widget is the signal that Better Bar should
 * give it a pill entry. See PluginButton.qml.
 */
Singleton {
    id: root

    // ---- state --------------------------------------------------------------

    /** Every plugin the host knows about, as returned by listPlugins. */
    property var plugins: []

    /** Plugin ids awaiting enable-then-summon; see `openOrEnable`. */
    property var pendingOpen: []

    /** shell.json's bar layout, so per-plugin widget settings can be found. */
    property var layout: ({ left: [], center: [], right: [] })

    /**
     * id -> manifest, read straight off disk.
     *
     * listPlugins reports ids and kinds but no path, and an id does not imply
     * one: omarchy.audio lives in plugins/panels/audio, omarchy.battery in
     * plugins/services/battery. The host can resolve entry points through its
     * registry, but that registry is not reachable from here, so the manifests
     * are read directly. Cheap and re-read only after a lifecycle action.
     */
    property var manifests: ({})

    property bool loaded: false
    property string busyWith: ""
    property string lastError: ""

    /**
     * Layout changes come from outside too (CLI, host menu), so the registry is
     * polled rather than trusted as a one-shot read.
     *
     * 30s, down from 5s. The poll spawns *two* `omarchy-shell` processes per
     * tick, so the old rate was 34k spawns/day to re-read a registry that only
     * changes when a plugin is installed, removed or re-enabled — and every such
     * change already calls `refresh()` directly through `settle`. The one thing
     * polling genuinely covers is an edit made outside the shell, which is what
     * `shellConfigFile` below now watches so that path stays immediate too.
     *
     * `surfaceOpen` is still honoured: the surface reads the list on open, so it
     * wants the tighter cadence then.
     */
    readonly property int refreshMs: surfaceOpen ? 1500 : 30000

    /** The file `listShellConfig` reads. Watched so an edit from outside lands
     *  at once rather than waiting out the poll. */
    readonly property string shellConfigPath: root.home + "/.config/omarchy/shell.json"

    readonly property string home: Quickshell.env("HOME") || ""

    // ---- derived views ------------------------------------------------------

    /** Plugins the host mounts itself: self-positioned windows, no bar needed. */
    readonly property var hostMounted: root.plugins.filter(function (p) {
        return p.kinds.indexOf("panel") !== -1
            || p.kinds.indexOf("overlay") !== -1
            || p.kinds.indexOf("menu") !== -1;
    })

    /**
     * Bar-widgets are the only kind the host can only place in its off-screen
     * bar, so these are the ones Better Bar has to host (and give pill entries).
     */
    readonly property var barWidgets: root.plugins.filter(function (p) {
        return p.kinds.indexOf("bar-widget") !== -1;
    })

    /** Enabled bar-widgets: exactly the set that gets a pill entry. */
    readonly property var pillWidgets: root.barWidgets.filter(function (p) {
        return p.enabled === true;
    })

    /**
     * The same set minus the entries the bar does not place itself:
     * omarchy.menu (the host's own launcher/logo; Better Bar has its
     * own) and omarchy.agents (a panel the host mounts itself — its
     * `barWidget` entry point is the panel root, not a strip widget,
     * so hosting it locally only produces a failed chip rendering the
     * letter "A"; clicking it summons the host's own agent panel
     * instead).
     *
     * Also excluded: a plugin another plugin cloned away, and a
     * plugin whose capability Better Bar supersedes with its own
     * surface — unless the user picked that plugin for the
     * capability, in which case it is the strip's, and the bar's
     * own surface steps aside (see `surfaceDisabled`).
     *
     * Split out as a predicate, and deliberately independent of
     * `enabled`, so the settings surface can answer "what would
     * happen if I turned this on" *before* the toggle is flipped.
     * Answering from `pillWidgetsGeneric` would only ever describe
     * the plugins that are already on.
     */
    function hostsInStrip(p) {
        if (!p || p.kinds.indexOf("bar-widget") === -1)
            return false;
        if (p.id === "omarchy.menu" || p.id === "omarchy.agents")
            return false;
        if (root.clonedAway(p))
            return false;
        if (root.supersededByUs(p))
            return false;
        return true;
    }

    readonly property var pillWidgetsGeneric: root.pillWidgets.filter(root.hostsInStrip)

    readonly property bool surfaceOpen: false

    // ---- lookup -------------------------------------------------------------

    function byId(id) {
        for (var i = 0; i < root.plugins.length; i++) {
            if (root.plugins[i].id === id)
                return root.plugins[i];
        }
        return null;
    }

    /** shell.json stores a widget's overrides inline on its layout entry. */
    function settingsFor(id) {
        var sections = ["left", "center", "right"];
        for (var s = 0; s < sections.length; s++) {
            var rows = root.layout[sections[s]] || [];
            for (var i = 0; i < rows.length; i++) {
                if (rows[i] && rows[i].id === id)
                    return rows[i];
            }
        }
        return ({});
    }

    function manifestFor(id) {
        return root.manifests[String(id || "")] || null;
    }

    /**
     * The file a bar-widget renders into a strip.
     *
     * `barWidget` is the only entry point worth hosting here: it is the surface
     * written to live in a bar, and Better Bar's strip is the bar. A plugin with
     * one is loaded locally. Empty means the plugin has no bar surface, so the
     * host owns its UI and we only drive it.
     */
    function barEntryFor(id) {
        var m = root.manifestFor(id);
        if (!m)
            return "";
        var file = String((m.entryPoints || {}).barWidget || "");
        return file ? m.dir + "/" + file : "";
    }

    // ---- strip icon + render mode -------------------------------------------

    /**
     * The glyphs this shell can draw, by name.
     *
     * Duplicated rather than imported because GlyphIcon is a component and
     * these are singleton-scoped values: a component cannot be queried from
     * here. Only the two prefixes the resolver actually uses are listed, since
     * a bare `name` that resolves to nothing renders an empty box rather than
     * falling back. Anything else in GlyphIcon.qml stays reachable from Pill.qml
     * by name as before.
     */
    readonly property var glyphNames: ({
        "app-window": 1, "arrow-up": 1, "awake": 1, "bluetooth": 1, "bolt": 1,
        "camera": 1, "check": 1, "chevron-down": 1, "chevron-left": 1,
        "chevron-right": 1, "chevron-up": 1, "clipboard": 1, "clock": 1,
        "close": 1, "cloud": 1, "cog": 1, "computer": 1, "cursor": 1, "dnd": 1,
        "dock": 1, "download": 1, "droplet": 1, "ethernet": 1,
        "eye-off": 1, "gamepad": 1, "headphones": 1, "hotspot": 1, "inbox": 1,
        "keyboard": 1, "language": 1, "layers": 1, "lock": 1, "logout": 1,
        "mic": 1, "mixer": 1, "monitor": 1, "moon": 1, "mouse": 1, "music": 1,
        "palette": 1, "pause": 1, "phone": 1, "pin": 1, "play": 1,
        "printer": 1, "record": 1, "refresh": 1, "return": 1, "scaling": 1,
        "shutdown": 1, "speaker": 1, "sparkles": 1, "stopwatch": 1, "sun": 1,
        "suspend": 1, "trash": 1, "tv": 1, "type": 1, "undo": 1, "video": 1,
        "watch": 1, "waves": 1, "wifi": 1, "wallpaper": 1
    })

    /**
     * Glyph names for the stock bar-widgets.
     *
     * They live here and not in the plugins' own manifests because
     * /usr/share/omarchy is not ours to edit — it is replaced wholesale on
     * update. A third-party plugin that CAN ship a `better.icon` should, and
     * that beats this table.
     *
     * `cloud` is deliberately shared by dropbox and weather rather than given a
     * bespoke cloud-rain: the stock table is a starting point, and a plugin
     * author overriding one word is cheaper than this file carrying a name per
     * plugin forever.
     */
    readonly property var stockIcons: ({
        "omarchy.active-window": "app-window",
        "omarchy.agents": "sparkles",
        "omarchy.audio": "speaker",
        "omarchy.bluetooth": "bluetooth",
        "omarchy.clock": "clock",
        "omarchy.dropbox": "cloud",
        "omarchy.indicators": "bolt",
        "omarchy.keyboard-layout": "keyboard",
        "omarchy.media": "music",
        "omarchy.menu": "app-window",
        "omarchy.microphone": "mic",
        "omarchy.monitor": "monitor",
        "omarchy.network": "wifi",
        "omarchy.power": "bolt",
        "omarchy.system-update": "download",
        "omarchy.tailscale": "hotspot",
        "omarchy.tray": "layers",
        "omarchy.weather": "cloud",
        "omarchy.workspaces": "dock"
    })

    /**
     * Keyword → glyph, tried in order against a lowercased name + id.
     *
     * This is the answer for the plugin installed five minutes from now that
     * declares nothing: "audio" finds a speaker without anyone writing a row.
     * Order is the whole design — the first substring match wins, so the more
     * specific words come first and generic ones ("app", "tool", "system") are
     * left out entirely, because matching those is how a plugin ends up with a
     * wrong-but-plausible icon that nobody notices is wrong.
     */
    readonly property var iconKeywords: [
        { re: "mic", name: "mic" },
        { re: "recast|record|screen ?cast|capture", name: "video" },
        { re: "battery|power ?sav", name: "bolt" },
        { re: "power|shutdown", name: "shutdown" },
        { re: "suspend|sleep", name: "suspend" },
        { re: "reboot|restart", name: "reboot" },
        { re: "audio|sound|volume|mixer", name: "mixer" },
        { re: "volume|mute", name: "speaker" },
        { re: "music|media|player", name: "music" },
        { re: "bluetooth|bt", name: "bluetooth" },
        { re: "wifi|wireless", name: "wifi" },
        { re: "network|ethernet|net", name: "ethernet" },
        { re: "weather|temperature|forecast", name: "cloud" },
        { re: "clipboard|copy ?history", name: "clipboard" },
        { re: "wallpaper|background", name: "wallpaper" },
        { re: "monitor|display|screen", name: "monitor" },
        { re: "theme|colour|color|palette|appearance", name: "palette" },
        { re: "notification|notif|notify|alert", name: "inbox" },
        { re: "clock|time", name: "clock" },
        { re: "cog|setting|preference|config", name: "cog" },
        { re: "keyboard|kb|layout", name: "keyboard" },
        { re: "phone", name: "phone" },
        { re: "watch|wearable", name: "watch" },
        { re: "printer|print", name: "printer" },
        { re: "tv|television", name: "tv" },
        { re: "camera|webcam", name: "camera" },
        { re: "dock|launcher|menu|app", name: "app-window" },
        { re: "download", name: "download" },
        { re: "backup|archive", name: "download" },
        { re: "trash|delete|bin", name: "trash" },
        { re: "agent|ai|assistant|copilot", name: "sparkles" }
    ]

    /**
     * The glyph to draw for a plugin, or "" when nothing resolves.
     *
     * Precedence, most specific first:
     *   1. the plugin's own manifest `better.icon`
     *   2. the stock table, for the omarchy.* widgets we cannot ship a manifest for
     *   3. a keyword match on name + id
     *   4. "" — PluginButton falls back to its letter chip
     *
     * The manifest name is checked against `glyphNames` rather than trusted: a
     * typo would otherwise render an empty box, which is the exact "wrong icon"
     * this whole path exists to remove. Falling through to the keyword pass is
     * strictly better than showing nothing.
     */
    function iconFor(id) {
        var pluginId = String(id || "");
        if (!pluginId)
            return "";

        var m = root.manifestFor(pluginId);
        var declared = m && m.better ? String(m.better.icon || "") : "";
        if (declared && root.glyphNames[declared])
            return declared;

        var stock = root.stockIcons[pluginId];
        if (stock)
            return stock;

        var haystack = (pluginId + " " + (m && m.name ? String(m.name) : "")).toLowerCase();
        for (var i = 0; i < root.iconKeywords.length; i++) {
            // A real regex test, not indexOf: these are alternations like
            // "audio|sound|volume|mixer", and substring-matching the joined
            // pattern would never once match a haystack.
            if (new RegExp(root.iconKeywords[i].re).test(haystack))
                return root.iconKeywords[i].name;
        }

        return "";
    }

    // ---- capability registry ----------------------------------------------

    /**
     * What a plugin is *for*, as an ordered list of capabilities and
     * the phrases that identify one. Order is the whole design, exactly
     * as it is for icons: the first capability whose phrase appears in
     * the plugin's id, name or description wins, so the specific words
     * come first and the ambiguous ones last. That is why "power" is
     * matched before "battery" (the stock power widget's description
     * begins "Battery, power profile...") and "clock" before "calendar"
     * (the stock clock widget's description ends "...with a calendar
     * popup"). A bare word that would match half the registry ("menu",
     * "system", "tool") is left out on purpose.
     */
    readonly property var capabilityKeywords: [
        { cap: "recorder", re: "screen ?recorder|screen ?recording|screenrecord|gpu.screen.recorder" },
        { cap: "launcher", re: "app ?launcher|launcher|application menu|command menu|application drawer" },
        { cap: "clipboard", re: "clipboard manager|clipboard history|cliphist|clipboard" },
        { cap: "power", re: "power menu|power options|power profile|power panel|power" },
        { cap: "mixer", re: "volume mixer|audio mixer|per.app mixer|mixer|volume control|volume slider" },
        { cap: "weather", re: "weather|forecast|meteo" },
        { cap: "clock", re: "clock|world clock|date/time|time and date" },
        { cap: "calendar", re: "calendar|agenda" },
        // Wi-Fi QR must run before the wifi rule: the generic
        // `wi.?fi` alternative would otherwise swallow it first,
        // and a QR sharer is not a wifi manager.
        { cap: "wifiqr", re: "wi.?fi qr|qr code" },
        { cap: "wifi", re: "wi.?fi|wireless network|network manager" },
        { cap: "bluetooth", re: "bluetooth" },
        { cap: "battery", re: "battery status|battery level|charge level|battery widget|low battery|battery (warning|service|indicator|meter)" },
        { cap: "media", re: "media player|music player|mpris|media control" },
        // Wallpaper needs a purpose word, not a mention: "syncs to
        // the wallpaper", "used for wallpapers" and "wallpaper
        // widgets" are lock screens, pickers and settings panels,
        // not wallpaper providers.
        { cap: "wallpaper", re: "wallpaper\\s+(manager|setter|changer|switcher|daemon|slideshow|viewer|engine)|wallhaven|set\\s+(the\\s+)?wallpaper" },
        { cap: "osd", re: "\\bosd\\b|on.screen display|status overlays?" },
        // Display needs a purpose word, and it runs after the OSD
        // rule on purpose: an overlay that mentions brightness is
        // still an OSD, while a brightness slider with nothing else
        // around it is the display job the bar's own surface takes.
        { cap: "display", re: "brightness (slider|control|fader|keys?|stepper)|display (controls|settings|configuration|panel)|laptop display" },
        // Appearance needs a purpose word too: "used for
        // wallpapers, themes, and any other directory" is an
        // image picker, not a theme manager.
        { cap: "appearance", re: "appearance|theme manager|theme (switcher|engine|pack|changer)|customisation|customization" },
        { cap: "plugins", re: "plugin manager|plugin market|plugins" },
        { cap: "update", re: "update checker|system update|software update|updater" },
        { cap: "dock", re: "\\bdock\\b|taskbar" },
        { cap: "notifications", re: "notification center|notifications" },
        { cap: "reminders", re: "reminders?|to.?do" },
        { cap: "emojis", re: "emojis?" },
        { cap: "speedtest", re: "speedtest|speed test|latency test" },
        { cap: "tailscale", re: "tailscale" },
        { cap: "dropbox", re: "dropbox" },
        { cap: "wifiqr", re: "wi.?fi qr|qr code" },
        { cap: "agents", re: "ai agents?|copilot|assistant" },
        { cap: "nightlight", re: "night ?light|nightlight" },
        { cap: "idle", re: "idle|dpms" },
        { cap: "polkit", re: "polkit" },
        { cap: "background", re: "wallpaper daemon|background service" },
        { cap: "imagepicker", re: "image ?picker|image[- ]?grid|screenshot picker|image selector" },
        { cap: "devgallery", re: "dev gallery|developer gallery" },
        { cap: "sysmon", re: "system monitor|sysmon|process monitor" },
    ]

    /**
     * The capabilities Better Bar implements itself. A plugin that
     * provides one of these is superseded — the bar's own surface is
     * what shows — unless the user picked that plugin for the
     * capability, which `providers` records. Everything else is a
     * capability only plugins provide, so a plugin for it is never
     * superseded and always gets its strip entry.
     *
     * The stock widgets this covers are the eight the bar duplicates
     * out of the box (clock, weather, network, audio, bluetooth,
     * power, media — plus any future omarchy.* widget that names one
     * of these words). The rest are the bar's own surfaces, where the
     * point is the swap the other way round: install a plugin for one
     * of them and it becomes the default, uninstall it and the bar's
     * own surface comes back.
     */
    readonly property var ownCapabilities: ({
        launcher: 1, clipboard: 1, notifications: 1,
        power: 1, mixer: 1, weather: 1, clock: 1, calendar: 1, wifi: 1,
        bluetooth: 1, media: 1, wallpaper: 1, osd: 1, appearance: 1,
        display: 1, nightlight: 1, sysmon: 1,
        plugins: 1, update: 1, dock: 1,
    })

    /**
     * Surface name → the capability that surface implements. A surface
     * whose capability is owned by a plugin cannot be opened from
     * here: the plugin is the default for that job now, and opening
     * the bar's own copy beside it would be the duplication this
     * registry exists to prevent.
     */
    readonly property var surfaceCapability: ({
        launcher: "launcher", clipboard: "clipboard",
        link: "notifications", power: "power", mixer: "mixer", weather: "weather",
        calendar: "calendar", wifi: "wifi", bt: "bluetooth",
        media: "media", wallpaper: "wallpaper", osd: "osd",
        display: "display", sysmon: "sysmon",
        appearance: "appearance", plugins: "plugins", update: "update",
        dock: "dock",
    })

    /**
     * capability → the plugin id the user picked for it. An absent or
     * empty entry means Better Bar's own surface is the default.
     * Persisted in the state dir so the choice survives restarts, the
     * same way dock pins are.
     */
    property var providers: ({})

    readonly property string providersFile: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better/providers.json"

    FileView {
        id: providersStore
        path: root.providersFile
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    function loadProviders() {
        var raw = providersStore.text();
        try {
            var v = raw && raw.length > 0 ? JSON.parse(raw) : {};
            root.providers = v && typeof v === "object" ? v : {};
        } catch (e) {
            root.providers = {};
        }
    }

    function saveProviders() {
        providersStore.setText(JSON.stringify(root.providers));
    }

    /**
     * The capability a plugin provides, or "" when it provides none.
     *
     * Precedence, most specific first:
     *   1. the plugin's own manifest `better.provides`
     *   2. `omarchy.clonedFrom` — a clone provides what its source
     *      provided, which is Omarchy's own swap contract
     *   3. a keyword match on id + name + description
     */
    function capabilityFor(id, depth) {
        var pid = String(id || "");
        if (!pid)
            return "";
        var m = root.manifestFor(pid);
        if (!m)
            return "";

        var meta = m.better;
        if (meta && meta.provides && typeof meta.provides === "string") {
            var declared = String(meta.provides);
            for (var i = 0; i < root.capabilityKeywords.length; i++) {
                if (root.capabilityKeywords[i].cap === declared)
                    return declared;
            }
        }

        var source = "";
        var entry = root.byId(pid);
        if (entry && entry.clonedFrom)
            source = String(entry.clonedFrom);
        if (source && (!depth || depth < 4)) {
            var inherited = root.capabilityFor(source, (depth || 0) + 1);
            if (inherited.length > 0)
                return inherited;
        }

        var haystack = (pid + " " + String(m.name || "") + " "
                        + String(m.description || "")).toLowerCase();
        for (var k = 0; k < root.capabilityKeywords.length; k++) {
            if (new RegExp(root.capabilityKeywords[k].re).test(haystack))
                return root.capabilityKeywords[k].cap;
        }
        return "";
    }

    /**
     * True when a user plugin owns the capability `p` provides, so
     * Better Bar's own surface for it is the one that steps aside.
     * Deliberately independent of `enabled`, like `hostsInStrip`, so
     * the settings surface can answer "what would happen if I turned
     * this on" before the toggle is flipped.
     */
    function supersededByUs(p) {
        if (!p)
            return false;
        var cap = root.capabilityFor(p.id);
        if (!cap || !root.ownCapabilities[cap])
            return false;
        return root.providers[cap] !== p.id;
    }

    /** True when the user picked `p` to provide its own capability. */
    function providerChosen(p) {
        if (!p)
            return false;
        var cap = root.capabilityFor(p.id);
        return cap.length > 0 && root.providers[cap] === p.id;
    }

    /**
     * True when another plugin declares `p` as its `omarchy.clonedFrom`
     * source. The clone takes the source's place in the host, so the
     * source has nothing left to show here — that swap is the host's
     * contract, and honouring it is what stops a clone and its
     * original both rendering.
     */
    function clonedAway(p) {
        if (!p)
            return false;
        for (var i = 0; i < root.plugins.length; i++) {
            var other = root.plugins[i];
            if (other && String(other.clonedFrom || "") === p.id)
                return true;
        }
        return false;
    }

    /**
     * Hand the capability `cap` to the plugin `id` ("" hands it back
     * to Better Bar's own surface). The one write path for the
     * "use this plugin instead" action in the plugins surface.
     */
    function setProvider(cap, id) {
        if (!cap)
            return;
        var next = {};
        for (var k in root.providers)
            next[k] = root.providers[k];
        if (id)
            next[cap] = String(id);
        else
            delete next[cap];
        root.providers = next;
        root.saveProviders();
    }

    /**
     * True when the surface `name` belongs to a capability a plugin
     * now owns, so the surface must not open.
     */
    function surfaceDisabled(name) {
        var cap = root.surfaceCapability[String(name || "")];
        if (!cap)
            return false;
        var owner = root.providers[cap];
        return owner !== undefined && owner !== "";
    }

    /**
     * How a plugin draws its strip entry: "glyph" (default) or "widget".
     *
     * "glyph" is the default and is the entire point: a plugin looks like part
     * of this shell without anyone writing a strip component for it.
     *
     * "widget" is the opt-out, for a widget whose visual carries data a bare
     * icon cannot show — a volume bar, a temperature, a track name. The
     * plugin's own BarWidget is then hosted in the cell as before, which is
     * also where its size is free to be whatever the data needs.
     *
     *   "better": { "render": "widget" }
     *
     * `better` is the key the manifest scan reads; there is no older
     * spelling to fall back to.
     *
     * A plugin whose strip entry is *stateful* — a recording dot, a live
     * timer, a replay ring — has no single glyph to draw and wants its
     * own component in the pill instead. That is the escape hatch a
     * plugin opts into with `"render": "widget"`, and the reason
     * `hostsInStrip` only ever hosts the plugin the user picked for
     * that capability. See PluginButton.qml.
     */
    function renderFor(id) {
        var m = root.manifestFor(id);
        var meta = m && m.better ? m.better : null;
        return meta && String(meta.render || "") === "widget" ? "widget" : "glyph";
    }

    /**
     * A panel-kind entry point. Recorded for reference only: the host already
     * mounts these and positions their windows itself, so Better Bar never loads
     * a second copy.
     */
    function panelEntryFor(id) {
        var m = root.manifestFor(id);
        if (!m)
            return "";
        var file = String((m.entryPoints || {}).panel || "");
        return file ? m.dir + "/" + file : "";
    }

    // ---- host IPC -----------------------------------------------------------

    function refresh() {
        listProc.running = true;
        configProc.running = true;
        scanProc.running = true;
    }

    function summon(id, payload) {
        act("summon", [id, payload || "{}"]);
    }

    function hide(id) {
        act("hide", [id]);
    }

    function toggle(id, payload) {
        act("toggle", [id, payload || "{}"]);
    }

    /** The host's equivalent of `bar.requestPopout`: open a plugin's panel. */
    function openPanel(id) {
        act("summon", [id, "{}"]);
    }

    /**
     * Open a plugin, enabling it first if the host has it switched off.
     *
     * `summon` refuses a disabled plugin outright — `shell.qml:1163` in the host
     * returns false before it ever loads a Loader, because a disabled plugin has
     * none, and a bare `openPanel` on one of the 27 disabled plugins was therefore
     * a dead click with no feedback. That refusal cannot be lifted from here.
     *
     * So this does the only ordering that works: enable, wait for the host to
     * re-register the plugin, then summon. The wait is not a timer guess — it is
     * the next `listPlugins` read, which is the same signal the pill itself keys
     * off, so the summon cannot fire before the host agrees the plugin is on.
     */
    function openOrEnable(id) {
        var plugin = root.byId(id);
        if (plugin && plugin.enabled === true) {
            root.openPanel(id);
            return;
        }
        if (root.pendingOpen.indexOf(id) === -1)
            root.pendingOpen.push(id);
        root.enable(id);
    }

    /**
     * Summon anything that was queued by `openOrEnable` and has since become
     * enabled. Driven from the list read rather than a timer, so it runs exactly
     * once per transition and never summons a plugin the host still has off.
     */
    function flushPendingOpens() {
        if (root.pendingOpen.length === 0)
            return;
        // `act` drops rather than queues when the runner is busy, so consuming the
        // list here would throw away a summon that never actually ran. Bail and
        // leave the queue intact; the next list read retries.
        if (actProc.running)
            return;
        var still = [];
        for (var i = 0; i < root.pendingOpen.length; i++) {
            var id = root.pendingOpen[i];
            var plugin = root.byId(id);
            if (plugin && plugin.enabled === true)
                root.openPanel(id);
            else
                still.push(id);
        }
        root.pendingOpen = still;
    }

    function closePanel(id) {
        act("hide", [id]);
    }

    function enable(id, placement) {
        // enablePlugin is what writes a layout entry, which is how a bar-widget
        // becomes "in the bar" — and therefore how it earns a pill entry.
        //
        // That placement is only meaningful for a bar-widget: the host inserts a
        // layout row only when the manifest declares that kind
        // (`PluginRegistry.setEnabled`, the `isBarWidget` branch), so for the 9
        // services and 5 panels/overlays a section is ignored. Passing one anyway
        // was harmless but wrong, and would misplace a plugin that later grew bar
        // semantics. So ask what kind this is instead of assuming.
        var plugin = root.byId(id);
        var isWidget = plugin && Array.isArray(plugin.kinds)
            && plugin.kinds.indexOf("bar-widget") !== -1;
        var payload = placement || (isWidget ? JSON.stringify({ section: "right" }) : "{}");
        act("enablePlugin", [id, payload]);
        scheduleRefresh();
    }

    function disable(id) {
        act("setPluginEnabled", [id, "false"]);
        scheduleRefresh();
    }

    function setEnabled(id, on) {
        if (on)
            root.enable(id);
        else
            root.disable(id);
    }

    function rescan() {
        act("rescanPlugins", []);
        scheduleRefresh();
    }

    // A single runner for host IPC so a burst of toggles cannot interleave, and
    // so the surface can show what is in flight.
    function act(method, args) {
        if (actProc.running)
            return;
        root.busyWith = method;
        actProc.command = ["omarchy-shell", "shell", method].concat(args || []);
        actProc.running = true;
    }

    // ---- plugin files (no host IPC equivalent) ------------------------------

    function install(url) {
        return runCli("add", [url, "--yes"]);
    }

    function clone(id) {
        return runCli("clone", [id]);
    }

    function update(id) {
        return runCli("update", [id ? id : "--yes", "--yes"]);
    }

    function remove(id) {
        return runCli("remove", [id, "--yes"]);
    }

    function validate(folder) {
        return runCli("validate", [folder]);
    }

    function runCli(verb, args) {
        root.busyWith = verb;
        cliProc.verb = verb;
        cliProc.command = ["omarchy-plugin-" + verb].concat(args);
        cliProc.running = true;
        return true;
    }

    // Both queues need a beat to settle: the host writes shell.json and re-registers
    // asynchronously, so an immediate read would race it.
    function scheduleRefresh() {
        settle.restart();
    }

    Timer {
        id: settle
        interval: 900
        onTriggered: root.refresh()
    }

    // ---- processes ----------------------------------------------------------

    Process {
        id: listProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var parsed = null;
                try {
                    parsed = JSON.parse(String(text || "").trim() || "[]");
                } catch (e) {
                    parsed = null;
                }
                if (Array.isArray(parsed)) {
                    root.plugins = parsed;
                    // The list read is the signal that the host finished applying
                    // whatever was queued, so this is the earliest moment a
                    // queued summon can succeed.
                    root.flushPendingOpens();
                } else
                    root.lastError = "could not read the plugin list";
            }
        }
    }

    Process {
        id: configProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var parsed = null;
                try {
                    parsed = JSON.parse(String(text || "").trim() || "{}");
                } catch (e) {
                    parsed = null;
                }
                var bar = parsed && parsed.bar ? parsed.bar : null;
                var lay = bar && bar.layout ? bar.layout : null;
                if (lay)
                    root.layout = lay;
            }
        }
    }

    // One pass over every installed manifest. `--arg d` keeps the jq program free
    // of string literals, so this survives being nested inside sh -c.
    Process {
        id: scanProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var map = {};
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (!line)
                        continue;
                    var m = null;
                    try {
                        m = JSON.parse(line);
                    } catch (e) {
                        continue;
                    }
                    if (m && m.id)
                        map[m.id] = m;
                }
        root.manifests = map;
        root.loadProviders();
        root.loaded = true;
            }
        }
    }

    Process {
        id: actProc
        onExited: (code) => {
            root.busyWith = "";
            if (code !== 0)
                root.lastError = "the host rejected " + actProc.command[3];
            scheduleRefresh();
        }
    }

    Process {
        id: cliProc
        property string verb: ""
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.lastOutput = String(text || "").trim()
        }
        onExited: (code) => {
            if (code !== 0)
                root.lastError = cliProc.verb + " failed";
            root.busyWith = "";
            // An install/clone adds a directory the host has not scanned yet.
            if (["add", "clone", "update", "remove"].indexOf(cliProc.verb) !== -1) {
                act("rescanPlugins", []);
                settle.restart();
            } else {
                scheduleRefresh();
            }
        }
    }

    property string lastOutput: ""

    // ---- lifecycle ----------------------------------------------------------

    Timer {
        id: poll
        interval: root.refreshMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.pollOnce()
    }

    FileView {
        id: shellConfigFile
        path: root.shellConfigPath
        blockLoading: true
        watchChanges: true
        printErrors: false
        // Covers the "changed from outside" case the slow poll tolerates.
        onFileChanged: root.pollOnce()
    }

    /** One registry tick. Both halves are guarded on `running` so an external
     *  change landing mid-poll cannot queue a second pair of spawns behind the
     *  first; the next tick picks up whatever that one missed. */
    function pollOnce() {
        if (!listProc.running)
            listProc.running = true;
        if (!configProc.running)
            configProc.running = true;
    }

    Component.onCompleted: {
        listProc.command = ["omarchy-shell", "shell", "listPlugins"];
        configProc.command = ["omarchy-shell", "shell", "listShellConfig"];
        scanProc.command = ["sh", "-c",
            "find /usr/share/omarchy/shell/plugins \"$HOME/.config/omarchy/plugins\""
            + " -maxdepth 3 \\( -name manifest.json -o -name '*.manifest.json' \\) -print0 2>/dev/null"
            + " | while IFS= read -r -d '' m; do"
            + " jq -c --arg d \"$(dirname \"$m\")\""
            + " '{id:.id,name:.name,description:.description,kinds:(.kinds//[]),entryPoints:(.entryPoints//{}),dir:$d,better:(.better//null)}' \"$m\";"
            + " done"];
        root.refresh();
    }
}
