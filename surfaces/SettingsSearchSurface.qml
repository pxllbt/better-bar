pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"
import "../lib/settings-search.js" as SettingsSearch

/**
 * SETTINGS SEARCH: the door to every visible setting without remembering
 * which surface owns it.
 *
 * Better Bar's settings are split into categories so each page stays small.
 * This surface is the lookup index over those categories: it shows every
 * known setting, narrows as you type, and opens the owning surface or external
 * setting command when a row is picked.
 *
 * The destination map lives in lib/settings-search.js so no existing setting
 * surface has to duplicate itself here. Search results are destinations only:
 * the target surface owns the control, so there is one implementation of each
 * setting, not two.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    /** Bounded result height; the catalog is small but a full listing scrolls. */
    readonly property real listCap: 250 * root.s

    readonly property var results: SettingsSearch.search(queryText.text)

    property var resultRows: []

    function registerRow(item) {
        if (root.resultRows.indexOf(item) === -1) {
            root.resultRows = root.resultRows.concat([item]);
            root.syncRows();
        }
    }

    function unregisterRow(item) {
        var next = root.resultRows.slice();
        var at = next.indexOf(item);
        if (at !== -1) {
            next.splice(at, 1);
            root.resultRows = next;
            root.syncRows();
        }
    }

    function syncRows() {
        var rows = [];
        if (root.queryText.text.trim().length > 0 && root.results.length === 0)
            rows.push({ item: noResultsRow, kind: "toggle", get: function () { return false; }, activate: function () { queryText.text = ""; } });
        else
            rows = rows.concat(root.resultRows);
        root.rows = rows;
    }

    function openEntry(entry) {
        if (!entry)
            return;
        if (entry.plugin && entry.plugin.length > 0) {
            Plugins.openOrEnable(entry.plugin);
            root.requestClose();
            return;
        }
        if (entry.to && entry.to.length > 0 && entry.to !== "search") {
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

    Component.onCompleted: Qt.callLater(root.syncRows)

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "SETTINGS SEARCH"
            showBack: true
        }

        Item { width: 1; height: 12 * root.s }

        Rectangle {
            width: parent.width
            height: searchWrap.height + 8 * root.s

            Column {
                id: searchWrap
                width: parent.width - 24 * root.s
                x: 12 * root.s
                spacing: 4 * root.s

                SearchField {
                    id: queryText
                    width: parent.width
                    s: root.s
                    active: root.open
                    placeholder: "Search settings…"
                    counterText: root.queryText.text.trim().length > 0
                        ? root.results.length + (root.results.length === 1 ? " match" : " matches")
                        : root.results.length + " settings"
                    onDismissed: text = ""
                    onMoved: (delta) => root.kbMove(delta)
                    onAccepted: if (root.results.length > 0) root.openEntry(root.results[0].entry)
                }

                Text {
                    width: parent.width
                    text: root.queryText.text.trim().length === 0
                        ? "Type a setting name, category or keyword"
                        : (root.results.length === 0
                            ? "No matching setting"
                            : root.results.length + (root.results.length === 1 ? " setting" : " settings"))
                    color: Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 10 * root.s
                    elide: Text.ElideRight
                }
            }
        }

        Flickable {
            width: parent.width
            height: Math.min(resultCol.implicitHeight, root.listCap)
            contentHeight: resultCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: resultCol
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
                            ? (resultRow.modelData.entry.sub
                                + (resultRow.modelData.entry.cat ? " · " + resultRow.modelData.entry.cat : ""))
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
                    }
                }

                SettingsRow {
                    id: noResultsRow
                    surface: root
                    visible: root.queryText.text.trim().length > 0 && root.results.length === 0
                    glyph: "⌕"
                    name: "No settings matched"
                    sub: "Clear the field to see the full settings catalog"
                    last: true

                    GlyphIcon {
                        width: 16 * root.s
                        height: 16 * root.s
                        name: "close"
                        color: root.focusRowItem === noResultsRow ? Theme.cream : Theme.iconDim
                        stroke: 1.9
                    }
                }
            }
        }
    }
}