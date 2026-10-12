pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"

/**
 * 色 THEME sub-surface: Visual System Theme Gallery for Omarchy themes,
 * plus collapsible manual hue tuning and wallpaper rotation folder.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    property string query: ""
    property var allThemes: []
    property bool customOpen: false
    property string optimisticTheme: ""

    property string hueArg: String(Math.round(Flags.manualHue))
    property string modeArg: Flags.manualDark ? "dark" : "light"
    property string satArg: String(Flags.manualSat)

    readonly property string themeMode: Flags.paletteMode === "static" ? "dark" : Flags.paletteMode
    readonly property color accentColor: Qt.hsla(Flags.manualHue / 360, Flags.manualSat, Flags.manualDark ? 0.5 : 0.62, 1)
    readonly property string currentHex: Theme.hexUpper(accentColor)
    readonly property string activeThemeName: optimisticTheme.length > 0 ? optimisticTheme : ThemeSync.activeThemeName.toLowerCase()

    FileView {
        id: themesCache
        path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/better/themes.json"
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadCachedThemes()
        onFileChanged: root.loadCachedThemes()
    }

    function loadCachedThemes() {
        var raw = themesCache.text();
        if (raw && raw.length > 0) {
            try {
                var parsed = JSON.parse(raw);
                if (parsed && parsed.length > 0)
                    root.allThemes = parsed;
            } catch (e) {}
        }
    }

    readonly property var filteredThemes: {
        if (!allThemes || allThemes.length === 0)
            return [];
        var q = query.trim().toLowerCase();
        if (q.length === 0)
            return allThemes;
        var out = [];
        for (var i = 0; i < allThemes.length; i++) {
            var t = allThemes[i];
            if (t.name.toLowerCase().indexOf(q) >= 0 || t.id.toLowerCase().indexOf(q) >= 0)
                out.push(t);
        }
        return out;
    }

    function applyManual() {
        hueArg = String(Math.round(Flags.manualHue));
        modeArg = Flags.manualDark ? "dark" : "light";
        satArg = String(Flags.manualSat);
        applyTimer.restart();
    }

    function applyMode(v) {
        Flags.paletteMode = v;
        if (v === "manual")
            applyManual();
        else if (v === "dynamic")
            paletteRegen.running = true;
    }

    function switchTheme(themeId) {
        if (!themeId || themeId.length === 0)
            return;
        optimisticTheme = themeId.toLowerCase();
        Flags.accentOverride = "";
        Flags.textOverride = "";
        if (Flags.paletteMode === "manual")
            Flags.paletteMode = "dark";
        Quickshell.execDetached(["omarchy-theme-set", themeId]);
        fastSyncTimer.restart();
    }

    Timer {
        id: fastSyncTimer
        interval: 80
        onTriggered: {
            ThemeSync.probe();
            Color.reloadTheme();
        }
    }

    Process {
        id: themeScanner
        command: ["python3", Config.hyprPath("scripts", "themes.py")]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var parsed = JSON.parse(text);
                    if (parsed && parsed.length > 0) {
                        root.allThemes = parsed;
                        Quickshell.execDetached(["sh", "-c", "mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$1\" > \"$2\"", "_", text, themesCache.path]);
                    }
                } catch (e) {
                }
            }
        }
    }

    Component.onCompleted: {
        root.loadCachedThemes();
        themeScanner.running = true;
    }

    onActiveChanged: {
        if (active) {
            root.loadCachedThemes();
            themeScanner.running = true;
        } else {
            query = "";
            searchField.text = "";
            optimisticTheme = "";
        }
    }

    Timer {
        id: applyTimer
        interval: 260
        repeat: false
        onTriggered: paletteProc.running = true
    }

    Process {
        id: paletteProc
        command: ["sh", "-c",
            "wallscript=\"" + Config.hyprPath("scripts", "wallcolors.py") + "\"; python3 \"$wallscript\" --hue \"$1\" \"$2\" \"$3\" && hyprctl reload >/dev/null 2>&1; busctl --user call com.mitchellh.ghostty /com/mitchellh/ghostty org.gtk.Actions Activate \"sava{sv}\" reload-config 0 0 >/dev/null 2>&1; command -v kitty >/dev/null 2>&1 && timeout -k 1 5 kitty @ set-colors \"${XDG_CACHE_HOME:-$HOME/.cache}/better/kitty-colors\" >/dev/null 2>&1 || true",
            "sh", root.hueArg, root.modeArg, root.satArg]
    }

    Process {
        id: paletteRegen
        command: ["bash", Config.hyprPath("scripts", "wallpaper.sh"), "regen"]
    }

    Connections {
        target: Flags
        function onManualHueChanged() {
            if (Flags.paletteMode === "manual")
                root.applyManual();
        }
        function onManualSatChanged() {
            if (Flags.paletteMode === "manual")
                root.applyManual();
        }
    }

    rows: [
        { item: wpDirRow, kind: "text", activate: function () {
            wpDirRow.editing = !wpDirRow.editing;
            if (wpDirRow.editing) {
                wpDirField.text = Flags.wallpaperDir;
                Qt.callLater(wpDirField.forceActiveFocus);
            }
        } }
    ]

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "THEMES"
            showBack: true
        }

        Item { width: 1; height: 8 * root.s }

        // Search Bar
        Rectangle {
            width: parent.width
            height: 32 * root.s
            radius: 8 * root.s
            color: Qt.alpha(Theme.frameBg, 0.5)
            border.width: 1
            border.color: searchField.activeFocus ? Qt.alpha(Theme.accent, 0.6) : Theme.hairSoft

            Row {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 10 * root.s
                anchors.rightMargin: 8 * root.s
                spacing: 8 * root.s

                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14 * root.s
                    height: 14 * root.s
                    name: "search"
                    color: searchField.activeFocus ? Theme.cream : Theme.iconDim
                    stroke: 1.8
                }

                TextField {
                    id: searchField
                    width: parent.width - 44 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    background: null
                    padding: 0
                    color: Theme.cream
                    font.family: Theme.font
                    font.pixelSize: 12 * root.s
                    placeholderText: "Search " + (root.allThemes.length > 0 ? root.allThemes.length : 27) + " Omarchy themes..."
                    placeholderTextColor: Theme.faint
                    selectByMouse: true
                    selectionColor: Theme.verm
                    onTextChanged: root.query = text
                }

                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.query.length > 0
                    width: 13 * root.s
                    height: 13 * root.s
                    name: "close"
                    color: clearMouse.containsMouse ? Theme.cream : Theme.iconDim
                    stroke: 1.8

                    MouseArea {
                        id: clearMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            searchField.text = "";
                            root.query = "";
                        }
                    }
                }
            }
        }

        Item { width: 1; height: 10 * root.s }

        // Theme Cards Grid
        Item {
            id: gridFrame
            width: parent.width
            height: 280 * root.s
            clip: true

            GridView {
                id: themeGrid
                anchors.fill: parent
                cellWidth: parent.width / 2
                cellHeight: 74 * root.s
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                model: root.filteredThemes

                delegate: Item {
                    id: tCard
                    required property int index
                    required property var modelData

                    readonly property bool isActive: {
                        var idMatch = tCard.modelData.id.toLowerCase() === root.activeThemeName;
                        var nameMatch = tCard.modelData.name.toLowerCase().replace(/\s+/g, "-") === root.activeThemeName;
                        return idMatch || nameMatch;
                    }

                    width: themeGrid.cellWidth
                    height: themeGrid.cellHeight

                    Rectangle {
                        id: cardBg
                        anchors.fill: parent
                        anchors.margins: 4 * root.s
                        radius: 8 * root.s
                        color: tCard.modelData.bg || Theme.frameBg
                        border.width: tCard.isActive ? 2 : 1
                        border.color: tCard.isActive ? (tCard.modelData.accent || Theme.accent) : (cardMouse.containsMouse ? Qt.alpha(Theme.cream, 0.25) : Qt.alpha(Theme.cream, 0.08))

                        Behavior on border.color { ColorAnimation { duration: Motion.fast } }

                        // Subtle active corner accent badge
                        Rectangle {
                            visible: tCard.isActive
                            anchors.top: parent.top
                            anchors.right: parent.right
                            width: 18 * root.s
                            height: 18 * root.s
                            radius: 9 * root.s
                            anchors.topMargin: -4 * root.s
                            anchors.rightMargin: -4 * root.s
                            color: tCard.modelData.accent || Theme.accent

                            GlyphIcon {
                                anchors.centerIn: parent
                                width: 10 * root.s
                                height: 10 * root.s
                                name: "check"
                                color: "#000000"
                                stroke: 2.2
                            }
                        }

                        Column {
                            anchors.fill: parent
                            anchors.margins: 8 * root.s
                            spacing: 5 * root.s

                            // Title & Mode Row
                            Row {
                                width: parent.width
                                spacing: 4 * root.s

                                Text {
                                    width: parent.width - (tCard.isActive ? 20 * root.s : 0)
                                    text: tCard.modelData.name
                                    color: tCard.modelData.fg || Theme.cream
                                    font.family: Theme.font
                                    font.pixelSize: 11.5 * root.s
                                    font.weight: tCard.isActive ? Font.Bold : Font.DemiBold
                                    elide: Text.ElideRight
                                }
                            }

                            // Palette ribbon
                            Row {
                                width: parent.width
                                spacing: 3 * root.s

                                Repeater {
                                    model: (tCard.modelData.palette && tCard.modelData.palette.length > 0)
                                        ? tCard.modelData.palette.slice(0, 5)
                                        : [tCard.modelData.accent || "#ffffff"]

                                    delegate: Rectangle {
                                        required property var modelData
                                        width: (parent.width - 12 * root.s) / 5
                                        height: 7 * root.s
                                        radius: 3.5 * root.s
                                        color: modelData
                                    }
                                }
                            }
                        }

                        MouseArea {
                            id: cardMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.switchTheme(tCard.modelData.id)
                        }
                    }
                }
            }
        }

        Item { width: 1; height: 10 * root.s }

        // Accordion for Custom Hue & Wallpaper Folder
        Rectangle {
            width: parent.width
            height: 34 * root.s
            radius: 8 * root.s
            color: customMouse.containsMouse ? Qt.alpha(Theme.sheen, 0.5) : "transparent"
            border.width: 1
            border.color: Theme.hairSoft

            Row {
                anchors.left: parent.left
                anchors.leftMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8 * root.s

                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14 * root.s
                    height: 14 * root.s
                    name: "palette"
                    color: Theme.iconDim
                    stroke: 1.8
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Manual Hue Tuning & Settings"
                    color: Theme.cream
                    font.family: Theme.font
                    font.pixelSize: 11.5 * root.s
                    font.weight: Font.DemiBold
                }
            }

            GlyphIcon {
                anchors.right: parent.right
                anchors.rightMargin: 10 * root.s
                anchors.verticalCenter: parent.verticalCenter
                width: 12 * root.s
                height: 12 * root.s
                name: root.customOpen ? "chevron-down" : "chevron-right"
                color: Theme.iconDim
                stroke: 1.8
            }

            MouseArea {
                id: customMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.customOpen = !root.customOpen
            }
        }

        // Custom Section Content
        Item {
            id: customSection
            width: parent.width
            height: root.customOpen ? customCol.implicitHeight : 0
            clip: true
            Behavior on height { NumberAnimation { duration: Motion.standard; easing.type: Motion.easeStandard } }

            Column {
                id: customCol
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                topPadding: 10 * root.s
                bottomPadding: 8 * root.s
                spacing: 12 * root.s

                SettingsRow {
                    surface: root
                    name: "Mode"
                    icon: "palette"

                    SettingsSeg {
                        s: root.s
                        options: [{ label: "Light", value: "light" }, { label: "Dark", value: "dark" }, { label: "Dynamic", value: "dynamic" }, { label: "Manual", value: "manual" }]
                        value: root.themeMode
                        onPicked: (v) => root.applyMode(v)
                    }
                }

                // Hue Strip
                Column {
                    width: parent.width
                    spacing: 10 * root.s
                    visible: Flags.paletteMode === "manual"

                    Item {
                        width: parent.width
                        height: 14 * root.s

                        Rectangle {
                            id: hueStrip
                            anchors.fill: parent
                            radius: 7 * root.s
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: Qt.hsla(0.0, 0.7, 0.5, 1) }
                                GradientStop { position: 1 / 6; color: Qt.hsla(1 / 6, 0.7, 0.5, 1) }
                                GradientStop { position: 2 / 6; color: Qt.hsla(2 / 6, 0.7, 0.5, 1) }
                                GradientStop { position: 3 / 6; color: Qt.hsla(3 / 6, 0.7, 0.5, 1) }
                                GradientStop { position: 4 / 6; color: Qt.hsla(4 / 6, 0.7, 0.5, 1) }
                                GradientStop { position: 5 / 6; color: Qt.hsla(5 / 6, 0.7, 0.5, 1) }
                                GradientStop { position: 1.0; color: Qt.hsla(1.0, 0.7, 0.5, 1) }
                            }

                            Rectangle {
                                id: hueThumb
                                width: 16 * root.s
                                height: 16 * root.s
                                radius: width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                x: (Flags.manualHue / 359) * (hueStrip.width - width)
                                color: root.accentColor
                                border.width: 2.5 * root.s
                                border.color: Theme.cream
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                function setHue(mx) {
                                    if (Flags.manualSat < 0.05)
                                        Flags.manualSat = 0.5;
                                    Flags.manualHue = Math.round(Math.max(0, Math.min(1, mx / hueStrip.width)) * 359);
                                }
                                onPressed: (mouse) => setHue(mouse.x)
                                onPositionChanged: (mouse) => setHue(mouse.x)
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: Math.max(34 * root.s, toneSeg.implicitHeight)

                        Rectangle {
                            id: accentSwatch
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 30 * root.s
                            height: 30 * root.s
                            radius: 8 * root.s
                            color: root.accentColor
                            border.width: 1
                            border.color: Theme.border
                        }

                        Column {
                            anchors.left: accentSwatch.right
                            anchors.leftMargin: 10 * root.s
                            anchors.right: toneSeg.left
                            anchors.rightMargin: 10 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2 * root.s

                            Text {
                                text: "Accent hue"
                                color: Theme.cream
                                font.family: Theme.font
                                font.pixelSize: 11.5 * root.s
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: root.currentHex + " · " + (Flags.manualDark ? "dark" : "light")
                                color: Theme.faint
                                font.family: Theme.font
                                font.pixelSize: 10 * root.s
                                font.features: { "tnum": 1 }
                                elide: Text.ElideRight
                                width: parent.width
                            }
                        }

                        SettingsSeg {
                            id: toneSeg
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            s: root.s
                            options: [{ label: "Dark", value: true }, { label: "Light", value: false }]
                            value: Flags.manualDark
                            onPicked: (v) => { Flags.manualDark = v; root.applyManual(); }
                        }
                    }
                }

                SettingsRow {
                    id: wpDirRow
                    surface: root
                    name: "Wallpaper folder"
                    icon: "wallpaper"
                    sub: wpDirRow.editing ? "Return to save · Esc to cancel" : Walls.wpDir
                    captionOnFocus: true
                    last: true

                    property bool editing: false

                    Item {
                        width: wpDirRow.editing ? 200 * root.s : 26 * root.s
                        height: 26 * root.s
                        Behavior on width { NumberAnimation { duration: Motion.fast } }

                        Rectangle {
                            anchors.fill: parent
                            radius: 8 * root.s
                            visible: wpDirRow.editing
                            color: Qt.alpha(Theme.frameBg, 0.7)
                            border.width: 1
                            border.color: wpDirField.activeFocus ? Qt.alpha(Theme.vermLit, 0.7) : Theme.hairSoft
                        }

                        TextInput {
                            id: wpDirField
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 8 * root.s
                            anchors.rightMargin: 8 * root.s
                            visible: wpDirRow.editing
                            clip: true
                            color: Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                            selectByMouse: true
                            selectionColor: Theme.verm

                            Keys.onPressed: (e) => {
                                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                    Flags.wallpaperDir = text.trim();
                                    Walls.refresh();
                                    wpDirRow.editing = false;
                                    focus = false;
                                    e.accepted = true;
                                } else if (e.key === Qt.Key_Escape) {
                                    wpDirRow.editing = false;
                                    focus = false;
                                    e.accepted = true;
                                }
                            }
                        }

                        GlyphIcon {
                            anchors.centerIn: parent
                            visible: !wpDirRow.editing
                            width: 15 * root.s
                            height: 15 * root.s
                            name: "wallpaper"
                            color: wpDirRow.focused ? Theme.cream : Theme.iconDim
                            stroke: 1.7
                        }
                    }
                }
            }
        }
    }
}
