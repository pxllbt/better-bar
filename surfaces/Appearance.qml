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

    readonly property var categoryRows: [
        { item: themeTile, kind: "nav", surface: "theme" },
        { item: appearTile, kind: "nav", surface: "appcat" },
        { item: fontTile, kind: "nav", surface: "fontpicker" },
        { item: dispTile, kind: "nav", surface: "display" },
        { item: screensTile, kind: "nav", surface: "screens" },
        { item: dockTile, kind: "nav", surface: "dock" },
        { item: keyboardTile, kind: "nav", surface: "keybinds" },
        { item: ifaceTile, kind: "nav", surface: "interface" },
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
            height: searchWrap.height + 14 * root.s
            color: Theme.frameBg
            radius: 9 * root.s
            border.width: 1
            border.color: Theme.hairSoft

            Column {
                id: searchWrap
                x: 12 * root.s
                y: 7 * root.s
                width: parent.width - 24 * root.s
                spacing: 3 * root.s

                SearchField {
                    id: query
                    width: parent.width
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

                Text {
                    width: parent.width
                    text: root.searching
                        ? (root.results.length === 0
                            ? "No matching setting"
                            : root.results.length + (root.results.length === 1 ? " setting" : " settings"))
                        : "FIND A SETTING"
                    color: Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 9 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1
                    elide: Text.ElideRight
                }
            }
        }

        Item { width: 1; height: 6 * root.s }

        Flickable {
            id: resultsScroll
            visible: root.searching
            width: parent.width
            height: visible ? Math.min(resultsCol.implicitHeight, 260 * root.s) : 0
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
                    }
                }
            }
        }

        Column {
            id: categoriesCol
            visible: !root.searching
            width: parent.width

            // --- Visuals & Theme ---
            SettingsRow {
                id: themeTile
                surface: root
                glyph: "🎨"
                name: "Theme"
                sub: "Theme gallery · 27 themes"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === themeTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            SettingsRow {
                id: appearTile
                surface: root
                glyph: "✦"
                name: "Appearance"
                sub: "Accent harmony · glass · font colour"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === appearTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            SettingsRow {
                id: fontTile
                surface: root
                glyph: "Aa"
                name: "Font"
                sub: "UI family and typography fallback"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === fontTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            // --- Bar & Dock Layout ---
            SettingsRow {
                id: dispTile
                surface: root
                glyph: "◫"
                name: "Display & Pill"
                sub: "Pill layout · time format · glyphs"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === dispTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            SettingsRow {
                id: screensTile
                surface: root
                name: "Screens"
                sub: "Arrangement · scale · rotation · mirror"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === screensTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            SettingsRow {
                id: dockTile
                surface: root
                glyph: "⎍"
                name: "Dock Settings"
                sub: "Auto-hide · theme · glass · pins"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === dockTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            // --- Keyboard ---
            SettingsRow {
                id: keyboardTile
                surface: root
                glyph: "keyboard"
                name: "Keyboard"
                sub: "Hyprland keybindings · conflicts · editor"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === keyboardTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            // --- System & Extensions ---
            SettingsRow {
                id: ifaceTile
                surface: root
                glyph: "⚙"
                name: "Interface"
                sub: "Scale · motion · auto-hide"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === ifaceTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            SettingsRow {
                id: pluginsTile
                surface: root
                glyph: "⬡"
                name: "Plugins"
                sub: "Install · enable · strip icons"

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === pluginsTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }

            SettingsRow {
                id: updateTile
                surface: root
                glyph: "↻"
                name: "Update"
                sub: Updater.checked && Updater.pending > 0
                    ? Updater.pending + (Updater.pending === 1 ? " commit behind · view in UPDATE" : " commits behind · view in UPDATE")
                    : "Pull latest · re-applies the patch"
                last: true

                GlyphIcon {
                    width: 16 * root.s
                    height: 16 * root.s
                    name: "chevron-right"
                    color: root.focusRowItem === updateTile ? Theme.cream : Theme.iconDim
                    stroke: 1.9
                }
            }
        }


    }
}
