pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import "../Singletons"
import "../components"
import "../lib/keybinds.js" as KeybindsModel

/**
 * KEYBINDS: Better Bar's native Hyprland keybinding manager.
 *
 * The upstream plugin's own window is not used here. The model, search, tabs and
 * actions are Better Bar settings rows driven by the same Hyprland bindings the
 * shell already owns; the upstream Python backend stays only as the safe writer
 * for bindings.lua and conflict detection. That keeps the UI in the pill and
 * keeps the bar from paying for a second plugin window.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    /** Bounded list height; Hyprland can carry 180+ active bindings. */
    readonly property real listCap: 240 * root.s

    readonly property var visibleRows: Keybinds.filteredRows

    /** Keyboard navigation entries for the live rows below. */
    property var rowEntries: []

    /** Editor state. Editing an active row keeps `oldKey` for a rebind. */
    property bool editorOpen: false
    property string editorTitle: "New binding"
    property string editorKey: ""
    property string editorDesc: ""
    property string editorCommand: ""
    property string editorOldKey: ""
    property bool recordingKey: false

    function openEditor(key, description, command, title, oldKey) {
        root.editorKey = String(key || "");
        root.editorDesc = String(description || "");
        root.editorCommand = String(command || "");
        root.editorOldKey = String(oldKey || "");
        root.editorTitle = String(title || "New binding");
        root.editorOpen = true;
    }

    function closeEditor() {
        root.editorOpen = false;
        root.recordingKey = false;
    }

    function registerRow(item) {
        if (root.rowEntries.indexOf(item) === -1)
            root.rowEntries = root.rowEntries.concat([item]);
    }

    function unregisterRow(item) {
        var next = root.rowEntries.slice();
        var at = next.indexOf(item);
        if (at !== -1)
            root.rowEntries = next;
    }

    function saveEditor() {
        if (root.editorKey.length === 0 || root.editorDesc.length === 0
            || root.editorCommand.length === 0) {
            Keybinds.lastError = "Key, description and command are required";
            return;
        }
        Keybinds.setBinding(root.editorKey, root.editorDesc,
            root.editorCommand, root.editorOldKey);
        root.closeEditor();
    }

    function bindCatalog(row) {
        if (!row)
            return;
        root.openEditor(row.key, row.description, row.action,
            "Bind " + row.description, row.current_key);
    }

    function rowSub(row) {
        if (!row)
            return "";
        if (row.kind === "conflict")
            return row.key + " · " + row.bindings.length + " actions";
        if (row.kind === "catalog")
            return (row.bound ? row.current_key + " · bound" : "Unbound") + " · " + row.action;
        return row.key + " · " + row.action;
    }

    function rowStatus(row) {
        if (!row)
            return "";
        if (row.kind === "catalog")
            return row.bound ? "BOUND" : "PRESET";
        if (row.kind === "conflict")
            return "CONFLICT";
        return String(row.status || "").toUpperCase();
    }

    onOpenChanged: {
        Keybinds.surfaceOpen = open;
        if (open) {
            Keybinds.refresh();
            Qt.callLater(function () {
                if (root.open)
                    searchField.forceActiveFocus();
            });
        } else {
            root.closeEditor();
        }
    }

    Component.onCompleted: Keybinds.surfaceOpen = root.open

    SettingsHeader {
        s: root.s
        glyph: "keyboard"
        title: "KEYBINDS"
        showBack: true
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        Rectangle {
            width: parent.width
            height: tabRow.height + 16 * root.s
            color: Theme.frameBg
            radius: 9 * root.s
            border.width: 1
            border.color: Theme.hairSoft

            Row {
                id: tabRow
                x: 12 * root.s
                y: 8 * root.s
                spacing: 8 * root.s

                Repeater {
                    model: [
                        { label: "Active", value: "active" },
                        { label: "Custom", value: "modified" },
                        { label: "Conflicts", value: "conflicts" },
                        { label: "Catalog", value: "catalog" }
                    ]

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool current: Keybinds.tab === modelData.value

                        width: Math.max(64 * root.s, tabLabel.implicitWidth + 14 * root.s)
                        height: 24 * root.s
                        radius: 8 * root.s
                        color: current ? Qt.alpha(Theme.accent, 0.18) : "transparent"
                        border.width: 1
                        border.color: current ? Theme.accent : Theme.hairSoft

                        Text {
                            id: tabLabel
                            anchors.centerIn: parent
                            text: modelData.label
                            color: current ? Theme.cream : Theme.iconDim
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.DemiBold
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Keybinds.tab = modelData.value
                        }
                    }
                }
            }
        }

        Item { width: 1; height: 8 * root.s }

        Rectangle {
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
                    id: searchField
                    width: parent.width
                    s: root.s
                    active: root.open && !root.editorOpen
                    placeholder: "Search keybindings…"
                    counterText: String(root.visibleRows.length)
                    onTextChanged: Keybinds.query = text
                    onDismissed: {
                        if (text.length > 0)
                            text = "";
                        else if (root.editorOpen)
                            root.closeEditor();
                        else
                            root.requestClose();
                    }
                    onMoved: (delta) => root.kbMove(delta)
                }

                Text {
                    width: parent.width
                    text: Keybinds.lastError.length > 0
                        ? Keybinds.lastError
                        : (root.visibleRows.length + (root.visibleRows.length === 1 ? " binding" : " keybindings"))
                    color: Keybinds.lastError.length > 0 ? Theme.vermLit : Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 10 * root.s
                    elide: Text.ElideRight
                }
            }
        }

        Item { width: 1; height: 8 * root.s }

        SettingsRow {
            surface: root
            icon: "type"
            name: "New binding"
            sub: root.editorOpen ? "Close the editor" : "Create a custom Hyprland binding"
            last: false

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: root.editorOpen ? "close" : "type"
                color: root.focusRowItem === keybindEditorToggle ? Theme.cream : Theme.iconDim
                stroke: 1.9

                MouseArea {
                    id: keybindEditorToggle
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.editorOpen ? root.closeEditor() : root.openEditor("", "", "", "New binding", "")
                }
            }
        }

        Rectangle {
            id: editorPanel
            width: parent.width
            height: editorOpen ? editorCol.height + 16 * root.s : 0
            visible: height > 0
            color: Theme.frameBg
            radius: 9 * root.s
            border.width: 1
            border.color: Theme.hairSoft
            clip: true

            Behavior on height {
                NumberAnimation { duration: Motion.fast }
            }

            Column {
                id: editorCol
                x: 12 * root.s
                y: 8 * root.s
                width: parent.width - 24 * root.s
                spacing: 7 * root.s

                Text {
                    text: root.editorTitle
                    color: Theme.cream
                    font.family: Theme.font
                    font.pixelSize: 11 * root.s
                    font.weight: Font.Bold
                }

                TextField {
                    id: descField
                    width: parent.width
                    placeholderText: "Description"
                    color: Theme.cream
                    font.family: Theme.font
                    font.pixelSize: 11 * root.s
                    text: root.editorDesc
                    background: null
                    readOnly: true
                    selectByMouse: false
                    onActiveFocusChanged: cursorVisible = activeFocus
                    onTextChanged: root.editorDesc = text
                    Keys.onPressed: (e) => TextEntry.handle(descField, e)
                }

                TextField {
                    id: commandField
                    width: parent.width
                    placeholderText: "Command"
                    color: Theme.cream
                    font.family: Theme.font
                    font.pixelSize: 11 * root.s
                    text: root.editorCommand
                    background: null
                    readOnly: true
                    selectByMouse: false
                    onActiveFocusChanged: cursorVisible = activeFocus
                    onTextChanged: root.editorCommand = text
                    Keys.onPressed: (e) => TextEntry.handle(commandField, e)
                }

                Row {
                    width: parent.width
                    spacing: 8 * root.s

                    Rectangle {
                        width: parent.width - keyRecordButton.width - 8 * root.s
                        height: 28 * root.s
                        radius: 8 * root.s
                        color: Theme.frameBg
                        border.width: 1
                        border.color: root.recordingKey ? Theme.verm : Theme.hairSoft

                        Text {
                            anchors.centerIn: parent
                            text: root.editorKey.length > 0
                                ? root.editorKey
                                : (root.recordingKey ? "Press a key chord…" : "No key set")
                            color: root.editorKey.length > 0 ? Theme.cream : Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                        }
                    }

                    Rectangle {
                        id: keyRecordButton
                        width: Math.max(76 * root.s, keyRecordLabel.implicitWidth + 16 * root.s)
                        height: 28 * root.s
                        radius: 8 * root.s
                        color: root.recordingKey ? Qt.alpha(Theme.verm, 0.2) : Qt.alpha(Theme.accent, 0.16)
                        border.width: 1
                        border.color: root.recordingKey ? Theme.verm : Theme.accent

                        Text {
                            id: keyRecordLabel
                            anchors.centerIn: parent
                            text: root.recordingKey ? "Cancel" : "Record"
                            color: Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.DemiBold
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.recordingKey = !root.recordingKey
                        }
                    }
                }

                Text {
                    width: parent.width
                    visible: root.editorOldKey.length > 0
                    text: "Rebinding " + root.editorOldKey
                    color: Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 10 * root.s
                    elide: Text.ElideRight
                }

                Row {
                    width: parent.width
                    spacing: 8 * root.s

                    Rectangle {
                        width: (parent.width - 8 * root.s) / 2
                        height: 28 * root.s
                        radius: 8 * root.s
                        color: Qt.alpha(Theme.accent, 0.18)
                        border.width: 1
                        border.color: Theme.accent

                        Text {
                            anchors.centerIn: parent
                            text: Keybinds.busy ? "Saving…" : "Save"
                            color: Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.DemiBold
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.saveEditor()
                        }
                    }

                    Rectangle {
                        width: (parent.width - 8 * root.s) / 2
                        height: 28 * root.s
                        radius: 8 * root.s
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.hairSoft

                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            color: Theme.iconDim
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.DemiBold
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            enabled: !Keybinds.busy
                            onClicked: root.closeEditor()
                        }
                    }
                }
            }
        }

        Item {
            width: parent.width
            height: 8 * root.s
            visible: root.editorOpen
        }

        ListView {
            id: listScroll
            width: parent.width
            height: Math.min(listScroll.contentHeight, root.listCap)
            clip: true
            cacheBuffer: root.listCap
            reuseItems: true
            boundsBehavior: ListView.StopAtBounds
            model: root.visibleRows
            delegate: SettingsRow {
                        id: bindRow
                        required property var modelData
                        required property int index

                        readonly property var row: bindRow.modelData

                        surface: root
                        icon: row.kind === "catalog" ? "layers" : "keyboard"
                        name: row.description
                        sub: root.rowSub(row)
                        last: bindRow.index === root.visibleRows.length - 1

                        Component.onCompleted: root.registerRow(bindRow)
                        Component.onDestruction: root.unregisterRow(bindRow)

                        Row {
                            spacing: 9 * root.s
                            anchors.verticalCenter: parent.verticalCenter

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "type"
                                color: editArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8
                                visible: row.kind === "active"

                                MouseArea {
                                    id: editArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openEditor(row.key, row.description,
                                        row.action, "Edit " + row.description, row.key)
                                }
                            }

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "check"
                                color: bindArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8
                                visible: row.kind === "catalog"

                                MouseArea {
                                    id: bindArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.bindCatalog(row)
                                }
                            }

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "play"
                                color: enableArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8
                                visible: row.kind === "active" && row.status === "disabled"

                                MouseArea {
                                    id: enableArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Keybinds.enable(row.key)
                                }
                            }

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "undo"
                                color: resetArea.containsMouse ? Theme.cream : Theme.iconDim
                                stroke: 1.8
                                visible: row.kind === "active" && KeybindsModel.canReset(row)

                                MouseArea {
                                    id: resetArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Keybinds.reset(row.key, row.default_key)
                                }
                            }

                            GlyphIcon {
                                width: 14 * root.s
                                height: 14 * root.s
                                name: "close"
                                color: disableArea.containsMouse ? Theme.vermLit : Theme.iconDim
                                stroke: 1.8
                                visible: row.kind === "active" && row.status !== "disabled"

                                MouseArea {
                                    id: disableArea
                                    anchors.fill: parent
                                    anchors.margins: -5 * root.s
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Keybinds.disable(row.key)
                                }
                            }
                        }
            }
        }

        SettingsRow {
            id: statusRow
            surface: root
            glyph: "refresh"
            name: Keybinds.busy ? Keybinds.busyAction : "Status"
            sub: {
                if (Keybinds.lastError.length > 0)
                    return Keybinds.lastError;
                if (Keybinds.busy)
                    return Keybinds.busyAction + "…";
                if (Keybinds.totals.total_active === 0)
                    return "Reading Hyprland keybindings…";
                return Keybinds.statusMessage;
            }
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
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Keybinds.refresh()
                }
            }
        }
    }

    /**
     * Keyboard navigation entries for the live rows, plus the status row that is
     * always last. Dynamic only: no delegate is created until a row is visible,
     * so the 180-binding case does not cost a registry entry per row at startup.
     */
    rows: root.rowEntries.concat([{
        item: statusRow,
        kind: "toggle",
        get: function () { return false; },
        activate: function () { Keybinds.refresh(); }
    }])

    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: root.recordingKey
        Keys.onPressed: (e) => {
            if (!root.recordingKey)
                return;
            if (e.key === Qt.Key_Escape) {
                root.recordingKey = false;
                e.accepted = true;
                return;
            }
            var chord = KeybindsModel.keyFromEvent(
                (e.modifiers & Qt.ControlModifier) !== 0,
                (e.modifiers & Qt.AltModifier) !== 0,
                (e.modifiers & Qt.ShiftModifier) !== 0,
                (e.modifiers & Qt.MetaModifier) !== 0,
                e.key,
                e.text
            );
            if (chord.length === 0) {
                e.accepted = true;
                return;
            }
            root.editorKey = chord;
            root.recordingKey = false;
            e.accepted = true;
        }
    }
}
