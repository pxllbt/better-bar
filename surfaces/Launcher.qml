pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../lib/fuzzy.js" as Fuzzy
import "../lib/calc.js" as Calc
import "../components"

/**
 * Launcher surface: the Omarchy command menu, hosted in the pill.
 *
 * Opens on the ten root sections of `omarchy-menu.jsonc` — Apps, Learn, Trigger,
 * Style, Setup, Install, Remove, Update, About, System — and descends into
 * submenus from there. Typing filters the *whole* tree at once rather than the
 * current level, so `firefox` finds the installed app and `Setup > Defaults >
 * Browser > Firefox` from the same keystrokes, ranked so the more exact match
 * wins. That is the stock menu's model (`OmarchyMenu` + `lib/menu.js`); this file
 * is the presentation layer.
 *
 * What it keeps from Better Bar's own launcher, because none of it is in the stock
 * menu:
 *
 *   * calc mode — a real expression in the query puts a result row on top and
 *     Enter copies it (see `lib/calc.js`, which never evals)
 *   * launch-frequency ranking, from the same usage file the dock reads
 *   * AppImage install management: right-click renames, and an armed second
 *     right-click deletes
 *   * right-click pinning to the dock for anything launchable
 *   * drag an AppImage onto the pill
 *
 * `omarchy-menu` is still installed and still bound to its other keys, so there
 * is a fallback launcher that is not this one.
 */
PillSurface {
    id: root

    mTop: 15
    mLeft: 11
    mRight: 11
    mBottom: 14

    /** Submenu currently open. "root" is the ten sections. */
    property string path: "root"
    property string query: ""
    property int selectedIndex: 0

    property var usage: ({})

    /**
     * Rows currently listed. Global while there is a query (searching spans the
     * whole tree), the current submenu's children otherwise. Both go through
     * `OmarchyMenu`, so `when:` guards have already removed rows that should not
     * be here by the time this is bound.
     */
    readonly property var rows: root.query.trim().length > 0 ? root.searchResults : root.childRows

    readonly property var childRows: {
        // A volatile provider (fonts, power profiles) is re-read on entry, so the
        // row set reflects what is installed now rather than at shell start.
        OmarchyMenu.refreshProvider(root.path);
        return OmarchyMenu.childrenOf(root.path);
    }

    readonly property var searchResults: OmarchyMenu.search(root.query, {
        fuzzy: Fuzzy,
        usage: function (id) { return root.uses(id); }
    })

    readonly property bool searching: root.query.trim().length > 0
    readonly property bool busy: !OmarchyMenu.guardsResolved

    /** Grandparent, for the breadcrumb's "back" target. */
    readonly property string parentPath: {
        var entry = OmarchyMenu.item(root.path);
        if (!entry || !entry.parent || entry.parent === "root")
            return "root";
        return entry.parent;
    }

    readonly property string breadcrumb: root.path === "root" ? "" : OmarchyMenu.pathFor(root.path)

    /**
     * Rows this deep are not worth flattening: the tree is three levels at its
     * deepest in the shipped menu, and a wider fan-out would put Install's 60-odd
     * entries in front of a search that only wanted one of them.
     */
    readonly property int searchLimit: 40

    readonly property var visibleRows: root.rows.length > root.searchLimit ? root.rows.slice(0, root.searchLimit) : root.rows

        function uses(id) {
        if (!id)
            return 0;
        var c = root.usage[id];
        return typeof c === "number" ? c : 0;
    }

    function noteUse(entry) {
        if (!entry || entry.kind !== "app" || !entry.appId)
            return;
        var key = entry.appId;
        root.usage[key] = (root.usage[key] || 0) + 1;
        usageStore.setText(JSON.stringify(root.usage));
    }

    // ---- calc ---------------------------------------------------------------

    readonly property var calc: Calc.evaluate(root.query)
    readonly property bool calcActive: root.calc.ok
    property bool calcCopied: false
    /**
     * Query change resets the selection, so every keystroke starts the ranked
     * list at its best match rather than wherever the previous query left it.
     * Both the calc-copy hint and the selection reset belong to this one handler.
     */
    onQueryChanged: {
        root.calcCopied = false;
        root.selectedIndex = 0;
    }

    function copyResult() {
        if (!root.calcActive)
            return;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "_", root.calc.display]);
        root.calcCopied = true;
    }

    // ---- AppImage install management ---------------------------------------

    /** Row index in AppImage edit mode (rename plus armed delete), -1 when none. */
    property int editIndex: -1

    /**
     * Window-coordinate position of the last hover event that was allowed to
     * move the selection. Rows sliding under a stationary cursor during keyboard
     * scrolling produce hover events at an unchanged window position, which must
     * not steal the keyboard selection.
     */
    property point lastPointer: Qt.point(-1, -1)

    readonly property string appimageScript: Config.hyprPath("scripts", "app-install.sh")

    function appimageSlug(appId) {
        return appId && appId.indexOf("pill-") === 0 ? appId.substring(5) : "";
    }

    Process { id: appimageProc }

    // ---- navigation ---------------------------------------------------------

    function move(delta) {
        if (root.visibleRows.length === 0)
            return;
        root.selectedIndex = Math.max(0, Math.min(root.visibleRows.length - 1, root.selectedIndex + delta));
        list.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }

    function descend(entry) {
        if (!entry)
            return;
        var target = entry.kind === "link" ? entry.target : entry.id;
        // An action row inside a submenu is terminal, so it runs and closes; only
        // a row with somewhere to go actually navigates.
        if (entry.kind === "action") {
            OmarchyMenu.runAction(entry.action);
            root.requestClose();
            return;
        }
        root.path = target;
        root.selectedIndex = 0;
        list.positionViewAtBeginning();
        // Loading a provider is the one thing that can add rows to a submenu
        // after the fact, so the list is rebuilt when it lands. `childRows` reads
        // it, so the mutation is enough — no extra invalidation needed.
        OmarchyMenu.ensureProvider(target);
    }

    /**
     * Jump to a menu route on open. Set by the `menu` IPC handler, which the
     * stock `omarchy-menu toggle <route>` keys are bound to instead (Omarchy's
     * menu plugin is disabled on this desktop, so those keys had nothing to
     * open). An empty route, or one that does not resolve, leaves the launcher at
     * its root rather than showing nothing.
     */
    property string route: ""

    function applyRoute() {
        if (root.route.length === 0)
            return;
        var resolved = OmarchyMenu.resolveRoute(root.route);
        root.path = OmarchyMenu.item(resolved) ? resolved : "root";
    }

    function ascend() {
        root.path = root.parentPath;
        root.selectedIndex = 0;
        list.positionViewAtBeginning();
    }

    function activate() {
        if (root.calcActive) {
            root.copyResult();
            return;
        }
        if (root.visibleRows.length === 0 || root.selectedIndex < 0 || root.selectedIndex >= root.visibleRows.length)
            return;
        var entry = root.visibleRows[root.selectedIndex];
        // An app row is terminal: Enter has to launch it and close, the same
        // thing a left click does. Only a row with somewhere to go navigates.
        if (entry && entry.kind === "app") {
            root.launchApp(entry);
            root.requestClose();
            return;
        }
        root.descend(entry);
    }

    /** Launch a desktop entry through the same path the stock menu uses. */
    function launchApp(entry) {
        if (!entry || entry.kind !== "app")
            return;
        root.noteUse(entry);
        var src = DesktopEntries.applications.values;
        for (var i = 0; i < src.length; i++) {
            if (src[i] && src[i].id === entry.appId) {
                src[i].execute();
                break;
            }
        }
    }

        /**
     * A route arriving while the launcher is already open. `applyRoute` alone is
     * not enough on open, because `open` never changes again for a live
     * navigation — without this, a key aimed at a submenu while the launcher is
     * up did nothing at all.
     */
    onRouteChanged: {
        if (!root.open)
            return;
        var hadRoute = root.path !== "root";
        root.applyRoute();
        // Navigating away from root clears the route so the launcher is back to
        // being a plain launcher next time it opens.
        if (hadRoute)
            root.route = "";
        root.selectedIndex = 0;
        list.positionViewAtBeginning();
    }

    onActiveChanged: {
        if (root.active) {
            root.query = "";
            search.text = "";
            root.editIndex = -1;
            // A routed open (a key that used to summon an omarchy-menu submenu)
            // wins over the remembered path.
            root.applyRoute();
            // Otherwise land at the top of the path we were left on. The path is
            // *not* reset to root: someone who closed on Setup > Defaults >
            // Browser expects to come back there, and root is only forced when
            // the tree has since lost the submenu (an edit to the menu file, say).
            if (!OmarchyMenu.item(root.path))
                root.path = "root";
            root.selectedIndex = 0;
            // Guards describe state that changed while the launcher was closed
            // (a package installed, DNS switched), so they are re-read on open.
            OmarchyMenu.runGuards();
            OmarchyMenu.mergeAppRows(root.usage);
            Qt.callLater(root.focusField);
        }
    }

    onPathChanged: {
        root.selectedIndex = 0;
        root.editIndex = -1;
        list.positionViewAtBeginning();
    }

    onVisibleRowsChanged: {
        if (root.selectedIndex >= root.visibleRows.length)
            root.selectedIndex = 0;
        root.editIndex = -1;
    }

    function focusField() { search.input.forceActiveFocus(); }

    /**
     * Row geometry follows the presence of a secondary line, so a submenu with
     * only actions does not carry a description's worth of padding on every row.
     */
    readonly property bool showDetail: root.searching

    readonly property point caretPoint: {
        void root.width;
        void root.height;
        void search.input.width;
        return search.input.mapToItem(root,
            search.input.cursorRectangle.x + search.input.cursorRectangle.width / 2,
            search.input.cursorRectangle.y + search.input.cursorRectangle.height / 2);
    }
    readonly property real caretX: root.caretPoint.x
    readonly property real caretY: root.caretPoint.y

    ameForm: "caret"
    amePoint: Qt.point(root.caretX, root.caretY)

    FileView {
        id: usageStore
        path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better/launcher-usage.json"
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Component.onCompleted: {
        var raw = usageStore.text();
        try {
            root.usage = raw && raw.length ? JSON.parse(raw) : ({});
        } catch (e) {
            root.usage = ({});
        }
    }

    // ---- chrome -------------------------------------------------------------

    SearchField {
        id: search
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        s: root.s
        placeholder: root.searching ? "Search everything" : "Search apps and commands"
        counterText: root.busy ? "…" : (root.searching
            ? root.searchResults.length + " / " + (root.searchResults.length > root.searchLimit ? root.searchLimit + "+" : "")
            : "")
        onTextChanged: root.query = text
        onMoved: (d) => root.move(d)
        onAccepted: root.activate()
        onDismissed: root.requestClose()
        onKeyPressed: (e) => {
            // Right opens the selected row. The stock menu has no right-click, and
            // this is where pin / AppImage rename / delete live.
            if (e.key === Qt.Key_Right || (e.key === Qt.Key_Menu)) {
                if (root.selectedIndex >= 0 && root.selectedIndex < root.visibleRows.length)
                    root.openRowMenu(root.visibleRows[root.selectedIndex]);
                e.accepted = true;
            }
        }
    }

    /**
     * Row context action, shared by right-click and the Right key. Modelled as a
     * plain function rather than a popup because there are only ever two outcomes
     * and no choices: pin/unpin a launchable, or open AppImage edit mode.
     */
    function openRowMenu(entry) {
        if (!entry)
            return;
        if (root.appimageSlug(entry.appId)) {
            root.editIndex = (root.editIndex === root.selectedIndex) ? -1 : root.selectedIndex;
            return;
        }
        if (entry.appId)
            DockPins.toggle(entry.appId);
    }

    /** Breadcrumb: the current path, and where "back" goes. */
    Row {
        id: crumb
        visible: root.breadcrumb.length > 0
        anchors.top: search.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: visible ? 16 * root.s : 0
        spacing: 5 * root.s

        GlyphIcon {
            id: backGlyph
            anchors.verticalCenter: parent.verticalCenter
            width: 11 * root.s
            height: 11 * root.s
            stroke: 1.9
            name: "chevron-left"
            color: Theme.vermLit

        MouseArea {
                anchors.fill: parent
                anchors.margins: -5 * root.s
                cursorShape: Qt.PointingHandCursor
                onClicked: root.ascend()
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - backGlyph.width - 5 * root.s
            text: root.breadcrumb
            color: Theme.dim
            font.family: Theme.font
            font.pixelSize: 10.5 * root.s
            elide: Text.ElideRight
        }
    }

    Rectangle {
        id: divider
        anchors.top: crumb.visible ? crumb.bottom : search.bottom
        anchors.topMargin: 8 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.hair
    }

    Item {
        id: calcRow
        visible: root.calcActive
        anchors.top: divider.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        height: visible ? 44 * root.s : 0

        Rectangle {
            anchors.fill: parent
            radius: 9 * root.s
            color: Theme.frameBg
            border.width: 1
            border.color: Theme.frameBorder
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyResult()
        }

        Item {
            anchors.fill: parent
            anchors.leftMargin: 12 * root.s
            anchors.rightMargin: 12 * root.s

            Column {
                anchors.left: parent.left
                anchors.right: copyHint.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1 * root.s

                Text {
                    width: parent.width
                    text: "= " + root.calc.display
                    color: Theme.bright
                    font.family: Theme.font
                    font.pixelSize: 15 * root.s
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    text: root.query
                    color: Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 10.5 * root.s
                    elide: Text.ElideRight
                }
            }

            Text {
                id: copyHint
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.calcCopied ? "copied" : "↵ copy"
                color: root.calcCopied ? Theme.dim : Theme.vermLit
                font.family: Theme.font
                font.pixelSize: 11 * root.s
            }
        }
    }

    Text {
        anchors.centerIn: list
        visible: !root.busy && root.visibleRows.length === 0
        text: root.busy ? "…" : (root.searching ? "No matches" : "Nothing here")
        color: Theme.faint
        font.family: Theme.font
        font.pixelSize: 10.5 * root.s
    }

    ListView {
        id: list
        anchors.top: root.calcActive ? calcRow.bottom : divider.bottom
        anchors.topMargin: 6 * root.s
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hint.visible ? hint.top : parent.bottom
        anchors.bottomMargin: hint.visible ? 4 * root.s : 0
        spacing: 3 * root.s
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.visibleRows

        delegate: Item {
            id: menuRow
            required property int index
            required property var modelData

            width: list.width
            height: 38 * root.s

            readonly property var entry: menuRow.modelData
            readonly property bool selected: menuRow.index === root.selectedIndex
            readonly property bool isAppImage: root.appimageSlug(menuRow.entry ? menuRow.entry.appId : "") !== ""
            readonly property bool editing: root.editIndex === menuRow.index && menuRow.isAppImage
            readonly property bool isApp: menuRow.entry && menuRow.entry.kind === "app"
            readonly property bool hasChildren: menuRow.entry
                && (menuRow.entry.kind === "menu" || menuRow.entry.kind === "link")
                && OmarchyMenu.childCount(menuRow.entry.kind === "link" ? menuRow.entry.target : menuRow.entry.id) > 0
            readonly property bool dockPinned: menuRow.isApp && DockPins.has(menuRow.entry.appId)
            property bool armed: false
            onEditingChanged: if (!editing) armed = false

            /** The ✓ for a `checked:` row, or the "this is current" mark for a provider row. */
            readonly property bool current: menuRow.entry
                && (menuRow.entry.isCurrent === true
                    || (menuRow.entry.checked && OmarchyMenu.checkedResults[menuRow.entry.id] === true))

            readonly property string secondary: {
                var e = menuRow.entry;
                if (!e)
                    return "";
                if (e.description && e.description.length > 0)
                    return e.description;
                if (root.searching && e.id !== "root")
                    return OmarchyMenu.pathFor(e.id);
                return "";
            }

            Rectangle {
                anchors.fill: parent
                radius: 9 * root.s
                visible: menuRow.selected || rowArea.containsMouse
                color: menuRow.selected ? Theme.frameBg : Qt.rgba(0.94, 0.88, 0.84, 0.03)
                border.width: menuRow.selected ? 1 : 0
                border.color: Theme.frameBorder
            }

            MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: (m) => {
                    // Rows sliding under a stationary cursor during keyboard
                    // scrolling produce hover events at an unchanged window
                    // position, which must not steal the keyboard selection.
                    var g = rowArea.mapToItem(null, m.x, m.y);
                    if (g.x !== root.lastPointer.x || g.y !== root.lastPointer.y) {
                        root.lastPointer = Qt.point(g.x, g.y);
                        root.selectedIndex = menuRow.index;
                    }
                }
                onClicked: (m) => {
                    if (m.button === Qt.RightButton) {
                        root.selectedIndex = menuRow.index;
                        root.openRowMenu(menuRow.entry);
                        return;
                    }
                    if (menuRow.editing)
                        return;
                    root.selectedIndex = menuRow.index;
                    if (menuRow.isApp) {
                        root.launchApp(menuRow.entry);
                        root.requestClose();
                        return;
                    }
                    root.activate();
                }
                onDoubleClicked: (m) => {
                    if (menuRow.isApp) {
                        root.launchApp(menuRow.entry);
                        root.requestClose();
                    }
                }
            }

            Item {
                anchors.fill: parent
                anchors.leftMargin: 11 * root.s
                anchors.rightMargin: 11 * root.s

                Rectangle {
                    id: iconBg
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22 * root.s
                    height: 22 * root.s
                    radius: 5 * root.s
                    color: Qt.rgba(1, 1, 1, 0.05)
                    visible: menuRow.isApp && !(icon.status === Image.Ready && icon.source != "")
                }

                // Menu icons are Nerd Font glyphs from the JSONC, drawn as text in
                // the menu font. `monospace` is the stock default (Style.font.
                // menuFamily) and is what fontconfig resolves the glyphs through;
                // a row may name its own family, which `iconFont` carries.
                Text {
                    id: glyphIcon
                    anchors.fill: iconBg
                    visible: !menuRow.isApp && menuRow.entry && menuRow.entry.icon.length > 0
                    text: menuRow.entry ? menuRow.entry.icon : ""
                    color: menuRow.selected ? Theme.cream : Theme.iconDim
                    font.family: (menuRow.entry && menuRow.entry.iconFont && menuRow.entry.iconFont.length > 0)
                        ? menuRow.entry.iconFont : "monospace"
                    font.pixelSize: 15 * root.s
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                Image {
                    id: icon
                    anchors.fill: iconBg
                    sourceSize.width: Math.round(40 * root.s)
                    sourceSize.height: Math.round(40 * root.s)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                    visible: menuRow.isApp && status === Image.Ready && source != ""
                    source: {
                        if (!menuRow.isApp || !menuRow.entry || !menuRow.entry.appIcon)
                            return "";
                        var ic = menuRow.entry.appIcon;
                        if (menuRow.isAppImage && ic.indexOf("/") === 0)
                            return "file://" + ic;
                        return Quickshell.iconPath(ic, true);
                    }
                }

                TextMetrics {
                    id: retMetrics
                    font.family: Theme.font
                    font.pixelSize: 12 * root.s
                    text: "↵"
                }
                Text {
                    id: ret
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    text: retMetrics.text
                    color: Theme.vermLit
                    font.family: Theme.font
                    font.pixelSize: 12 * root.s
                    visible: menuRow.selected && !menuRow.editing
                    width: visible ? retMetrics.advanceWidth + 6 * root.s : 0
                    horizontalAlignment: Text.AlignRight
                }

                GlyphIcon {
                    id: pinGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: ret.left
                    anchors.rightMargin: 5 * root.s
                    width: menuRow.dockPinned ? 12 * root.s : 0
                    height: 12 * root.s
                    visible: menuRow.dockPinned
                    opacity: 0.6
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                    stroke: 2
                    name: "pin"
                    color: Theme.vermLit
                }

                GlyphIcon {
                    id: trashGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: parent.right
                    width: menuRow.editing ? 16 * root.s : 0
                    height: 16 * root.s
                    visible: menuRow.editing
                    stroke: 2
                    name: "trash"
                    color: menuRow.armed ? Theme.verm : Theme.dim

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6 * root.s
                        enabled: menuRow.editing
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!menuRow.armed) {
                                menuRow.armed = true;
                                return;
                            }
                            var slug = root.appimageSlug(menuRow.entry ? menuRow.entry.appId : "");
                            if (slug) {
                                appimageProc.command = ["bash", root.appimageScript, "remove", slug];
                                appimageProc.running = true;
                            }
                            root.editIndex = -1;
                        }
                    }
                }

                /**
                 * "3 ›" on a submenu, so depth is legible without entering it.
                 * Sits inboard of the current-setting tick, since the two are
                 * mutually exclusive and this one is the wider of the two.
                 */
                Text {
                    id: childCount
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: curTick.left
                    anchors.rightMargin: 7 * root.s
                    visible: menuRow.hasChildren && !menuRow.current
                    text: (menuRow.entry ? OmarchyMenu.childCount(menuRow.entry.kind === "link" ? menuRow.entry.target : menuRow.entry.id) : 0) + " ›"
                    color: menuRow.selected ? Theme.dim : Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 10.5 * root.s
                    font.features: { "tnum": 1 }
                }

                /**
                 * The "this is your current setting" mark, for provider rows
                 * (fonts, power profiles) where the current value arrives as a
                 * column rather than a `checked:` guard. A `checked:` row gets its
                 * ✓ in the label instead, matching the stock menu.
                 */
                Text {
                    id: curTick
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.right: menuRow.editing ? trashGlyph.left : (menuRow.dockPinned ? pinGlyph.left : ret.left)
                    anchors.rightMargin: 8 * root.s
                    width: menuRow.current ? 12 * root.s : 0
                    text: "✓"
                    visible: menuRow.current
                    color: Theme.vermLit
                    font.family: Theme.font
                    font.pixelSize: 11.5 * root.s
                }

                Column {
                    anchors.left: iconBg.right
                    anchors.leftMargin: 10 * root.s
                    anchors.right: menuRow.editing ? trashGlyph.left
                        : (menuRow.dockPinned ? pinGlyph.left : ret.left)
                    anchors.rightMargin: 8 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1 * root.s

                    Item {
                        width: parent.width
                        height: nameText.implicitHeight

                        Text {
                            id: nameText
                            anchors.fill: parent
                            visible: !menuRow.editing
                            text: {
                                if (!menuRow.entry)
                                    return "";
                                // A `checked:` row's ✓ rides in its label, matching
                                // the stock menu; the gutter tick is for provider rows.
                                if (menuRow.entry.checked && OmarchyMenu.checkedResults[menuRow.entry.id] === true)
                                    return menuRow.entry.label + " ✓";
                                return menuRow.entry.label;
                            }
                            color: Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 13 * root.s
                            font.weight: menuRow.selected ? Font.DemiBold : Font.Normal
                            elide: Text.ElideRight
                        }
                        TextInput {
                            id: nameEdit
                            anchors.fill: parent
                            visible: menuRow.editing
                            text: menuRow.entry ? menuRow.entry.label : ""
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 13 * root.s
                            selectByMouse: true
                            clip: true
                            onVisibleChanged: if (visible) {
                                selectAll();
                                forceActiveFocus();
                            }
                            onEditingFinished: {
                                var slug = root.appimageSlug(menuRow.entry ? menuRow.entry.appId : "");
                                var nm = nameEdit.text.trim();
                                if (slug && nm.length > 0 && nm !== menuRow.entry.label) {
                                    appimageProc.command = ["bash", root.appimageScript, "rename", slug, nm];
                                    appimageProc.running = true;
                                }
                                root.editIndex = -1;
                            }
                        }
                    }
                    Text {
                        width: parent.width
                        visible: menuRow.secondary.length > 0
                        text: menuRow.secondary
                        color: menuRow.selected ? Theme.dim : Theme.faint
                        font.family: Theme.font
                        font.pixelSize: 10.5 * root.s
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    WheelScroller {
        anchors.fill: list
        s: root.s
        flick: list
    }

    /** Faint nudge so the drag-to-install gesture is discoverable at all. */
    Row {
        id: hint
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 2 * root.s
        spacing: 5 * root.s
        visible: root.query.length === 0 && root.editIndex === -1 && root.path === "root"
        opacity: 0.6

        GlyphIcon {
            anchors.verticalCenter: parent.verticalCenter
            width: 12 * root.s
            height: 12 * root.s
            stroke: 1.7
            name: "download"
            color: Theme.faint
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Drag an AppImage onto the pill · / to search · → to pin"
            color: Theme.faint
            font.family: Theme.font
            font.pixelSize: 10.5 * root.s
        }
    }
}