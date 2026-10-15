pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"

/**
 * PLYMOUTH: the boot / unlock Plymouth theme picker that ships inside Better Bar.
 *
 * Omarchy already has a Plymouth-style picker in its menu, and it needs a
 * terminal because Plymouth is system-owned: applying a theme writes under
 * /usr/share/plymouth and therefore asks for privilege. This surface keeps that
 * truth. It reads the real inventory with `omarchy-plymouth-list`, shows the
 * live value from `omarchy-plymouth-current`, and applies changes through
 * Omarchy's floating terminal wrapper so the password prompt still has a place
 * to be answered.
 *
 * This is deliberately not a wrapper around `omarchy-plymouth-switcher`'s image
 * menu: that is a file picker, and Better Bar already owns the styling of a
 * settings row. Showing the same list here adds no privilege and loses none of
 * the native behaviour.
 */
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    /** The list is long; keep the surface pill-sized and scroll the themes. */
    readonly property real listCap: 260 * root.s

    property var availableThemes: []
    property string currentTheme: ""
    property string statusMessage: "Loading Plymouth unlock themes…"

    /** Theme-specific nav entries, grown as the list arrives. */
    property var themeRows: []

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
        root.rows = root.themeRows.concat([
            { item: resetRow, kind: "toggle", get: function () { return false; }, activate: () => root.resetPlymouth() },
            { item: statusRow, kind: "toggle", get: function () { return false; } }
        ]);
    }

    function themeTitle(name) {
        var s = String(name || "");
        return s.length === 0 ? s
            : s.split(/[-_ ]+/).map(function (word) {
                return word.charAt(0).toUpperCase() + word.slice(1);
            }).join(" ");
    }

    function themeSub(name) {
        if (name === root.currentTheme)
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
        root.statusMessage = "Applying " + root.themeTitle(name) + " in the terminal…";
        applyProc.command = [
            "omarchy-launch-floating-terminal-with-presentation",
            "omarchy-plymouth-set-by-theme " + name
        ];
        applyProc.running = true;
    }

    function resetPlymouth() {
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
                    ? "Pick an unlock theme · changes apply in the terminal"
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

    Process {
        id: applyProc
        running: false
        command: []
        onExited: function (code) {
            // The wrapper talks to a terminal, so its exit is not the theme's
            // finished state. Re-read the installed value after a short delay
            // instead of reporting success from a launcher's exit code.
            refreshAfterApply.restart();
            root.statusMessage = "Unlock theme command sent · confirming…";
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
            id: resetRow
            surface: root
            glyph: "undo"
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
                        icon: root.currentTheme === themeRow.modelData ? "check" : "dot"
                        name: root.themeTitle(themeRow.modelData)
                        sub: root.themeSub(themeRow.modelData)
                        last: themeRow.index === root.availableThemes.length - 1 && root.themeRows.length === 0

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
                + (root.currentTheme.length ? " · current: " + root.themeTitle(root.currentTheme) : "")
            last: true
        }
    }
}