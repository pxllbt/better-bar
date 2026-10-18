pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import "../Singletons"
import "../components"
import "../lib/settings-search.js" as SettingsSearch

/**
 * 相 SETTINGS index: the door into the settings, split into
 * category tiles — THEME, APPEARANCE, FONT, DISPLAY, SCREENS,
 * DOCK, INTERFACE, PLUGINS and UPDATE. Picking a tile morphs
 * the pill into that category's surface; the back chevron on
 * each returns here, and an empty click or the cog closes.
 *
 * The search field at the top is the settings search: it is a
 * live filter over the whole settings catalog, not a door into
 * a second search page. Typing replaces this index with the
 * matching settings themselves, so the result rows open the
 * surface or command that owns them. Clearing the field puts
 * the category index back.
 */
SettingsSurface {
    id: root

    backSurface: ""
    implicitHeight: content.implicitHeight

    readonly property bool searching: query.text.trim().length > 0
    readonly property var results: SettingsSearch.search(query.text)

    /** Live result rows, registered and unregistered by the Repeater below. */
    property var resultRows: []

    /**
     * The index, grouped by what it is for rather than by where the code lives.
     * INTERFACE used to sit here as its own tile for eight rows that are all
     * "how does this bar behave" — those are on the DISPLAY page now, so this is
     * one hop shorter and no row is orphaned on a page of its own.
     */
    readonly property var categoryRows: [
        { item: themeTile, kind: "nav", surface: "theme" },
        { item: appearTile, kind: "nav", surface: "appcat" },
        { item: fontTile, kind: "nav", surface: "fontpicker" },
        { item: dispTile, kind: "nav", surface: "display" },
        { item: screensTile, kind: "nav", surface: "screens" },
        { item: dockTile, kind: "nav", surface: "dock" },
        { item: keyboardTile, kind: "nav", surface: "keybinds" },
        { item: pluginsTile, kind: "nav", surface: "plugins" },
        { item: updateTile, kind: "nav", surface: "update" }
    ]

    rows: root.searching ? root.resultRows : root.categoryRows

    function registerRow(item) {
        if (root.resultRows.indexOf(item) === -1) {
            root.resultRows = root.resultRows.concat([item]);
        }
    }

    function unregisterRow(item) {
        var next = root.resultRows.slice();
        var at = next.indexOf(item);
        if (at !== -1) {
            next.splice(at, 1);
            root.resultRows = next;
        }
    }

    function openEntry(entry) {
        if (!entry)
            return;
        if (entry.plugin && entry.plugin.length > 0) {
            Plugins.openOrEnable(entry.plugin);
            root.requestClose();
            return;
        }
        if (entry.to && entry.to.length > 0) {
            root.requestSurface(entry.to);
            return;
        }
        if (entry.argv && entry.argv.length > 0) {
            var argv = entry.argv.slice();
            for (var i = 0; i < argv.length; i++) {
                if (typeof argv[i] === "string")
                    argv[i] = argv[i].replace(/\$HOME/g, Quickshell.env("HOME") || "");
            }
            Quickshell.execDetached(argv);
            root.requestClose();
        }
    }

    function open(item) {
        if (!item || !item.modelData || !item.modelData.entry)
            return;
        root.openEntry(item.modelData.entry);
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "SETTINGS"
            showBack: false
        }

        Item { width: 1; height: 8 * root.s }

        Rectangle {
            id: searchShell
            width: parent.width
            height: 36 * root.s
            radius: 10 * root.s
            color: query.input.activeFocus ? Qt.alpha(Theme.cream, 0.07) : Theme.frameBg
            border.width: 1
            border.color: query.input.activeFocus ? Theme.accent : Theme.hairSoft

            Behavior on color { ColorAnimation { duration: Motion.fast } }
            Behavior on border.color { ColorAnimation { duration: Motion.fast } }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 12 * root.s
                anchors.rightMargin: 10 * root.s
                spacing: 8 * root.s

                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14 * root.s
                    height: 14 * root.s
                    name: "search"
                    color: query.input.activeFocus ? Theme.accent : Theme.iconDim
                    stroke: 2.0
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                }

                SearchField {
                    id: query
                    width: parent.width - 22 * root.s - (clearBtn.visible ? clearBtn.width + 6 * root.s : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    s: root.s
                    active: root.open
                    placeholder: "Search settings…"
                    onDismissed: {
                        if (text.length > 0)
                            text = "";
                        else
                            root.requestClose();
                    }
                    onMoved: (delta) => root.kbMove(delta)
                    onAccepted: if (root.results.length > 0) root.openEntry(root.results[0].entry)
                }

                Item {
                    id: clearBtn
                    visible: root.searching
                    width: 18 * root.s
                    height: 18 * root.s
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: clearHover.hovered ? Qt.alpha(Theme.cream, 0.15) : Qt.alpha(Theme.cream, 0.08)
                        Behavior on color { ColorAnimation { duration: Motion.fast } }

                        GlyphIcon {
                            anchors.centerIn: parent
                            width: 10 * root.s
                            height: 10 * root.s
                            name: "close"
                            color: clearHover.hovered ? Theme.bright : Theme.subtle
                            stroke: 2.2
                        }
                    }

                    HoverHandler {
                        id: clearHover
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: query.text = ""
                    }
                }
            }
        }

        Item { width: 1; height: 8 * root.s }

        Column {
            id: searchResultsWrapper
            visible: root.searching
            width: parent.width
            spacing: 5 * root.s

            Text {
                x: 6 * root.s
                text: root.results.length === 0
                    ? "NO MATCHING SETTINGS"
                    : "RESULTS (" + root.results.length + ")"
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 9.5 * root.s
                font.weight: Font.DemiBold
                font.letterSpacing: 1.2
            }

            Rectangle {
                width: parent.width
                height: Math.min(resultsCol.implicitHeight, 280 * root.s)
                radius: 12 * root.s
                color: Theme.frameBg
                border.width: 1
                border.color: Theme.hairSoft
                clip: true

                Flickable {
                    id: resultsScroll
                    anchors.fill: parent
                    contentHeight: resultsCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: resultsCol
                        width: parent.width

                        Repeater {
                            model: root.results

                            delegate: SettingsRow {
                                id: resultRow
                                required property var modelData
                                required property int index

                                property var navEntry: null

                                surface: root
                                icon: resultRow.modelData && resultRow.modelData.entry && resultRow.modelData.entry.argv
                                    ? "layers" : (resultRow.modelData && resultRow.modelData.entry && resultRow.modelData.entry.plugin
                                        ? "keyboard" : "chevron-right")
                                name: resultRow.modelData ? resultRow.modelData.entry.title : ""
                                sub: resultRow.modelData
                                    ? (resultRow.modelData.entry.sub + " · " + resultRow.modelData.entry.cat)
                                    : ""
                                last: resultRow.index === root.results.length - 1

                                Component.onCompleted: {
                                    resultRow.navEntry = {
                                        item: resultRow,
                                        kind: "toggle",
                                        get: function () { return false; },
                                        activate: function () { root.open(resultRow); }
                                    };
                                    root.registerRow(resultRow.navEntry);
                                }
                                Component.onDestruction: root.unregisterRow(resultRow.navEntry)

                                GlyphIcon {
                                    width: 14 * root.s
                                    height: 14 * root.s
                                    name: "chevron-right"
                                    color: root.focusRowItem === resultRow ? Theme.bright : Theme.iconDim
                                    stroke: 1.8
                                }
                            }
                        }
                    }
                }
            }
        }

        Column {
            id: categoriesCol
            visible: !root.searching
            width: parent.width
            spacing: 11 * root.s

            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "VISUALS & THEME"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: visualsCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: visualsCol
                        width: parent.width

                        // --- Visuals & Theme ---
                        SettingsRow {
                            id: themeTile
                            surface: root
                            name: "Theme"
                            sub: "Theme gallery · 27 themes"
                            badgeIcon: "palette"
                            badgeBg: Qt.rgba(0.65, 0.45, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.65, 0.45, 0.98, 0.28)
                            badgeFg: "#c084fc"

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === themeTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: appearTile
                            surface: root
                            name: "Appearance"
                            sub: "Accent harmony · glass · font colour"
                            badgeIcon: "sparkles"
                            badgeBg: Qt.alpha(Theme.accent, 0.16)
                            badgeBorder: Qt.alpha(Theme.accent, 0.28)
                            badgeFg: Theme.accent

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === appearTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: fontTile
                            surface: root
                            name: "Font"
                            sub: "UI family and typography fallback"
                            badgeText: "Aa"
                            badgeBg: Qt.rgba(0.96, 0.62, 0.15, 0.16)
                            badgeBorder: Qt.rgba(0.96, 0.62, 0.15, 0.28)
                            badgeFg: "#fbbf24"
                            last: true

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === fontTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "BAR & DOCK LAYOUT"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: layoutCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: layoutCol
                        width: parent.width

                        // --- Bar & Dock Layout ---
                        SettingsRow {
                            id: dispTile
                            surface: root
                            name: "Display & Bar"
                            sub: "Pill layout · visualizer · scale · auto-hide"
                            badgeIcon: "app-window"
                            badgeBg: Qt.rgba(0.24, 0.55, 0.98, 0.16)
                            badgeBorder: Qt.rgba(0.24, 0.55, 0.98, 0.28)
                            badgeFg: "#60a5fa"

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === dispTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: screensTile
                            surface: root
                            name: "Screens"
                            sub: "Arrangement · scale · rotation · mirror"
                            badgeIcon: "monitor"
                            badgeBg: Qt.rgba(0.12, 0.74, 0.85, 0.16)
                            badgeBorder: Qt.rgba(0.12, 0.74, 0.85, 0.28)
                            badgeFg: "#38bdf8"

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === screensTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: dockTile
                            surface: root
                            name: "Dock Settings"
                            sub: "Auto-hide · theme · glass · pins"
                            badgeIcon: "dock"
                            badgeBg: Qt.rgba(0.16, 0.78, 0.65, 0.16)
                            badgeBorder: Qt.rgba(0.16, 0.78, 0.65, 0.28)
                            badgeFg: "#2dd4bf"
                            last: true

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === dockTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: 5 * root.s

                Text {
                    x: 6 * root.s
                    text: "SYSTEM & EXTENSIONS"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.2
                }

                Rectangle {
                    width: parent.width
                    height: systemCol.implicitHeight
                    radius: 12 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft
                    clip: true

                    Column {
                        id: systemCol
                        width: parent.width

                        // --- Keyboard ---
                        SettingsRow {
                            id: keyboardTile
                            surface: root
                            name: "Keyboard"
                            sub: "Hyprland keybindings · conflicts · editor"
                            badgeIcon: "keyboard"
                            badgeBg: Qt.rgba(0.22, 0.78, 0.42, 0.16)
                            badgeBorder: Qt.rgba(0.22, 0.78, 0.42, 0.28)
                            badgeFg: "#4ade80"

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === keyboardTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        // --- System & Extensions ---
                        SettingsRow {
                            id: pluginsTile
                            surface: root
                            name: "Plugins"
                            sub: "Install · enable · strip icons"
                            badgeIcon: "layers"
                            badgeBg: Qt.rgba(0.92, 0.35, 0.65, 0.16)
                            badgeBorder: Qt.rgba(0.92, 0.35, 0.65, 0.28)
                            badgeFg: "#f472b6"

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === pluginsTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }

                        SettingsRow {
                            id: updateTile
                            surface: root
                            name: "Update"
                            sub: Updater.checked && Updater.pending > 0
                                ? Updater.pending + (Updater.pending === 1 ? " commit behind · view in UPDATE" : " commits behind · view in UPDATE")
                                : "Pull latest · re-applies the patch"
                            badgeIcon: "refresh"
                            badgeBg: Qt.rgba(0.45, 0.65, 0.95, 0.16)
                            badgeBorder: Qt.rgba(0.45, 0.65, 0.95, 0.28)
                            badgeFg: "#818cf8"
                            badgeGlow: Updater.checked && Updater.pending !== 0
                            last: true

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "chevron-right"
                                color: root.focusRowItem === updateTile ? Theme.bright : Theme.iconDim
                                stroke: 1.8
                            }
                        }
                    }
                }
            }
        }
    }
}
