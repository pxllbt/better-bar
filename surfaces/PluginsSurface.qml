pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../Singletons"
import "../components"

/**
 * PLUGINS: the plugin index, reachable from the settings tiles (相→Plugins)
 * and the pill's own hover row.
 *
 * The host shell owns plugin state, so every action here is a thin call into it
 * (see Plugins.qml) rather than a second implementation of discovery, enabling
 * or installation. What this surface adds is the part the terminal does badly:
 * a live inventory, and a switch that says what a plugin actually is.
 *
 * Enabling a bar-widget is what writes its layout entry, and that is also the
 * signal that it gets a strip entry (PluginButton), so the toggle here and the
 * icon in the strip stay in step. Panel-kind plugins have no bar entry to place
 * and are described as opening on demand instead.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"

    /** Bounded list height; the inventory scrolls below the fold. */
    readonly property real listCap: 240 * root.s

    /** Live plugin rows, kept in step with the Repeater below. */
    property var pluginRows: []

    readonly property var sorted: {
        var out = Plugins.plugins.slice();
        out.sort(function (a, b) {
            var an = String(a.name || a.id).toLowerCase();
            var bn = String(b.name || b.id).toLowerCase();
            return an < bn ? -1 : (an > bn ? 1 : 0);
        });
        return out;
    }

    /**
     * The live inventory filter, bound straight to the search
     * field's text so it narrows as the user types; empty shows
     * every plugin. Matches the display name or the raw id, so
     * "weather" finds omarchy.weather and "weather" finds it too.
     */
    readonly property string query: pluginSearch.text
    // 'all' | 'first-party' | 'third-party'
    property string filterMode: "all"

    /* The global automation/install controls are not what someone opens the
     * Plugins page for. They used to sit above the inventory, so every open
     * started with eight rows before the first plugin. They are one row now and
     * expand in place when asked for. */
    property bool advancedOpen: false
    property bool installOpen: false
    onAdvancedOpenChanged: root.syncRows()
    onInstallOpenChanged: root.syncRows()

    readonly property bool showStatus: Plugins.busy
        || Plugins.healingNeeded
        || Plugins.lastError.length > 0
        || Plugins.lastOutput.length > 0

    readonly property string automationSummary:
        (Plugins.autoCheckEnabled ? "check on" : "check off")
        + " · " + (Flags.pluginAutoUpdate ? "auto-update on" : "manual updates")
        + " · " + (Flags.pluginAutoIntegrate ? "adopt on" : "adopt off")
        + " · " + (Flags.pluginSelfHeal ? "self-heal on" : "self-heal off")

    readonly property var filtered: {
        var q = root.query.trim().toLowerCase();
        var mode = root.filterMode;
        var out = [];
        for (var i = 0; i < root.sorted.length; i++) {
            var p = root.sorted[i];
            if (mode === "first-party" && p.firstParty !== true) continue;
            if (mode === "third-party" && p.firstParty === true) continue;
            if (q !== "") {
                if (String(p.name || p.id).toLowerCase().indexOf(q) === -1
                    && String(p.id).toLowerCase().indexOf(q) === -1
                    && (p.kinds || []).join(" ").toLowerCase().indexOf(q) === -1)
                    continue;
            }
            out.push(p);
        }
        return out;
    }

    readonly property bool busy: Plugins.busyWith !== ""

    function registerRow(item) {
        if (root.pluginRows.indexOf(item) === -1) {
            root.pluginRows = root.pluginRows.concat([item]);
            root.syncRows();
        }
    }

    function unregisterRow(item) {
        var next = root.pluginRows.slice();
        var at = next.indexOf(item);
        if (at !== -1) {
            next.splice(at, 1);
            root.pluginRows = next;
            root.syncRows();
        }
    }

    /**
     * Rebuild the shared nav list. The collapsed global controls are only in the
     * registry while they are on screen, so the arrows walk the same rows the
     * user can see: updates, install, (advanced controls), inventory, status.
     */
    function syncRows() {
        var rows = [
            // The update row is the only one here that does something rather
            // than toggle or navigate, so it carries an `activate` -- the
            // dispatcher's escape hatch. An `onClicked` on the row itself would
            // look equivalent and would not work: SettingsRow has no such
            // property, and assigning one fails the whole shell at load, which
            // is how the bar came to be missing entirely.
            { item: updatesRow, kind: "toggle",
              get: function () { return false; },
              activate: function () {
                  if (Plugins.updateCount > 0)
                      Plugins.updateAll();
                  else
                      Plugins.checkForUpdates();
              } },
            { item: automationRow, kind: "toggle",
              get: function () { return root.advancedOpen; },
              activate: function () { root.advancedOpen = !root.advancedOpen; } },
            { item: installRow, kind: "toggle",
              get: function () { return root.installOpen; },
              activate: function () { root.installOpen = !root.installOpen; } }
        ];

        if (root.installOpen) {
            rows = rows.concat([
                { item: doInstallRow, kind: "toggle", get: function () { return false; },
                  set: function (v) { root.install(urlField.text); } }
            ]);
        }

        if (root.advancedOpen) {
            rows = rows.concat([
                { item: autoCheckRow, kind: "toggle",
                  get: function () { return Plugins.autoCheckEnabled; },
                  set: function (v) { Plugins.autoCheckEnabled = v; } },
                { item: autoUpdateRow, kind: "toggle",
                  get: function () { return Flags.pluginAutoUpdate; },
                  set: function (v) { Flags.pluginAutoUpdate = v; } },
                { item: autoAdoptRow, kind: "toggle",
                  get: function () { return Flags.pluginAutoIntegrate; },
                  set: function (v) { Flags.pluginAutoIntegrate = v; } },
                { item: selfHealRow, kind: "toggle",
                  get: function () { return Flags.pluginSelfHeal; },
                  set: function (v) { Flags.pluginSelfHeal = v; } },
                { item: repairRow, kind: "toggle",
                  get: function () { return false; },
                  activate: Plugins.healAll }
            ]);
        }

        if (Plugins.needsShellRestart) {
            rows = rows.concat([
                { item: restartRow, kind: "toggle",
                  get: function () { return false; },
                  activate: function () { Plugins.restartShell(); } }
            ]);
        }

        rows = rows.concat([
            { item: countRow, kind: "toggle", get: function () { return false; },
              set: function () { Plugins.rescan(); } }
        ]).concat(root.pluginRows);

        if (root.showStatus) {
            rows = rows.concat([
                { item: statusRow, kind: "toggle", get: function () { return false; },
                  set: function () { Plugins.rescan(); } }
            ]);
        }

        root.rows = rows;
    }

    /** Keep the focused row in view when the arrows move below the fold. */
    function followFocus(item) {
        if (!item || item === installRow || item === doInstallRow
            || item === countRow || item === statusRow
            || item === automationRow || item === restartRow
            || item === autoCheckRow || item === autoUpdateRow
            || item === autoAdoptRow || item === selfHealRow || item === repairRow)
            return;
        var y = item.mapToItem(scroll.contentItem, 0, 0).y;
        if (y < scroll.contentY) {
            scroll.contentY = Math.max(0, y - 2 * root.s);
        } else if (y + item.height > scroll.contentY + scroll.height) {
            scroll.contentY = y + item.height - scroll.height + 2 * root.s;
        }
    }

    function install(url) {
        var trimmed = String(url || "").trim();
        if (trimmed.length === 0)
            return;
        Plugins.install(trimmed);
    }

    /** One line: what it is, where it came from, and what enabling it will do. */
    function describe(p) {
        if (!p)
            return "";
        var order = ["bar-widget", "panel", "overlay", "menu", "service"];
        var bits = [];
        for (var i = 0; i < order.length; i++) {
            if (p.kinds.indexOf(order[i]) !== -1) {
                bits.push(order[i] === "bar-widget" ? "bar" : order[i]);
            }
        }
        if (bits.length === 0)
            bits = p.kinds.slice();

        var origin = p.firstParty === true ? "built-in"
            : (p.clonedFrom ? "clone of " + p.clonedFrom : "third-party");
        var mode = root.modeFor(p);
        var cap = Plugins.capabilityFor(p.id);
        var effect = mode === "strip"
            ? "enable adds a strip icon"
            : (mode === "replaced"
                ? (cap && Plugins.ownCapabilities[cap]
                    ? "Better Bar provides its own" + (Plugins.providerChosen(p) ? "" : " · use this instead")
                    : "Better Bar provides its own · nothing appears here")
                : "no strip icon · the host renders its own window");
        return bits.join(" · ") + " · " + origin + " · " + effect;
    }

    /**
     * What enabling this plugin will really do inside Better Bar.
     *
     * The row model is the *host* registry, but the only thing this shell can
     * put on screen out of it is a strip entry, and `Plugins.pillWidgetsGeneric`
     * is the sole source of those. So a plugin can be toggled on here, the host
     * will report it enabled, and nothing will ever appear: either it is a
     * bar-widget this shell supersedes with its own, or it is not a bar-widget
     * at all and has no strip entry to begin with. Telling those users "enable
     * adds a strip icon" is what made this list look broken.
     *
     *   "strip"      an ordinary bar-widget; enabling adds a strip icon.
     *   "replaced"   a bar-widget Better Bar supersedes with its own surface,
     *                so it is filtered out of the strip — until the user
     *                hands that capability to the plugin, which the row
     *                below offers.
     *   "own-window" not a bar-widget; no strip entry exists, and the host
     *                draws it as its own window instead.
     */
    function modeFor(p) {
        if (!p)
            return "own-window";
        if (Plugins.hostsInStrip(p))
            return "strip";
        if (p.kinds.indexOf("bar-widget") === -1)
            return "own-window";
        return "replaced";
    }

    implicitHeight: body.implicitHeight

    Component.onCompleted: {
        if (Quickshell.env("BETTER_PLUGIN_SELFTEST") === "1")
            console.log("[better] PluginsSurface constructed; plugins=" + Plugins.plugins.length
                + " loaded=" + Plugins.loaded
                + " first=" + (Plugins.plugins.length > 0 ? Plugins.plugins[0].id : "none"));
        Qt.callLater(root.syncRows);
    }

    onOpenChanged: {
        Plugins.surfaceOpen = open;
        if (open) {
            Plugins.refresh();
            // Opening is the natural moment to check: you came here because
            // something is wrong with a plugin, and "an update is waiting" is
            // the cheapest possible answer to that. Not on a timer — a check
            // hits the network per plugin, which is not something to do every
            // few seconds on someone's behalf.
            Plugins.checkForUpdates();
        }
        // The search field opens ready to type. Deferred a beat because
        // forceActiveFocus() is a no-op before the item is in the scene, and
        // without this the field opens unfocused — a search you have to click
        // before it accepts a single keystroke.
        Qt.callLater(function () {
            if (open)
                pluginSearch.forceActiveFocus();
        });
    }

    Connections {
        target: root
        function onFocusRowItemChanged() { root.followFocus(root.focusRowItem); }
    }

    Connections {
        target: Plugins
        function onBusyWithChanged() { root.syncRows(); }
        function onHealingNeededChanged() { root.syncRows(); }
        function onNeedsShellRestartChanged() { root.syncRows(); }
        function onLastErrorChanged() { root.syncRows(); }
        function onLastOutputChanged() { root.syncRows(); }
    }

    SettingsHeader {
        s: root.s
        glyph: "⬡"
        title: "PLUGINS"
        showBack: true
    }

    Column {
        id: body
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        Item { width: 1; height: 7 * root.s }

        /**
         * The auto part: the bar notices updates instead of you noticing them.
         *
         * This is a row rather than a button because it has three states worth
         * showing, and only one of them is an action: nothing to do, updates
         * waiting, and "I could not ask" — which is deliberately not shown as
         * "up to date", because a host we could not reach tells you nothing.
         */
        SettingsRow {
            id: updatesRow
            surface: root
            icon: Plugins.checkingUpdates ? "refresh" : "download"
            name: {
                if (Plugins.checkingUpdates)
                    return "Checking for updates…";
                if (Plugins.updateCount > 0)
                    return Plugins.updateCount + (Plugins.updateCount === 1 ? " update available" : " updates available");
                return "Plugins are up to date";
            }
            sub: {
                if (Plugins.updateError)
                    return "Could not check";
                if (Plugins.updateCount > 0)
                    return "Tap to update all git-managed plugins";
                return "Check now · refs only, never merges";
            }
        }

        /**
         * The collapsed automation group. All four settings stay, but they cost
         * one row until asked for; the summary row says what each one is doing
         * without opening them.
         */
        SettingsRow {
            id: automationRow
            surface: root
            icon: "layers"
            name: root.advancedOpen ? "Hide automation" : "Automation"
            sub: root.automationSummary

            GlyphIcon {
                width: 15 * root.s
                height: 15 * root.s
                name: "chevron-right"
                color: root.focusRowItem === automationRow ? Theme.cream : Theme.iconDim
                stroke: 1.8
                rotation: root.advancedOpen ? 90 : 0
                transformOrigin: Item.Center
                Behavior on rotation { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
            }
        }

        SettingsRow {
            id: installRow
            surface: root
            icon: "download"
            name: "Install from URL"
            sub: root.installOpen ? "Paste a repository URL" : "git clone · validated · then rescanned"

            GlyphIcon {
                width: 15 * root.s
                height: 15 * root.s
                name: "chevron-right"
                color: root.focusRowItem === installRow ? Theme.cream : Theme.iconDim
                stroke: 1.8
                rotation: root.installOpen ? 90 : 0
                transformOrigin: Item.Center
                Behavior on rotation { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }
            }
        }

        Item {
            width: parent.width
            height: root.installOpen ? installCol.implicitHeight : 0
            visible: height > 0
            clip: true
            Behavior on height { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }

            Column {
                id: installCol
                width: parent.width

                Item {
                    width: parent.width
                    height: 30 * root.s

                    SearchField {
                        id: urlField
                        s: root.s
                        anchors.left: parent.left
                        anchors.leftMargin: 12 * root.s
                        anchors.right: parent.right
                        anchors.rightMargin: 12 * root.s
                        anchors.verticalCenter: parent.verticalCenter
                        placeholder: "https://github.com/user/repo"
                        onAccepted: root.install(urlField.text)
                    }
                }

                SettingsRow {
                    id: doInstallRow
                    surface: root
                    glyph: "＋"
                    name: "Install"
                    sub: root.busy ? "working…" : "fetch, validate and register"
                    enabled: urlField.text.trim().length > 0 && !root.busy

                    GlyphIcon {
                        width: 16 * root.s
                        height: 16 * root.s
                        name: "chevron-right"
                        color: root.focusRowItem === doInstallRow ? Theme.cream : Theme.iconDim
                        stroke: 1.9
                    }
                }
            }
        }

        Item {
            width: parent.width
            height: root.advancedOpen ? automationCol.implicitHeight : 0
            visible: height > 0
            clip: true
            Behavior on height { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }

            Column {
                id: automationCol
                width: parent.width

                SettingsRow {
                    id: autoCheckRow
                    surface: root
                    icon: "download"
                    name: "Auto update check"
                    sub: "Read-only every 4 hours · never merges"

                    LinkToggle {
                        s: root.s
                        on: Plugins.autoCheckEnabled
                        onToggled: Plugins.autoCheckEnabled = !Plugins.autoCheckEnabled
                    }
                }

                SettingsRow {
                    id: autoUpdateRow
                    surface: root
                    icon: "refresh"
                    name: "Auto install updates"
                    sub: "Validated · rolled back on failure · shell restart stays a click"
                    opacity: Plugins.autoCheckEnabled ? 1 : 0.55

                    LinkToggle {
                        s: root.s
                        on: Flags.pluginAutoUpdate
                        enabled: Plugins.autoCheckEnabled
                        onToggled: Flags.pluginAutoUpdate = !Flags.pluginAutoUpdate
                    }
                }

                SettingsRow {
                    id: autoAdoptRow
                    surface: root
                    icon: "layers"
                    name: "Auto adopt plugins"
                    sub: "A newly seen third-party plugin is enabled and hosted like a native entry"

                    LinkToggle {
                        s: root.s
                        on: Flags.pluginAutoIntegrate
                        onToggled: Flags.pluginAutoIntegrate = !Flags.pluginAutoIntegrate
                    }
                }

                SettingsRow {
                    id: selfHealRow
                    surface: root
                    icon: "undo"
                    name: "Self-heal plugins"
                    sub: "Retry broken or missing plugins on a clock"

                    LinkToggle {
                        s: root.s
                        on: Flags.pluginSelfHeal
                        onToggled: Flags.pluginSelfHeal = !Flags.pluginSelfHeal
                    }
                }

                SettingsRow {
                    id: repairRow
                    surface: root
                    icon: "refresh"
                    name: "Repair now"
                    sub: Plugins.healingNeeded
                        ? "Re-reading the manifest and retrying every failed plugin"
                        : "Nothing to repair"

                    GlyphIcon {
                        width: 15 * root.s
                        height: 15 * root.s
                        name: "chevron-right"
                        color: root.focusRowItem === repairRow ? Theme.cream : Theme.iconDim
                        stroke: 1.8
                    }
                }

                /**
                 * Only appears when an update actually changed plugin code. The shell
                 * running right now has not loaded it, which is exactly what an
                 * unfixed update looks like from the outside — so this is the difference
                 * between the update having worked and looking like it had not.
                 */
                SettingsRow {
                    id: restartRow
                    surface: root
                    visible: Plugins.needsShellRestart
                    icon: "refresh"
                    name: "Restart the shell"
                    sub: "Plugin code was updated — restart to load it"
                }
            }
        }

        // ---- inventory ------------------------------------------------------

        SettingsRow {
            id: countRow
            surface: root
            glyph: "◧"
            name: "Installed"
            sub: Plugins.loaded
                ? (root.query.trim() === ""
                    ? Plugins.plugins.length + " registered · " + Plugins.barWidgets.length + " in the bar"
                    : root.filtered.length + " of " + Plugins.plugins.length + " match")
                : "reading the host…"

            GlyphIcon {
                width: 14 * root.s
                height: 14 * root.s
                name: "refresh"
                color: rescan2Area.containsMouse ? Theme.cream : Theme.iconDim
                stroke: 1.8

                MouseArea {
                    id: rescan2Area
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    enabled: !root.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Plugins.rescan()
                }
            }
        }

        // ---- filters ----------------------------------------------------
        Row {
            width: parent.width
            height: 28 * root.s
            spacing: 8 * root.s
            anchors.left: undefined
            padding: 12 * root.s

            Repeater {
                model: ["All", "Omarchy", "Third-party"]
                delegate: Rectangle {
                    required property var modelData
                    readonly property string key: modelData === "Omarchy" ? "first-party"
                                            : (modelData === "Third-party" ? "third-party" : "all")
                    height: 22 * root.s
                    width: 86 * root.s
                    radius: 11 * root.s
                    color: root.filterMode === key ? Theme.surfaceHighlight : "transparent"
                    border.width: 1 * root.s
                    border.color: root.filterMode === key ? Theme.accent : Theme.borderLight

                    Text {
                        anchors.centerIn: parent
                        text: modelData
                        color: root.filterMode === key ? Theme.text : Theme.iconDim
                        font.family: Theme.font
                        font.pixelSize: 10 * root.s
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.filterMode = key
                    }
                }
            }
        }

        // ---- search ---------------------------------------------------------

        Item {
            width: parent.width
            height: 30 * root.s

            SearchField {
                id: pluginSearch
                s: root.s
                anchors.left: parent.left
                anchors.leftMargin: 12 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 12 * root.s
                anchors.verticalCenter: parent.verticalCenter
                placeholder: "Search plugins…"
                // Escape clears the filter first, the way a search
                // bar should, before any wider dismiss is considered.
                onDismissed: if (text.length > 0)
                    text = "";
            }
        }

        Flickable {
            id: scroll
            width: parent.width
            height: Math.min(pluginCol.implicitHeight, root.listCap)
            contentHeight: pluginCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: pluginCol
                width: parent.width

                Repeater {
                    model: root.filtered

                    delegate: SettingsRow {
                        id: prow
                        required property var modelData
                        required property int index

                        // The entry handed to the shared nav list, kept so the
                        // same object can be withdrawn when this delegate dies.
                        property var navEntry: null
                        /**
                         * The surface this plugin could take over, resolved
                         * once per row. It is "" for a plugin that claims no
                         * capability, and `ownCapabilities[""]` is undefined —
                         * so the swap control's `visible` has to compare
                         * against 1 rather than coerce the lookup straight to
                         * a bool, which is what logged "Unable to assign
                         * [undefined] to bool" once per plugin per open.
                         */
                        readonly property string rowCapability: Plugins.capabilityFor(modelData.id)

                        surface: root
                        icon: prow.modelData.kinds.indexOf("bar-widget") !== -1 ? "layers"
                            : (prow.modelData.kinds.indexOf("panel") !== -1 ? "app-window" : "inbox")
                        name: prow.modelData.name || prow.modelData.id
                        sub: root.describe(prow.modelData)
                        // A plugin Better Bar supersedes can still legitimately be
                        // enabled -- the host owns it -- it just can never reach the
                        // strip. Dimming the row says "not here" without taking the
                        // toggle away, so a click that changes nothing visible is at
                        // least no longer advertised as though it would do something.
                        opacity: root.modeFor(prow.modelData) === "replaced" ? 0.45 : 1
                        last: prow.index === root.filtered.length - 1

                        Component.onCompleted: {
                            prow.navEntry = {
                                item: prow,
                                kind: "toggle",
                                get: function () { return prow.modelData.enabled === true; },
                                set: function (v) { Plugins.setEnabled(prow.modelData.id, !!v); }
                            };
                            root.registerRow(prow.navEntry);
                        }
                        Component.onDestruction: root.unregisterRow(prow.navEntry)

                        // The default `control` slot hosts the per-plugin actions
                        // on the row's right edge.
                        Row {
                            spacing: 9 * root.s
                            anchors.verticalCenter: parent.verticalCenter

                            GlyphIcon {
                                width: 13 * root.s
                                height: 13 * root.s
                                name: "refresh"
                                color: updArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8
                                visible: prow.modelData.firstParty !== true

                                MouseArea {
                                    id: updArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    enabled: !root.busy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Plugins.update(prow.modelData.id)
                                }
                            }

                            GlyphIcon {
                                width: 13 * root.s
                                height: 13 * root.s
                                name: "layers"
                                color: cloneArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8
                                visible: prow.modelData.firstParty === true

                                MouseArea {
                                    id: cloneArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    enabled: !root.busy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Plugins.clone(prow.modelData.id)
                                }
                            }

                            // Hand the plugin's capability to it (or back
                            // to Better Bar's own surface). Only offered for
                            // a bar-widget the bar supersedes: that is the
                            // one case where the choice is the user's to
                            // make, and it is what makes "install a plugin
                            // for a job the bar already does" work -- the
                            // plugin becomes the default, and the bar's own
                            // surface steps aside until it is uninstalled or
                            // the choice is reversed here.
                            GlyphIcon {
                                    width: 13 * root.s
                                    height: 13 * root.s
                                    name: Plugins.providerChosen(prow.modelData) ? "return" : "check"
                                    color: swapArea.containsMouse ? Theme.cream : Theme.iconDim
                                    stroke: 1.8
                                    visible: prow.rowCapability.length > 0
                                        && Plugins.ownCapabilities[prow.rowCapability] === 1

                                MouseArea {
                                    id: swapArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    enabled: !root.busy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var cap = Plugins.capabilityFor(prow.modelData.id);
                                        if (!cap)
                                            return;
                                        var chosen = Plugins.providerChosen(prow.modelData);
                                        Plugins.setProvider(cap, chosen ? "" : prow.modelData.id);
                                        // A provider that is not enabled has
                                        // no strip entry to show, so handing
                                        // the capability over carries the
                                        // enablement with it.
                                        if (!chosen && prow.modelData.enabled !== true)
                                            Plugins.setEnabled(prow.modelData.id, true);
                                        Plugins.refresh();
                                    }
                                }
                            }

                            // Open this plugin's own window/panel from settings.
                            // This is the route that makes a panel-only plugin
                            // (the keybindings manager, for example) reachable
                            // without its own strip entry.
                            GlyphIcon {
                                width: 13 * root.s
                                height: 13 * root.s
                                name: "app-window"
                                color: openArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8

                                MouseArea {
                                    id: openArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    enabled: !root.busy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Plugins.openOrEnable(prow.modelData.id)
                                }
                            }

                            GlyphIcon {
                                width: 13 * root.s
                                height: 13 * root.s
                                name: "trash"
                                color: rmArea.containsMouse ? Theme.vermLit : Theme.iconDim
                                stroke: 1.8
                                visible: prow.modelData.firstParty !== true

                                MouseArea {
                                    id: rmArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    enabled: !root.busy
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Plugins.remove(prow.modelData.id)
                                }
                            }

                            LinkToggle {
                                s: root.s
                                anchors.verticalCenter: parent.verticalCenter
                                on: prow.modelData.enabled === true
                                enabled: prow.modelData.canDisable !== false && !root.busy
                                onToggled: Plugins.setEnabled(prow.modelData.id,
                                    prow.modelData.enabled !== true)
                            }
                        }
                    }
                }
            }
        }

        // ---- status ---------------------------------------------------------

        SettingsRow {
            id: statusRow
            surface: root
            visible: root.showStatus
            glyph: "◌"
            name: root.busy ? "Working"
                : (Plugins.healingNeeded ? "Self-healing plugins" : "Status")
            sub: Plugins.healingNeeded
                ? "Retrying broken/removed plugins until they load"
                : (Plugins.lastError ? (Plugins.lastError + (Plugins.lastOutput.length ? ": " + Plugins.lastOutput : ""))
                    : (Plugins.lastOutput.length ? Plugins.lastOutput
                        : (root.busy ? Plugins.busyWith + "…" : "the host shell owns plugin state")))
            last: true

            GlyphIcon {
                width: 15 * root.s
                height: 15 * root.s
                name: "refresh"
                color: rescanArea.containsMouse ? Theme.cream : Theme.iconDim
                stroke: 1.8

                MouseArea {
                    id: rescanArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    hoverEnabled: true
                    enabled: !root.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Plugins.rescan()
                }
            }
        }
    }
}