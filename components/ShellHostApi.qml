import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Omarchy host-shell API, implemented natively.
 *
 * Better Bar is a bar, not a host: its own Plugins singleton used to shell out to
 * `omarchy-shell shell <method>` for every piece of plugin state, which only
 * works while the stock Omarchy shell is the process answering. As the sole
 * shell there is nobody to ask, so the request has to terminate here instead.
 *
 * This exposes the same `shell` IpcHandler target the stock shell registers
 * (see $OMARCHY_PATH/shell/shell.qml), so `omarchy plugin …`, `omarchy bar …`,
 * `omarchy shell-config` and Better Bar's own plugin surface all speak one
 * implementation against one source of truth: ~/.config/omarchy/shell.json.
 *
 * The root is an Item only because a QtObject has no default property and so
 * cannot own the FileView/Process children below. It draws nothing.
 */
Item {
    id: host

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

    /** $OMARCHY_PATH/config/omarchy/shell.json, the shipped defaults. */
    property var defaultsConfig: ({})
    /** ~/.config/omarchy/shell.json, the user's config and the only file written. */
    property var userConfig: ({})
    /** Defaults with the user's config layered over, which is what the stock
     *  shell reports as its effective shellConfig. */
    property var config: ({})

    /** id -> manifest, user plugins winning over first-party on a shared id. */
    property var manifests: ({})

    /**
     * Omarchy's current palette, parsed from the active theme's colors.toml.
     * Better Bar has a palette of its own, so this is an overlay: keys present here
     * win, and anything the theme does not name keeps Better Bar's value. Omarchy
     * themes bundle a wallpaper, so this also tracks wallpaper changes.
     */
    property var omarchyColors: ({})
    readonly property string themeColorsPath: home + "/.local/state/omarchy/current/theme/colors.toml"
    property bool ready: false

    /** A plugin id asked to open/close a panel. Better Bar surfaces are opened
     *  by name, so the shell decides whether it owns one; nothing is faked. */
    signal panelAction(string id, string verb, string payload)

    // ---- config ------------------------------------------------------------

    readonly property string defaultsPath: omarchyPath + "/config/omarchy/shell.json"
    readonly property string userConfigPath: home + "/.config/omarchy/shell.json"

    function isPlainObject(value) {
        return value !== null && typeof value === "object" && !Array.isArray(value)
    }

    function deepMerge(base, over) {
        var out = JSON.parse(JSON.stringify(isPlainObject(base) ? base : {}))
        if (!isPlainObject(over))
            return out
        for (var key in over) {
            if (isPlainObject(out[key]) && isPlainObject(over[key]))
                out[key] = deepMerge(out[key], over[key])
            else
                out[key] = over[key]
        }
        return out
    }

    function recompute() {
        host.config = host.deepMerge(host.defaultsConfig, host.userConfig)
        host.ready = true
    }

    // ---- plugin facts ------------------------------------------------------

    function kindsOf(id) {
        var m = host.manifests[String(id)]
        return m && Array.isArray(m.kinds) ? m.kinds : []
    }

    function isBarOption(id) {
        return host.kindsOf(id).indexOf("bar") !== -1
    }

    function isBarWidget(id) {
        return host.kindsOf(id).indexOf("bar-widget") !== -1
    }

    function sections() {
        var bar = host.isPlainObject(host.config.bar) ? host.config.bar : {}
        var layout = host.isPlainObject(bar.layout) ? bar.layout : {}
        return {
            left: Array.isArray(layout.left) ? layout.left : [],
            center: Array.isArray(layout.center) ? layout.center : [],
            right: Array.isArray(layout.right) ? layout.right : []
        }
    }

    function findInBar(id) {
        var layout = host.sections()
        var names = ["left", "center", "right"]
        for (var s = 0; s < names.length; s++) {
            for (var i = 0; i < layout[names[s]].length; i++) {
                if (layout[names[s]][i] && layout[names[s]][i].id === id)
                    return { section: names[s], index: i }
            }
        }
        return null
    }

    function inBar(id) {
        return host.findInBar(id) !== null
    }

    function isEnabled(id) {
        if (host.isBarOption(id)) {
            var bar = host.isPlainObject(host.config.bar) ? host.config.bar : {}
            var selected = String(bar.id || "")
            if (!selected)
                selected = "omarchy.bar"
            return selected === id
        }
        var disabled = Array.isArray(host.config.disabledPlugins) ? host.config.disabledPlugins : []
        return disabled.indexOf(id) === -1
    }

    function isActiveBarOption(id) {
        return host.isBarOption(id) && host.isEnabled(id)
    }

    // ---- persistence -------------------------------------------------------

    /** Mutate the user's shell.json. `mutate` receives a private copy. */
    function mutate(mutateFn) {
        var copy = JSON.parse(JSON.stringify(host.isPlainObject(host.userConfig) ? host.userConfig : {}))
        var error = mutateFn(copy)
        if (error)
            return error
        host.userConfig = copy
        host.recompute()
        try {
            writer.setText(JSON.stringify(copy, null, 2) + "\n")
        } catch (e) {
            console.warn("ShellHostApi: could not write " + host.userConfigPath + ": " + e)
            return "write failed: " + e
        }
        return ""
    }

    // ---- bar placement -----------------------------------------------------

    function defaultPlacement(id) {
        var m = host.manifests[String(id)]
        var widget = m && host.isPlainObject(m.barWidget) ? m.barWidget : {}
        var section = String(widget.defaultSection || "right")
        if (["left", "center", "right"].indexOf(section) === -1)
            section = "right"
        return { section: section }
    }

    function ensureShape(copy) {
        if (!host.isPlainObject(copy.bar))
            copy.bar = {}
        if (!host.isPlainObject(copy.bar.layout))
            copy.bar.layout = {}
        var layout = copy.bar.layout
        if (!Array.isArray(layout.left)) layout.left = []
        if (!Array.isArray(layout.center)) layout.center = []
        if (!Array.isArray(layout.right)) layout.right = []
        return layout
    }

    function putEntry(copy, id, placement) {
        var layout = host.ensureShape(copy)
        var section = String((placement && placement.section) || "right")
        if (["left", "center", "right"].indexOf(section) === -1)
            section = "right"
        var entry = host.isPlainObject(placement) && host.isPlainObject(placement.settings)
            ? JSON.parse(JSON.stringify(placement.settings)) : { id: id }
        entry.id = id
        var rows = layout[section]
        var index = placement && placement.index !== undefined && placement.index !== null
            ? Number(placement.index) : -1
        if (index < 0 || index > rows.length)
            index = rows.length
        rows.splice(index, 0, entry)
    }

    function moveEntry(copy, id, placement) {
        var here = host.findInBarIn(copy, id)
        if (!here)
            return "not in bar: " + id
        var layout = host.ensureShape(copy)
        var entry = layout[here.section].splice(here.index, 1)[0]
        var section = String((placement && placement.section) || here.section)
        if (["left", "center", "right"].indexOf(section) === -1)
            section = here.section
        var rows = layout[section]
        var index = placement && placement.index !== undefined && placement.index !== null
            ? Number(placement.index) : -1
        if (index < 0 || index > rows.length)
            index = rows.length
        rows.splice(index, 0, entry)
        return ""
    }

    function findInBarIn(config, id) {
        var previous = host.config
        host.config = config
        var found = host.findInBar(id)
        host.config = previous
        return found
    }

    function setEntrySettings(copy, id, key, value) {
        var here = host.findInBarIn(copy, id)
        if (!here)
            return "not in bar: " + id
        var layout = host.ensureShape(copy)
        layout[here.section][here.index][key] = value
        return ""
    }

    // ---- the omarchy-shell `shell` contract --------------------------------



    function ping() {
        return "ok"
    }

    function listPlugins() {
        var out = []
        for (var id in host.manifests) {
            var manifest = host.manifests[id]
            var kinds = Array.isArray(manifest.kinds) ? manifest.kinds : []
            var option = kinds.indexOf("bar") !== -1
            var widget = kinds.indexOf("bar-widget") !== -1
            var active = option && host.isActiveBarOption(id)
            var metadata = manifest.omarchy
            out.push({
                id: id,
                name: manifest.name,
                kinds: kinds,
                enabled: option ? active : (widget ? host.inBar(id) : host.isEnabled(id)),
                active: active,
                canDisable: !option,
                firstParty: !!manifest.__isFirstParty,
                clonedFrom: host.isPlainObject(metadata) ? String(metadata.clonedFrom || "") : ""
            })
        }
        out.sort(function (left, right) {
            var a = String(left.name || left.id)
            var b = String(right.name || right.id)
            if (a < b) return -1
            if (a > b) return 1
            return String(left.id).localeCompare(String(right.id))
        })
        return JSON.stringify(out)
    }

    function listShellConfig() {
        return JSON.stringify(host.config || {})
    }

    function listShellConfigFull() {
        return JSON.stringify({
            defaultsPath: host.defaultsPath,
            userConfigPath: host.userConfigPath,
            config: host.config
        })
    }

    function rescanPlugins() {
        host.rescan()
    }

    function reloadConfig() {
        host.reloadConfigs()
        return "ok"
    }

    function setPluginEnabled(id, enabled) {
        var on = enabled === "true"
        if (!host.manifests[String(id)])
            return "unknown"
        if (host.isBarOption(id))
            return on ? "ok" : "unknown"
        if (!on)
            return host.setPluginDisabled(id)
        return host.enablePlugin(id, JSON.stringify(host.defaultPlacement(id)))
    }

    function enablePlugin(id, placementJson) {
        if (!host.manifests[String(id)])
            return "unknown"
        var placement = {}
        try { placement = JSON.parse(placementJson || "{}") } catch (e) { return "invalid placement: " + e }
        if (host.isBarWidget(id)) {
            if (host.inBar(id))
                return "ok"
            var error = host.mutate(function (copy) { host.putEntry(copy, id, placement) })
            return error ? error : "ok"
        }
        if (host.isBarOption(id))
            return "ok"
        var off = host.mutate(function (copy) {
            if (!Array.isArray(copy.disabledPlugins))
                copy.disabledPlugins = []
            var at = copy.disabledPlugins.indexOf(id)
            if (at === -1)
                copy.disabledPlugins.push(id)
        })
        return off ? off : "ok"
    }

    function setPluginDisabled(id) {
        if (!host.manifests[String(id)])
            return "unknown"
        if (host.isBarWidget(id)) {
            var removed = host.mutate(function (copy) {
                var layout = host.ensureShape(copy)
                var names = ["left", "center", "right"]
                for (var s = 0; s < names.length; s++)
                    layout[names[s]] = layout[names[s]].filter(function (row) { return !row || row.id !== id })
            })
            return removed ? removed : "ok"
        }
        var on = host.mutate(function (copy) {
            if (!Array.isArray(copy.disabledPlugins))
                copy.disabledPlugins = []
            copy.disabledPlugins = copy.disabledPlugins.filter(function (row) { return row !== id })
        })
        return on ? on : "ok"
    }

    function putBarWidget(id, placementJson) {
        if (!host.manifests[String(id)])
            return "unknown"
        if (host.inBar(id))
            return "ok"
        var placement = {}
        try { placement = JSON.parse(placementJson || "{}") } catch (e) { return "invalid placement: " + e }
        var error = host.mutate(function (copy) { host.putEntry(copy, id, placement) })
        return error ? error : "ok"
    }

    function moveBarWidget(id, placementJson) {
        if (!host.manifests[String(id)])
            return "unknown"
        var placement = {}
        try { placement = JSON.parse(placementJson || "{}") } catch (e) { return "invalid placement: " + e }
        var error = host.mutate(function (copy) { host.moveEntry(copy, id, placement) })
        return error ? error : "ok"
    }

    function setBarWidget(id, key, valueJson, selectorJson) {
        if (!host.manifests[String(id)])
            return "unknown"
        var value
        try { value = JSON.parse(valueJson) } catch (e) { return "invalid widget setting: " + e }
        var error = host.mutate(function (copy) { host.setEntrySettings(copy, id, key, value) })
        return error ? error : "ok"
    }

    function summon(id, payloadJson) {
        host.panelAction(id, "summon", payloadJson || "{}")
        return "ok"
    }

    function hide(id) {
        host.panelAction(id, "hide", "{}")
    }

    function toggle(id, payloadJson) {
        host.panelAction(id, "toggle", payloadJson || "{}")
    }

    function call(id, method, arg) {
        host.panelAction(id, "call:" + method, arg || "")
        return ""
    }

    // ---- omarchy theme ------------------------------------------------------

    /**
     * A flat `key = "value"` read, which is the whole of colors.toml's shape.
     * Comments and sections are skipped; later keys win.
     */
    function parseColors(text) {
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

    function loadCurrentTheme() {
        themeProc.running = true
    }

    /** The `shell applyTheme` the omarchy theme scripts call. */
    function applyTheme(colorsB64, shellB64) {
        var raw = ""
        try { raw = Qt.atob(String(colorsB64 || "")) } catch (e) { raw = "" }
        if (!raw)
            return "no colors"
        host.omarchyColors = host.parseColors(raw)
        return "ok"
    }

    // ---- plumbing ----------------------------------------------------------

    function rescan() {
        scanProc.running = true
    }

    function reloadConfigs() {
        userProc.running = true
        defaultsProc.running = true
    }

    Process {
        id: defaultsProc
        command: ["cat", host.defaultsPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { host.defaultsConfig = JSON.parse(String(text || "").trim() || "{}") }
                catch (e) { host.defaultsConfig = ({}) }
                host.recompute()
            }
        }
    }

    Process {
        id: userProc
        command: ["cat", host.userConfigPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try { host.userConfig = JSON.parse(String(text || "").trim() || "{}") }
                catch (e) { host.userConfig = ({}) }
                host.recompute()
            }
        }
    }

    FileView {
        id: writer
        path: host.userConfigPath
        printErrors: false
    }

    Process {
        id: themeProc
        command: ["cat", host.themeColorsPath]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var text_ = String(text || "").trim()
                if (text_)
                    host.omarchyColors = host.parseColors(text_)
            }
        }
    }

    Process {
        id: scanProc
        // First-party plugins live in the omarchy package, not under
        // $OMARCHY_PATH/shell (which is Better Bar itself), so the package path is
        // named directly rather than derived.
        command: ["sh", "-c",
            "find /usr/share/omarchy/shell/plugins \"$HOME/.config/omarchy/plugins\""
            + " -maxdepth 3 \\( -name manifest.json -o -name '*.manifest.json' \\) -print0 2>/dev/null"
            + " | while IFS= read -r -d '' m; do"
            + " jq -c --arg d \"$(dirname \"$m\")\""
            + " '{id:.id,name:.name,kinds:(.kinds//[]),entryPoints:(.entryPoints//{}),dir:$d,omarchy:(.omarchy//{})}' \"$m\";"
            + " done"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var map = {}
                var firstParty = "/usr/share/omarchy/shell/plugins"
                var lines = String(text || "").split("\n")
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim()
                    if (!line)
                        continue
                    var manifest = null
                    try { manifest = JSON.parse(line) } catch (e) { continue }
                    if (!manifest || !manifest.id)
                        continue
                    manifest.__isFirstParty = String(manifest.dir || "").indexOf(firstParty) === 0
                    // A user clone shadows the first-party plugin it replaces.
                    if (map[manifest.id] && map[manifest.id].__isFirstParty && !manifest.__isFirstParty)
                        continue
                    map[manifest.id] = manifest
                }
                host.manifests = map
            }
        }
    }

    Component.onCompleted: {
        host.rescan()
        host.reloadConfigs()
        host.loadCurrentTheme()
    }
}
