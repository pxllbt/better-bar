pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/menu.js" as MenuModel

/**
 * The Omarchy command menu, hosted in the pill.
 *
 * This is the stock `/usr/share/omarchy/shell/plugins/menu/` model — the same
 * two JSONC files, the same guard semantics, the same providers — loaded into a
 * surface instead of a standalone Quickshell window. Editing
 * `~/.config/omarchy/extensions/omarchy-menu.jsonc` therefore changes this
 * launcher exactly as it changes the stock one; both read it.
 *
 * What the stock plugin does that this does not:
 *
 *   * It is not launched by `omarchy-menu summon <route>`. Routing here is
 *     available (see `resolve`) for the IPC surface, but nothing depends on it.
 *   * It does not draw. Row building lives in the surface; this singleton only
 *     owns state that outlives a search — the parsed tree, the guard answers and
 *     the provider rows.
 *
 * Guard evaluation is the expensive part and the reason this is one batched
 * `bash` rather than 173 forks: see `guardScript` in lib/menu.js.
 */
Singleton {
    id: root

    /** Parsed tree: id -> normalized item. */
    property var items: ({})
    /** Declaration order of `items`, which is the display order within a level. */
    property var itemOrder: []

    /** id -> bool, from `when:` guards. False hides the row. */
    property var whenResults: ({})
    /** id -> bool, from `checked:` guards. True appends a ✓ to the label. */
    property var checkedResults: ({})

    /** Set once the first guard batch lands, so the surface can say "loading". */
    property bool guardsResolved: false
    /** True while a batch is in flight. Guards re-run on demand, not on a timer. */
    property bool guardsRunning: false

    /** Menu id -> true once its provider has contributed rows. */
    property var providersLoaded: ({})

    readonly property string defaultMenuPath: "/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc"
    readonly property string userMenuPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/extensions/omarchy-menu.jsonc"

    Component.onCompleted: root.reload()

    // ---- sources -----------------------------------------------------------

    /**
     * Both files are watched, so an edit to either takes effect without a shell
     * restart — the same live-reload the stock menu does. A file that does not
     * exist yet is not an error: the user extension is optional, and Omarchy
     * creates the default one on install.
     */
    FileView {
        id: defaultMenuFile
        path: root.defaultMenuPath
        blockLoading: true
        printErrors: false
        onLoaded: root.merge()
        onFileChanged: reload()
        onLoadFailed: root.merge()
    }

    FileView {
        id: userMenuFile
        path: root.userMenuPath
        blockLoading: true
        printErrors: false
        onLoaded: root.merge()
        onFileChanged: reload()
        onLoadFailed: root.merge()
    }

    /** Re-read both sources and rebuild the tree, then re-run the guards. */
    function reload() {
        defaultMenuFile.reload();
        userMenuFile.reload();
        root.merge();
    }

    function merge() {
        var defaults = MenuModel.parseMenuJsonc(defaultMenuFile.text());
        var user = MenuModel.parseMenuJsonc(userMenuFile.text());
        var merged = MenuModel.mergeMenuSources(defaults, user);
        root.items = merged.items;
        root.itemOrder = merged.itemOrder;
        // A changed menu file can add or remove guarded rows, so the cached
        // answers no longer describe it. Re-run rather than trusting them.
        root.runGuards();
    }

    // ---- guards ------------------------------------------------------------

    /**
     * One batched bash for every `when:`/`checked:` in the tree. ~200 guards
     * measured at 0.9s warm on this machine, against over a second for the first
     * one after a cold `pacman -Qi` cache. It runs when the menu opens, not on a
     * timer: a row's guard describes state that only changes when the user does
     * something (installs a package, switches DNS), and the surface re-runs this
     * on every open so those changes are picked up.
     */
    function runGuards() {
        var script = "";
        try {
            script = MenuModel.guardScript(root.items);
        } catch (e) {
            // A malformed menu file must not leave the launcher spinning on
            // "…" forever. Treated as "no guards" leaves every row visible,
            // which is the same as a menu whose guards all passed.
            root.whenResults = ({});
            root.checkedResults = ({});
            root.guardsResolved = true;
            return;
        }
        if (!script) {
            root.guardsResolved = true;
            return;
        }
        root.guardsRunning = true;
        guardProc.collected = "";
        guardProc.command = ["bash", "-c", script];
        guardProc.running = true;
    }

    Process {
        id: guardProc

        /** Raw stdout, accumulated line by line. Not stdout itself: the answers
         *  are only usable once the script has finished, and a streaming parse
         *  would have to handle a half-written line. */
        property string collected: ""

        stdout: SplitParser {
            onRead: (line) => { guardProc.collected += line + "\n"; }
        }
        onExited: {
            root.applyGuards(guardProc.collected);
            root.guardsRunning = false;
            // Cleared so a second open re-runs cleanly: `running` is already false
            // by the time onExited fires, but the collected buffer would otherwise
            // still hold the previous answers if a later run appended to it.
            guardProc.collected = "";
        }
    }

    /**
     * `<id>:<w|c>:<0|1>` per line. A malformed line is skipped rather than
     * allowed to blank the whole map: one bad guard should cost its own row, not
     * the visibility of the whole menu.
     */
    function applyGuards(raw) {
        var when_ = ({});
        var checked_ = ({});
        var lines = String(raw || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].split(":");
            if (parts.length !== 3)
                continue;
            var id = parts[0];
            var ok = parts[2] === "1";
            if (parts[1] === "w")
                when_[id] = ok;
            else if (parts[1] === "c")
                checked_[id] = ok;
        }
        root.whenResults = when_;
        root.checkedResults = checked_;
        root.guardsResolved = true;
    }

    // ---- apps (native provider) -------------------------------------------

    /**
     * Desktop entries as `apps.*` rows under the Apps submenu.
     *
     * QML-native rather than a bash enumeration, matching the stock menu: rows
     * need real image icons and launch feedback, and an installed app should rank
     * by how often it is actually used — which the launcher already tracks in
     * its own usage file.
     */
    function mergeAppRows(usage) {
        if (typeof DesktopEntries === "undefined" || !DesktopEntries.applications)
            return;
        var src = DesktopEntries.applications.values;
        var rows = [];
        for (var i = 0; i < src.length; i++) {
            var entry = src[i];
            if (!entry || entry.noDisplay)
                continue;
            var appId = String(entry.id || "");
            if (!appId)
                continue;
            var subtext = "";
            if (entry.genericName && entry.genericName.length > 0)
                subtext = String(entry.genericName);
            var aliases = [];
            if (subtext)
                aliases.push(subtext);
            if (entry.keywords && typeof entry.keywords.length === "number")
                for (var k = 0; k < entry.keywords.length; k++)
                    aliases.push(String(entry.keywords[k]));
            rows.push({
                id: "apps." + appId,
                parent: "apps",
                kind: "app",
                icon: "",
                appIcon: String(entry.icon || ""),
                appId: appId,
                label: String(entry.name || appId),
                title: "",
                target: "",
                description: subtext,
                action: "",
                provider: "",
                aliases: aliases,
                when: "",
                checked: "",
                order: 0
            });
        }
        var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, rows);
        root.items = merged.items;
        root.itemOrder = merged.itemOrder;
    }

    // ---- providers ---------------------------------------------------------

    /**
     * Shell providers, same one-liners the stock menu uses: each emits
     * tab-delimited `label\tvalue\tcurrent` rows. `volatile` ones re-run each
     * time their submenu is entered, so a font installed after the shell started
     * shows up without a restart.
     */
    /**
     * Absolute path to an owned script.
     *
     * Spelled out rather than taken from `Config.hyprPath` because using it here
     * would mean importing `../Singletons` from a file that *lives in*
     * Singletons/ — a self-import, which Quickshell resolves into a cycle and
     * then fails to instantiate anything that touches the singleton.
     */
    readonly property string scriptsDir: (Quickshell.env("HOME") || "")
        + "/.local/share/quickshell/better/scripts"
    readonly property string keybindingsScript: root.scriptsDir + "/keybindings.sh"

    readonly property var providers: ({
        /**
         * The keybinding table, as browsable rows.
         *
         * This is the one thing `omarchy-menu-keybindings` cannot do on this
         * desktop: it builds the table correctly and then hands it to
         * `omarchy-menu-select`, which summons `omarchy.menu` — a plugin in
         * disabledPlugins — so `SUPER + K` produced nothing on screen. The rows
         * come from `scripts/keybindings.sh --print`, which reads the same
         * stock cache in the same priority order, and activating one shells back
         * to `--dispatch <label>`, which runs the binding.
         *
         * `volatile` because the table is rebuilt whenever the user edits their
         * bindings; re-running on entry means the list is never stale.
         */
        "keybindings": {
            // Three columns: the key combo on its own, the whole cached
            // display line verbatim (that is what `--dispatch` matches on),
            // and the action it runs. The stock cache pads the key to a
            // fixed column so the arrows line up, which makes a single
            // padded string too wide for a row and pushes the useful half
            // off the edge; splitting it puts the combo in the label and
            // the action on the secondary line, where the launcher has a
            // whole line for it.
            script: root.keybindingsScript + " --print 2>/dev/null | head -400 | while IFS= read -r l; do [[ -z $l ]] && continue; k=${l%%→*}; a=${l#*→}; [[ $a == \"$l\" ]] && { printf '%s\\t%s\\t\\n' \"$l\" \"$l\"; continue; }; k=$(printf '%s' \"$k\" | sed 's/[[:space:]]*$//'); a=$(printf '%s' \"$a\" | sed 's/^[[:space:]]*//'); printf '%s\\t%s\\t%s\\n' \"$k\" \"$l\" \"$a\"; done",
            icon: "",
            volatile: true,
            descriptionColumn: true,
            actionFor: function (value) {
                return root.keybindingsScript + " --dispatch " + shellQuote(value) + " >/dev/null 2>&1";
            }
        },
        "fonts": {
            script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
            icon: "",
            volatile: true,
            actionFor: function (value) {
                return "omarchy-font-set " + shellQuote(value);
            }
        },
        "power-profiles": {
            script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
            icon: "",
            volatile: true,
            actionFor: function (value) {
                return "omarchy-powerprofiles-set autodetect " + shellQuote(value);
            }
        }
    })

    /**
     * Positional shell quoting for a command *argument*, without exec'ing a
     * shell to build it. Single quotes suppress every expansion, and the
     * embedded `'` is closed, escaped and reopened — the standard `'\''` dance.
     */
    function shellQuote(value) {
        return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'";
    }

    /** Load `menuId`'s provider if it has one and has not been loaded yet. */
    function ensureProvider(menuId) {
        var entry = MenuModel.item(root.items, menuId);
        if (!entry || !entry.provider || root.providersLoaded[menuId])
            return;
        if (entry.provider === "apps") {
            // Native: the surface calls mergeAppRows itself, since it owns the
            // usage ranking the rows are ordered by.
            root.providersLoaded[menuId] = true;
            return;
        }
        var spec = root.providers[entry.provider];
        if (!spec) {
            // An unknown provider name is a menu-file error, not a crash. Mark it
            // loaded so it is not retried on every open, and the row shows as an
            // empty submenu.
            root.providersLoaded[menuId] = true;
            return;
        }
        root.providersLoaded[menuId] = true;
        providerProc.menuId = menuId;
        providerProc.spec = spec;
        providerProc.collected = "";
        providerProc.command = ["bash", "-c", spec.script];
        providerProc.running = true;
    }

    /** Re-run a volatile provider, so its rows reflect the world right now. */
    function refreshProvider(menuId) {
        var entry = MenuModel.item(root.items, menuId);
        if (!entry || !entry.provider)
            return;
        var spec = root.providers[entry.provider];
        if (spec && spec.volatile)
            root.providersLoaded[menuId] = false;
        root.ensureProvider(menuId);
    }

    Process {
        id: providerProc

        property string menuId: ""
        property var spec: null
        property string collected: ""

        stdout: SplitParser {
            onRead: (line) => { providerProc.collected += line + "\n"; }
        }
        onExited: {
            root.mergeProviderRows(providerProc.menuId, providerProc.spec, providerProc.collected);
            providerProc.collected = "";
        }
    }

    function mergeProviderRows(menuId, spec, raw) {
        if (!spec || menuId.length === 0)
            return;
        var current = "";
        var lines = String(raw || "").split("\n");
        var rows = [];
        for (var i = 0; i < lines.length; i++) {
            if (!lines[i])
                continue;
            var parts = lines[i].split("\t");
            if (parts.length < 2)
                continue;
            var label = parts[0];
            var value = parts[1];
            // Column 2 means different things to different providers: the
            // value-listing ones (fonts, power profiles) put the current
            // selection there so a row can carry its ✓, while the
            // keybinding table puts the action it runs there -- it is not
            // a selection, so it rides on the row's secondary line instead.
            if (parts.length > 2) {
                if (spec.descriptionColumn)
                    var description = parts[2];
                else
                    current = parts[2];
            }
            rows.push({
                id: menuId + "." + MenuModel.slugify(value),
                parent: menuId,
                kind: "action",
                icon: spec.icon || "",
                iconFont: "",
                label: label,
                title: "",
                target: "",
                // `checked:` is already answered for the JSONC rows; for a
                // provider row the current value is the last column, so it is
                // compared here and marked by `checked`.
                description: spec.descriptionColumn ? (description || "") : "",
                action: spec.actionFor ? spec.actionFor(value) : "",
                provider: "",
                aliases: [],
                when: "",
                checked: "",
                isCurrent: current.length > 0 && current === value,
                order: rows.length
            });
        }
        var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, rows);
        root.items = merged.items;
        root.itemOrder = merged.itemOrder;
    }

    // ---- queries -----------------------------------------------------------

    function item(id) { return MenuModel.item(root.items, id); }
    function resolveRoute(route) { return MenuModel.resolveRoute(root.items, root.itemOrder, route); }
    function pathFor(id) { return MenuModel.pathFor(root.items, id); }
    function childCount(id) { return MenuModel.childCount(root.items, root.itemOrder, id); }
    function labelFor(entry) { return MenuModel.labelFor(entry, root.checkedResults); }

    /** Visible children of a submenu, in declaration order. */
    function childrenOf(parentId) {
        return MenuModel.childrenOf(root.items, root.itemOrder, root.whenResults, parentId);
    }

    /** Every matching row in the whole tree, best first. */
    function search(query, opts) {
        return MenuModel.searchRows(root.items, root.itemOrder, root.whenResults, query, opts);
    }

    /**
     * Run a row's action. `action` is a shell command from the menu file, so it
     * goes through `bash -c` deliberately — the stock menu does the same, and
     * several shipped actions are shell snippets (`theme=$(…); [[ -n $theme ]] && …`).
     */
    function runAction(action) {
        var command = String(action || "");
        if (!command)
            return;
        Quickshell.execDetached(["bash", "-c", command]);
    }

    /**
     * Activate a row: descend into it if it has children, run it if it is an
     * action, follow it if it is a link. Returns true when the surface should
     * close (the row did something terminal).
     */
    function activate(entry) {
        if (!entry)
            return false;
        if (entry.kind === "action") {
            root.runAction(entry.action);
            return true;
        }
        var target = entry.kind === "link" ? entry.target : entry.id;
        root.ensureProvider(target);
        return false;
    }
}