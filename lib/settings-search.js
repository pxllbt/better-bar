.pragma library

/**
 * The settings search catalog.
 *
 * Better Bar's settings are split across surfaces so each category stays
 * readable. That makes "where is this setting?" the real cost of finding
 * anything, and this file is the map that answers it without forcing a new
 * surface to own a second copy of every setting.
 *
 * Each entry is a destination, not a control. A `to` route opens the surface
 * that owns the setting; an `argv` entry runs the command Better Bar already
 * uses for setting screens that live outside the pill. Either way the search
 * result stays honest: it names the real destination or real command, and
 * never invents a setting that does not exist.
 */
var entries = [
    { title: "Theme", sub: "Theme gallery and palette mode", cat: "Settings", to: "theme", keywords: ["themes", "colors", "wallpaper", "appearance"] },
    { title: "Appearance", sub: "Accent · glass · font colour · lock", cat: "Settings", to: "appcat", keywords: ["style", "look", "customization"] },
    { title: "Font", sub: "UI family and typography fallback", cat: "Settings", to: "fontpicker", keywords: ["typography", "font family", "text"] },
    { title: "Display & Pill", sub: "Pill layout · time · glyphs", cat: "Settings", to: "display", keywords: ["time", "clock", "layout", "bar"] },
    { title: "Screens", sub: "Arrangement · scale · rotation · mirror", cat: "Settings", to: "screens", keywords: ["monitor", "display", "resolution", "profiles"] },
    { title: "Dock Settings", sub: "Auto-hide · theme · glass · pins", cat: "Settings", to: "dock", keywords: ["dock", "pinned apps", "bottom bar"] },
    { title: "Bar behaviour", sub: "Scale · motion · auto-hide · media", cat: "Display", to: "display", keywords: ["ui scale", "bar follows cursor", "memory", "reduce motion"] },
    { title: "Plugins", sub: "Install · enable · strip icons", cat: "Settings", to: "plugins", keywords: ["extension", "plugin manager"] },
    { title: "Update", sub: "Pull latest · re-applies the patch", cat: "Settings", to: "update", keywords: ["git", "update bar", "upgrade"] },

    { title: "Theme gallery", sub: "Choose the active theme", cat: "Theme", to: "theme", keywords: ["colors", "theme switch", "wallpaper"] },
    { title: "Palette mode", sub: "Light · dark · dynamic · manual", cat: "Theme", to: "theme", keywords: ["theme mode", "accent mode"] },
    { title: "Wallpaper folder", sub: "Where the wallpaper gallery reads from", cat: "Theme", to: "theme", keywords: ["wallpapers", "background directory", "custom folder"] },
    { title: "Window effects & borders", sub: "Borders · gaps · blur · animations", cat: "Appearance", to: "appcat", argv: ["omarchy-launch-config-editor", "$HOME/.config/hypr/looknfeel.lua"], keywords: ["hyprland", "blur", "gaps", "animations", "borders"] },
    { title: "Lock Screen Theme", sub: "Customise the session lock screen, clock & blur", cat: "Appearance", to: "lockstyle", keywords: ["lock", "password", "unlock clock", "lockscreen"] },
    { title: "Screensaver", sub: "Configure screensaver text & branding", cat: "Appearance", argv: ["omarchy-branding-screensaver", "text"], keywords: ["screensaver", "idle", "branding"] },

    { title: "Accent color", sub: "Override the warm accent colour", cat: "Appearance", to: "accent", keywords: ["accent", "hue", "custom color", "harmony"] },
    { title: "Transparency mode", sub: "Translucent or solid pill", cat: "Appearance", to: "glass", keywords: ["glass", "transparency", "material", "opaque"] },
    { title: "Pill background", sub: "Background opacity level", cat: "Appearance", to: "glass", keywords: ["glass", "opacity", "solid", "sheer", "background"] },
    { title: "Match Hyprland", sub: "Let the compositor choose the glass material", cat: "Appearance", to: "glass", keywords: ["blur", "hyprland glass", "material"] },
    { title: "Text visibility", sub: "Extra contrast for copy on the glass", cat: "Appearance", to: "glass", keywords: ["contrast", "text", "readability"] },
    { title: "Font colour", sub: "Recolour the text family", cat: "Appearance", to: "fontcolor", keywords: ["font color", "text color", "palette"] },
    { title: "UI font", sub: "Font family and typography fallback", cat: "Settings", to: "fontpicker", keywords: ["font", "text", "typeface"] },

    { title: "Main display", sub: "Minimal · classic · system · strip", cat: "Display", to: "display", keywords: ["pill layout", "bar style", "strip", "face"] },
    { title: "Media expand", sub: "What the media card expands into", cat: "Display", to: "display", keywords: ["expand", "media", "player", "hover media"] },
    { title: "Time format", sub: "24-hour or 12-hour clock", cat: "Display", to: "display", keywords: ["clock", "time", "12h", "24h"] },
    { title: "Clock seconds", sub: "Show seconds in the pill clock", cat: "Display", to: "display", keywords: ["seconds", "time"] },
    { title: "Time icon", sub: "Icon left of the pill clock", cat: "Display", to: "display", keywords: ["clock glyph", "clock icon", "time icon"] },
    { title: "Music visualizer", sub: "Animated music bars", cat: "Display", to: "display", keywords: ["visualizer", "music", "cava"] },
    { title: "Dock", sub: "Show or hide the bottom dock", cat: "Display", to: "display", keywords: ["dock", "taskbar", "bottom bar"] },

    { title: "UI scale", sub: "Interface scale", cat: "Bar behaviour", to: "display", keywords: ["size", "scale", "zoom", "dpi"] },
    { title: "Reduce motion", sub: "Softer animations", cat: "Bar behaviour", to: "display", keywords: ["motion", "animation", "reduce"] },
    { title: "Auto hide", sub: "Hide the bar until hovered", cat: "Bar behaviour", to: "display", keywords: ["hide", "reveal", "auto hide"] },
    { title: "Bar follows cursor", sub: "Show the bar on the cursor monitor", cat: "Bar behaviour", to: "display", keywords: ["cursor", "monitor", "multi monitor", "follow"] },
    { title: "Memory saver", sub: "Unload closed surfaces", cat: "Bar behaviour", to: "display", keywords: ["memory", "ram", "unload", "performance"] },
    { title: "Keybindings", sub: "Manage Hyprland keybindings and conflicts", cat: "Keyboard", to: "keybinds", keywords: ["keybind", "shortcuts", "hotkeys", "bindings", "manager"] },

    { title: "Dock auto-hide", sub: "Slide the dock up on demand", cat: "Dock", to: "dock", keywords: ["hide", "dock", "hover"] },
    { title: "Dock theme", sub: "Light · dark · dynamic · manual", cat: "Dock", to: "dock", keywords: ["dock color", "theme", "palette"] },
    { title: "Dock glass", sub: "Transparent or solid dock pane", cat: "Dock", to: "dock", keywords: ["dock glass", "transparency", "material"] },
    { title: "Minimal dock", sub: "Icon-only dock chips", cat: "Dock", to: "dock", keywords: ["minimal", "labels", "dock titles", "icons only"] },
    { title: "Dock pins", sub: "Pinned and running apps", cat: "Dock", to: "dock", keywords: ["pin", "favorite", "running apps", "dock order"] },

    { title: "Screens arrangement", sub: "Arrange monitors", cat: "Screens", to: "screens", keywords: ["monitor", "layout", "multi monitor"] },
    { title: "Screen scale", sub: "Per-monitor scale", cat: "Screens", to: "screens", keywords: ["hidpi", "scaling", "resolution"] },
    { title: "Screen rotation", sub: "Rotate a monitor", cat: "Screens", to: "screens", keywords: ["rotate", "orientation", "portrait"] },
    { title: "Mirror screens", sub: "Mirror one monitor onto another", cat: "Screens", to: "screens", keywords: ["mirror", "duplicate", "display"] },
    { title: "Screen profiles", sub: "Save and restore monitor layouts", cat: "Screens", to: "screens", keywords: ["profiles", "save layout", "restore"] },

    { title: "Lock clock", sub: "Clock position, layout and format", cat: "Lock", to: "lockstyle", keywords: ["lock clock", "12h", "24h", "vertical clock"] },
    { title: "Lock date", sub: "Date format and visibility", cat: "Lock", to: "lockstyle", keywords: ["lock date", "date format", "calendar"] },
    { title: "Password style", sub: "Dots · stars · dashes · hidden", cat: "Lock", to: "lockstyle", keywords: ["password", "pin", "mask", "input"] },
    { title: "Lock input shape", sub: "Password box shape and size", cat: "Lock", to: "lockstyle", keywords: ["radius", "width", "pill", "password box"] },
    { title: "Lock wallpaper blur", sub: "Background blur on the lock screen", cat: "Lock", to: "lockstyle", keywords: ["blur", "background", "wallpaper", "lock"] },
    { title: "Lock darkening", sub: "Dark overlay over the lock wallpaper", cat: "Lock", to: "lockstyle", keywords: ["dim", "darkness", "overlay", "lock"] },
    { title: "Lock avatar", sub: "Show the user avatar", cat: "Lock", to: "lockstyle", keywords: ["avatar", "face", "user"] },
    { title: "Lock quote", sub: "Motivational quote on the lock screen", cat: "Lock", to: "lockstyle", keywords: ["quote", "message", "greeting"] },
    { title: "Lock media card", sub: "Show playing media on the lock screen", cat: "Lock", to: "lockstyle", keywords: ["media", "music", "track", "lock"] },
    { title: "Lock animations", sub: "Clock and focus transitions", cat: "Lock", to: "lockstyle", keywords: ["animation", "breathing", "transition", "lock"] },
    { title: "Restore original LockView", sub: "Put back the untouched stock LockView", cat: "Lock", to: "lockstyle", keywords: ["restore", "stock", "reset", "lock"] },

    { title: "Auto update check", sub: "Read-only plugin update check", cat: "Plugins", to: "plugins", keywords: ["update", "check", "plugin updates"] },
    { title: "Auto install updates", sub: "Apply plugin updates automatically", cat: "Plugins", to: "plugins", keywords: ["update", "install", "auto update", "plugins"] },
    { title: "Auto adopt plugins", sub: "Wire newly installed plugins into Better Bar", cat: "Plugins", to: "plugins", keywords: ["adopt", "install", "plugin", "auto integrate"] },
    { title: "Self-heal plugins", sub: "Retry broken or missing plugins", cat: "Plugins", to: "plugins", keywords: ["heal", "retry", "broken", "missing", "repair"] },
    { title: "Install from URL", sub: "Install a plugin from a git URL", cat: "Plugins", to: "plugins", keywords: ["plugin", "install", "url", "git clone"] },
    { title: "Installed plugins", sub: "Enable, open, update and remove plugins", cat: "Plugins", to: "plugins", keywords: ["plugins", "inventory", "list", "manage"] },

    { title: "Check for updates", sub: "Update Better Bar and desktop packages", cat: "Update", to: "update", keywords: ["update", "upgrade", "pull", "git"] },
    { title: "Check dependencies", sub: "Verify required and optional tools", cat: "Update", to: "update", keywords: ["dependencies", "doctor", "tools", "requirements"] },
    { title: "Discard local commits and update", sub: "Use the upstream code and drop local changes", cat: "Update", to: "update", keywords: ["local commits", "reset", "update", "upstream"] }
];

function lower(s) {
    return String(s === undefined || s === null ? "" : s).toLowerCase();
}

function score(entry, q) {
    var title = lower(entry.title);
    if (!q)
        return 0;
    if (title === q)
        return 100;
    if (title.indexOf(q) === 0)
        return 80;
    if (title.indexOf(q) !== -1)
        return 60;

    var cat = lower(entry.cat);
    var sub = lower(entry.sub);
    var words = entry.keywords || [];
    for (var i = 0; i < words.length; i++) {
        if (lower(words[i]).indexOf(q) !== -1)
            return 40;
    }
    if (cat.indexOf(q) !== -1)
        return 30;
    if (sub.indexOf(q) !== -1)
        return 20;
    return -1;
}

function search(query) {
    var q = lower(query).trim();
    var out = [];
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var s = score(e, q);
        if (s >= 0)
            out.push({ entry: e, score: s, order: i });
    }
    out.sort(function (a, b) {
        if (b.score !== a.score)
            return b.score - a.score;
        return a.order - b.order;
    });
    return out;
}
