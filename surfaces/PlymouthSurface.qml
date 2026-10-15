pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"

/**
 * PLYMOUTH · UNLOCK: the boot/unlock screen picker that ships inside Better Bar.
 *
 * Plymouth is system-owned: applying a theme writes under /usr/share/plymouth
 * and therefore asks for privilege. Better Bar does not hide that — it runs the
 * privileged step through Omarchy's floating terminal wrapper so the password
 * prompt has a place to appear.
 *
 * This surface is a full customiser, not a theme clone:
 *
 *   1. Custom unlock — background hex, text hex and a logo file chosen with the
 *      desktop file chooser, applied through `omarchy-plymouth-set`. Nothing is
 *      tied to the current Omarchy desktop theme.
 *   2. Theme presets — the theme list remains as a one-tap shortcut, because
 *      Omarchy's `omarchy-plymouth-set-by-theme` is the fastest way to match the
 *      boot screen to a desktop theme.
 *   3. Stock Plymouth — restores the packaged default.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    /** The preset list is long; keep the surface pill-sized and scroll only it. */
    readonly property real listCap: 260 * root.s

    property var availableThemes: []
    property string currentTheme: ""
    property string statusMessage: "Loading Plymouth unlock themes…"

    /* Custom unlock state lives in flags.json, so reopening the surface keeps
     * the colours and logo rather than resetting to the desktop's scheme. */
    readonly property string stockLogo: Plymouth.stockLogo
    readonly property string activeLogo: Plymouth.activeLogo
    readonly property bool customValid: Plymouth.valid
    /** True between a custom apply and the next theme/reset apply. */
    property bool customPending: false

    /** Theme-specific nav entries, grown as the preset list arrives. */
    property var themeRows: []

    function isHex(v) {
        return Plymouth.isHex(v);
    }

    function upperHex(v) {
        return String(v || "").toUpperCase();
    }

    function setBg(v) {
        var hex = root.upperHex(v);
        if (!root.isHex(hex)) {
            root.statusMessage = "Background must be #RRGGBB";
            return;
        }
        Flags.plymouthBg = hex;
    }

    function setTextColor(v) {
        var hex = root.upperHex(v);
        if (!root.isHex(hex)) {
            root.statusMessage = "Text colour must be #RRGGBB";
            return;
        }
        Flags.plymouthText = hex;
    }

    function basename(p) {
        var s = String(p || "");
        var at = s.lastIndexOf("/");
        return at >= 0 ? s.substring(at + 1) : s;
    }

    /** Single-quote one shell argument, without relying on bash string internals. */
    function shellArg(v) {
        return Plymouth.shellArg(v);
    }

    function refresh() {
        listProc.running = true;
        currentProc.running = true;
    }

    function registerRow(item) {
        if (root.themeRows.indexOf(item) === -1) {
            root.themeRows = root.themeRows.concat([item]);
            root.syncRows();
        }
    }

    function unregisterRow(item) {
        var next = root.themeRows.slice();
        var at = next.indexOf(item);
        if (at !== -1) {
            next.splice(at, 1);
            root.themeRows = next;
            root.syncRows();
        }
    }

    function syncRows() {
        root.rows = [
            { item: bgRow, kind: "toggle", get: function () { return false; }, activate: function () { bgField.input.forceActiveFocus(); } },
            { item: textRow, kind: "toggle", get: function () { return false; }, activate: function () { textField.input.forceActiveFocus(); } },
            { item: logoRow, kind: "toggle", get: function () { return false; }, activate: function () { root.pickLogo(); } },
            { item: stockLogoRow, kind: "toggle", get: function () { return false; }, activate: function () { root.useStockLogo(); } },
            { item: applyCustomRow, kind: "toggle", get: function () { return false; }, activate: function () { root.applyCustom(); } },
            { item: resetRow, kind: "toggle", get: function () { return false; }, activate: function () { root.resetPlymouth(); } },
            { item: statusRow, kind: "toggle", get: function () { return false; } }
        ].concat(root.themeRows);
    }

    function themeTitle(name) {
        var s = String(name || "");
        return s.length === 0 ? s
            : s.split(/[-_ ]+/).map(function (word) {
                return word.charAt(0).toUpperCase() + word.slice(1);
            }).join(" ");
    }

    function themeSub(name) {
        if (!root.customPending && name === root.currentTheme)
            return "Currently applied to the unlock screen";
        return "Apply to the Plymouth unlock screen";
    }

    /**
     * Applying a Plymouth theme is a privileged operation. Omarchy solves the
     * prompt problem by running it in the floating terminal wrapper, so Better
     * Bar does the same rather than invoking the privileged command behind a
     * GUI where its password prompt cannot appear.
     */
    function applyTheme(name) {
        if (!name || name.length === 0)
            return;
        root.customPending = false;
        root.statusMessage = "Applying " + root.themeTitle(name) + " in the terminal…";
        applyProc.command = [
            "omarchy-launch-floating-terminal-with-presentation",
            "omarchy-plymouth-set-by-theme " + name
        ];
        applyProc.running = true;
    }

    function pickLogo() {
        root.statusMessage = "Choosing a PNG unlock logo…";
        logoPickerProc.running = true;
    }

    function useStockLogo() {
        Flags.plymouthLogo = "";
        root.statusMessage = "Using the stock Omarchy unlock logo";
    }

    function applyCustom() {
        if (!root.customValid) {
            root.statusMessage = "Set both colours as #RRGGBB first";
            return;
        }
        root.customPending = true;
        root.statusMessage = "Applying custom unlock colours in the terminal…";
        applyProc.command = [
            "omarchy-launch-floating-terminal-with-presentation",
            "omarchy-plymouth-set " + root.shellArg(Flags.plymouthBg)
                + " " + root.shellArg(Flags.plymouthText)
                + " " + root.shellArg(root.activeLogo)
        ];
        applyProc.running = true;
    }

    function resetPlymouth() {
        root.customPending = false;
        root.statusMessage = "Restoring the default Plymouth unlock theme…";
        resetProc.command = [
            "omarchy-launch-floating-terminal-with-presentation",
            "omarchy-plymouth-reset"
        ];
        resetProc.running = true;
    }

    Process {
        id: listProc
        command: ["omarchy-plymouth-list"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var raw = String(text || "").trim();
                var out = [];
                if (raw.length > 0) {
                    var seen = {};
                    raw.split("\n").forEach(function (line) {
                        var name = line.trim();
                        if (name.length > 0 && !seen[name]) {
                            seen[name] = true;
                            out.push(name);
                        }
                    });
                }
                out.sort();
                root.availableThemes = out;
                var stillThere = out.indexOf(root.currentTheme) !== -1;
                if (!stillThere && root.currentTheme !== "default")
                    root.currentTheme = "";
                root.statusMessage = out.length
                    ? "Presets below · custom unlock above needs no theme"
                    : "No Plymouth unlock themes were found";
            }
        }
    }

    Process {
        id: currentProc
        command: ["omarchy-plymouth-current"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var value = String(text || "").trim();
                root.currentTheme = value;
            }
        }
    }

    /**
     * The desktop file chooser. It prints one local path per selected file and
     * a bare newline is still a non-empty string, so an empty answer is handled
     * explicitly rather than falling through as a zero-length logo path.
     */
    Process {
        id: logoPickerProc
        running: false
        command: ["omarchy-file-select", "--title", "Pick Plymouth unlock logo", "--extensions", "png"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = String(text || "").split("\n");
                var picked = "";
                for (var i = 0; i < lines.length; i++) {
                    if (lines[i].trim().length > 0) {
                        picked = lines[i].trim();
                        break;
                    }
                }
                if (picked.length > 0) {
                    Flags.plymouthLogo = picked;
                    root.customPending = true;
                    root.statusMessage = "Selected " + root.basename(picked) + " · apply to publish it";
                } else {
                    root.statusMessage = "No Plymouth logo selected";
                }
            }
        }
    }

    Process {
        id: applyProc
        running: false
        command: []
        onExited: function (code) {
            // The wrapper talks to a terminal, so its exit is not the theme's
            // finished state. Re-read the installed value after a short delay
            // instead of reporting success from a launcher's exit code.
            refreshAfterApply.restart();
            root.statusMessage = "Unlock command sent · confirming…";
        }
    }

    Process {
        id: resetProc
        running: false
        command: []
        onExited: function (code) {
            refreshAfterApply.restart();
            root.statusMessage = "Plymouth reset command sent · confirming…";
        }
    }

    Timer {
        id: refreshAfterApply
        interval: 3500
        repeat: false
        running: false
        onTriggered: currentProc.running = true;
    }

    Component.onCompleted: {
        root.syncRows();
        root.refresh();
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "PLYMOUTH · UNLOCK"
            showBack: true
        }

        Item { width: 1; height: 10 * root.s }

        SettingsRow {
            id: bgRow
            surface: root
            icon: "palette"
            name: "Unlock background"
            sub: "Hex colour · independent of the desktop theme"

            Row {
                spacing: 8 * root.s

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18 * root.s
                    height: 18 * root.s
                    radius: 5 * root.s
                    color: root.customValid ? Qt.color(Flags.plymouthBg) : Theme.tileBg
                    border.width: 1
                    border.color: root.customValid ? Qt.rgba(1, 1, 1, 0.25) : Theme.border
                }

                SearchField {
                    id: bgField
                    width: 92 * root.s
                    s: root.s
                    active: root.active
                    text: Flags.plymouthBg
                    placeholder: "#1A1B26"
                    onAccepted: root.setBg(text)
                }
            }
        }

        SettingsRow {
            id: textRow
            surface: root
            icon: "type"
            name: "Unlock text colour"
            sub: "Hex colour for the unlock copy"

            Row {
                spacing: 8 * root.s

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18 * root.s
                    height: 18 * root.s
                    radius: 5 * root.s
                    color: root.customValid ? Qt.color(Flags.plymouthText) : Theme.tileBg
                    border.width: 1
                    border.color: root.customValid ? Qt.rgba(1, 1, 1, 0.25) : Theme.border
                }

                SearchField {
                    id: textField
                    width: 92 * root.s
                    s: root.s
                    active: root.active
                    text: Flags.plymouthText
                    placeholder: "#EBDBB2"
                    onAccepted: root.setTextColor(text)
                }
            }
        }

        SettingsRow {
            id: logoRow
            surface: root
            icon: "wallpaper"
            name: "Unlock logo"
            sub: Flags.plymouthLogo.length > 0
                ? root.basename(Flags.plymouthLogo)
                : "Stock Omarchy logo"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === logoRow ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: stockLogoRow
            surface: root
            icon: "undo"
            name: "Use stock logo"
            sub: "Drop the custom logo and keep the colours"
            last: false

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === stockLogoRow ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: applyCustomRow
            surface: root
            icon: "check"
            name: "Apply custom unlock"
            sub: root.customValid
                ? ("Colours ready · logo: " + root.basename(root.activeLogo))
                : "Both colours must be #RRGGBB"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === applyCustomRow ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        SettingsRow {
            id: resetRow
            surface: root
            icon: "undo"
            name: "Stock Plymouth"
            sub: "Restore the default Omarchy unlock screen"

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === resetRow ? Theme.cream : Theme.iconDim
                stroke: 1.9
            }
        }

        Item { width: 1; height: 8 * root.s }

        Flickable {
            width: parent.width
            height: Math.min(themeCol.implicitHeight, root.listCap)
            contentHeight: themeCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: themeCol
                width: parent.width

                Repeater {
                    model: root.availableThemes

                    delegate: SettingsRow {
                        id: themeRow
                        required property string modelData
                        required property int index

                        surface: root
                        icon: (!root.customPending && root.currentTheme === themeRow.modelData) ? "check" : "dot"
                        name: root.themeTitle(themeRow.modelData)
                        sub: root.themeSub(themeRow.modelData)

                        property var navEntry: null
                        Component.onCompleted: {
                            themeRow.navEntry = {
                                item: themeRow,
                                kind: "toggle",
                                get: function () { return false; },
                                activate: function () {
                                    root.applyTheme(themeRow.modelData);
                                }
                            };
                            root.registerRow(themeRow.navEntry);
                        }
                        Component.onDestruction: root.unregisterRow(themeRow.navEntry)
                    }
                }
            }
        }

        SettingsRow {
            id: statusRow
            surface: root
            glyph: "shield"
            name: "Status"
            sub: root.statusMessage
                + (root.currentTheme.length ? " · system: " + root.themeTitle(root.currentTheme) : "")
            last: true
        }
    }
}
