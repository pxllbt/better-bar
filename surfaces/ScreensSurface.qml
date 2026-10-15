pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import "../components"
import "../Singletons"

/**
 * SCREENS -- the canvas, the per-screen editor and the profile list.
 *
 * Three regions in one column. The canvas draws every screen on the draft's
 * reflowed grid, lit for the focused one, so an arrangement is legible at a
 * glance. The editor drives the focused screen only. The profile list loads and
 * saves whole arrangements, matched to the machine by hardware identity rather
 * than by port, so a cable moved to another connector does not orphan a layout.
 *
 * This file draws and directs; it decides nothing. The layout rules live in the
 * Screens singleton as pure functions the unit tests lift out of it, the writer
 * lives in scripts/screens.sh, and this file never reaches the compositor
 * itself -- every mutation goes through Screens.updateDraft(), which applies
 * once when the draft settles.
 */
SettingsSurface {
    id: root

    // The Sysmon inset, not the SettingsSurface defaults: the canvas wants the
    // tightest margins it can get, the same 16 the dials use.
    mTop: 14
    mLeft: 16
    mRight: 16
    mBottom: 16

    implicitHeight: content.implicitHeight

    // Polling runs only while the surface is on screen.
    onActiveChanged: Screens.open = active

    // ---- focus -----------------------------------------------------------

    readonly property int fi: Screens.focusIndex
    readonly property var scr: Screens.focusScreen()
    readonly property int enabledCount: Screens.enabledCount()

    /** Whether one field has drifted from the live value it started from. */
    function diverged(field) {
        if (!root.scr)
            return false;
        var v = Screens.liveValue(root.scr.name, field);
        if (v === undefined)
            return false;
        return root.scr[field] !== v;
    }

    // ---- the last-screen rule -------------------------------------------

    /**
     * The one gate on turning a screen off. A layout with nothing enabled is
     * refused by the writer, and doing it here rather than trusting the writer
     * means the surface can say why instead of just failing.
     */
    function toggleEnabled(v) {
        if (!root.scr)
            return;
        if (!v && root.enabledCount <= 1) {
            Screens.status = "refused: the last enabled screen stays on";
            return;
        }
        Screens.updateDraft(root.fi, { enabled: !!v });
    }

    /** Save the current draft under the name in the field, then clear the field. */
    function commitProfileName() {
        if (!root.newProfileName.length)
            return false;
        Screens.saveProfile(root.newProfileName);
        nameField.text = "";
        root.newProfileName = "";
        return true;
    }

    // ---- option lists (labels are presentation, so they live here) ------

    function fmtScale(v) {
        return (Math.round(v * 100) / 100).toString();
    }

    /**
     * One pill per distinct resolution at its fastest refresh. A panel
     * advertising twenty-nine modes has a handful of distinct pixel sizes, and
     * twenty-nine pills would not fit.
     */
    function modeOptions() {
        if (!root.scr || !root.scr.modes)
            return [];
        var best = {};
        for (var i = 0; i < root.scr.modes.length; i++) {
            var m = root.scr.modes[i];
            var key = m.w + "x" + m.h;
            if (!best[key] || m.hz > best[key].hz)
                best[key] = m;
        }
        var out = [];
        for (var k in best)
            out.push(best[k]);
        out.sort(function (a, b) { return (b.w * b.h) - (a.w * a.h); });
        if (out.length > 6) {
            var trimmed = out.slice(0, 6);
            var current = null;
            for (var c = 0; c < out.length; c++) {
                if (out[c].raw === (root.scr ? root.scr.mode : ""))
                    current = out[c];
            }
            if (current && trimmed.indexOf(current) < 0)
                trimmed.push(current);
            out = trimmed;
        }
        return out.map(function (m) { return { label: m.w + "x" + m.h, value: m.raw }; });
    }

    function modeValues() {
        return root.modeOptions().map(function (o) { return o.value; });
    }

    /**
     * The scales that keep this mode's pixel grid whole. A fractional scale that
     * does not divide the width evenly renders a sheared, soft canvas, so the
     * candidates are the ones that do.
     */
    function scaleOptions() {
        if (!root.scr || !root.scr.width)
            return [];
        var w = root.scr.width;
        var cands = [1, 1.1, 1.2, 1.25, 1.33, 1.5, 1.6, 1.75, 2, 2.25, 2.5, 3];
        var out = [];
        for (var i = 0; i < cands.length; i++) {
            var v = cands[i];
            var px = w / v;
            if (px < 1 || Math.abs(px - Math.round(px)) > 0.001)
                continue;
            out.push({ label: root.fmtScale(v), value: v });
        }
        var cur = root.scr.scale;
        var has = false;
        for (var j = 0; j < out.length; j++) {
            if (out[j].value === cur)
                has = true;
        }
        if (!has && cur !== undefined)
            out.push({ label: root.fmtScale(cur), value: cur });
        out.sort(function (a, b) { return a.value - b.value; });
        return out;
    }

    function scaleValues() {
        return root.scaleOptions().map(function (o) { return o.value; });
    }

    readonly property var rotationOptions: [
        { label: "0", value: 0 },
        { label: "90", value: 1 },
        { label: "180", value: 2 },
        { label: "270", value: 3 }
    ]

    function mirrorOptions() {
        var out = [{ label: "none", value: "" }];
        for (var i = 0; i < Screens.draft.length; i++) {
            var s = Screens.draft[i];
            if (i === root.fi || !s || !s.enabled)
                continue;
            out.push({ label: s.name || s.output, value: s.output || s.name });
        }
        return out;
    }

    function mirrorValues() {
        return root.mirrorOptions().map(function (o) { return o.value; });
    }

    // ---- keys: the only way to move a screen on the canvas ---------------

    Keys.onPressed: (e) => {
        if (!open)
            return;
        var fine = !!(e.modifiers & Qt.ShiftModifier);
        var snap = !!(e.modifiers & Qt.ControlModifier);
        switch (e.key) {
        case Qt.Key_Left:
            if (snap) Screens.snapEdge("left");
            else Screens.nudge(-1, 0, fine);
            e.accepted = true;
            return;
        case Qt.Key_Right:
            if (snap) Screens.snapEdge("right");
            else Screens.nudge(1, 0, fine);
            e.accepted = true;
            return;
        case Qt.Key_Up:
            if (snap) Screens.snapEdge("up");
            else Screens.nudge(0, -1, fine);
            e.accepted = true;
            return;
        case Qt.Key_Down:
            if (snap) Screens.snapEdge("down");
            else Screens.nudge(0, 1, fine);
            e.accepted = true;
            return;
        case Qt.Key_Tab:
            Screens.focusNext();
            e.accepted = true;
            return;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.toggleEnabled(root.scr ? !root.scr.enabled : true);
            e.accepted = true;
            return;
        }
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        width: parent.width
        spacing: 0

        // -- title ---------------------------------------------------------

        Item {
            width: parent.width
            height: 24 * root.s

            Text {
                id: titleLabel
                anchors.verticalCenter: parent.verticalCenter
                text: "SCREENS"
                color: Theme.subtle
                font.family: Theme.font
                font.pixelSize: 10 * root.s
                font.weight: Font.DemiBold
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 1.8 * root.s
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.scr ? (root.scr.name || "") : "no screen"
                color: Theme.iconDim
                font.family: Theme.font
                font.pixelSize: 10 * root.s
                font.letterSpacing: 0.6 * root.s
            }
        }

        // -- the canvas ----------------------------------------------------

        ScreensCanvas {
            id: canvas
            width: parent.width
            s: root.s
            draft: Screens.draft
            focusIndex: Screens.focusIndex
            onFocusPicked: (i) => Screens.setFocus(i)
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.hairSoft
        }

        Item {
            width: 1
            height: 10 * root.s
        }

        // -- the editor -----------------------------------------------------

        SettingsRow {
            id: rowEnabled
            surface: root
            name: "Enabled"
            icon: "monitor"
            sub: root.enabledCount <= 1 ? "the only screen on" : "one of " + root.enabledCount + " on"
            enabled: !!root.scr

            LinkToggle {
                s: root.s
                on: root.scr ? !!root.scr.enabled : false
                onToggled: root.toggleEnabled(root.scr ? !root.scr.enabled : true)
            }
        }

        SettingsRow {
            id: rowMode
            surface: root
            name: "Resolution"
            icon: "monitor"
            sub: root.scr ? (root.scr.mode || "preferred") : ""
            enabled: !!root.scr

            Row {
                spacing: 6 * root.s

                SettingsSeg {
                    s: root.s
                    options: root.modeOptions()
                    value: root.scr ? root.scr.mode : ""
                    onPicked: (v) => Screens.updateDraft(root.fi, { mode: v })
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.diverged("mode")
                    text: "reset"
                    color: Theme.iconDim
                    font.family: Theme.font
                    font.pixelSize: 8 * root.s
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4 * root.s
                        onClicked: Screens.resetField("mode")
                    }
                }
            }
        }

        SettingsRow {
            id: rowScale
            surface: root
            name: "Scale"
            icon: "zoom"
            sub: root.scr ? root.fmtScale(root.scr.scale) : ""
            enabled: !!root.scr

            Row {
                spacing: 6 * root.s

                SettingsSeg {
                    s: root.s
                    options: root.scaleOptions()
                    value: root.scr ? root.scr.scale : 1
                    onPicked: (v) => Screens.updateDraft(root.fi, { scale: v })
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.diverged("scale")
                    text: "reset"
                    color: Theme.iconDim
                    font.family: Theme.font
                    font.pixelSize: 8 * root.s
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4 * root.s
                        onClicked: Screens.resetField("scale")
                    }
                }
            }
        }

        SettingsRow {
            id: rowRotate
            surface: root
            name: "Rotation"
            icon: "rotate"
            sub: root.scr ? (root.scr.transform === 1 || root.scr.transform === 3 ? "portrait" : "landscape") : ""
            enabled: !!root.scr

            Row {
                spacing: 6 * root.s

                SettingsSeg {
                    s: root.s
                    options: root.rotationOptions
                    value: root.scr ? root.scr.transform : 0
                    onPicked: (v) => Screens.updateDraft(root.fi, { transform: v })
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.diverged("transform")
                    text: "reset"
                    color: Theme.iconDim
                    font.family: Theme.font
                    font.pixelSize: 8 * root.s
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4 * root.s
                        onClicked: Screens.resetField("transform")
                    }
                }
            }
        }

        SettingsRow {
            id: rowMirror
            surface: root
            name: "Mirror"
            icon: "copy"
            sub: root.scr ? (root.scr.mirror || "none") : ""
            enabled: !!root.scr

            SettingsSeg {
                s: root.s
                options: root.mirrorOptions()
                value: root.scr ? root.scr.mirror : ""
                onPicked: (v) => Screens.updateDraft(root.fi, { mirror: v })
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.hairSoft
        }

        Item {
            width: 1
            height: 10 * root.s
        }

        // -- profiles ---------------------------------------------------------

        Text {
            text: "PROFILES"
            color: Theme.subtle
            font.family: Theme.font
            font.pixelSize: 9 * root.s
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1.6 * root.s
        }

        Item {
            width: 1
            height: 6 * root.s
        }

        SettingsRow {
            id: rowSave
            surface: root
            name: "Save this layout"
            icon: "save"
            sub: Screens.profiles.length ? Screens.profiles.length + " saved" : "none saved yet"

            Row {
                spacing: 6 * root.s

                SettingsSeg {
                    s: root.s
                    options: [{ label: "save", value: "save" }]
                    value: ""
                    onPicked: (v) => {
                        if (root.newProfileName.length)
                            Screens.saveProfile(root.newProfileName);
                    }
                }

                // readOnly and edited through the TextEntry engine, the bar's
                // one editable-field convention: a live TextInput reads the
                // clipboard on every change, and the bar is a single process.
                TextField {
                    id: nameField
                    width: 84 * root.s
                    height: 24 * root.s
                    background: null
                    padding: 0
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.cream
                    selectionColor: Theme.hair
                    placeholderText: "name"
                    placeholderTextColor: Theme.iconDim
                    font.family: Theme.font
                    font.pixelSize: 10 * root.s
                    text: root.newProfileName
                    clip: true
                    Keys.onPressed: (e) => {
                        TextEntry.handle(nameField, e);
                    }
                    // TextEntry deliberately leaves Return alone, so Enter can
                    // commit the name without reaching for the mouse.
                    Keys.onReturnPressed: root.commitProfileName()
                    Keys.onEnterPressed: root.commitProfileName()
                    selectByMouse: false
                    readOnly: true
                    onActiveFocusChanged: cursorVisible = activeFocus
                    onTextChanged: root.newProfileName = text
                }
            }
        }

        Item {
            width: 1
            height: 6 * root.s
        }

        Repeater {
            // A profile that names screens which are not present is marked and
            // refused: loading it would move the ones that are and strand the
            // rest, which is worse than not loading it.
            model: Screens.profiles

            delegate: SettingsRow {
                required property var modelData

                // Matched by hardware identity, so a profile saved on this desk
                // still finds its screens after a cable moves to another port.
                readonly property var pairing: Screens.pairByIdentity(Screens.live, modelData.screens || [])

                surface: root
                name: (modelData.name || "unnamed")
                sub: "screens " + pairing.present + "/" + pairing.total
                enabled: pairing.full

                SettingsSeg {
                    s: root.s
                    options: [{ label: "load", value: "load" }, { label: "forget", value: "forget" }]
                    value: ""
                    onPicked: (v) => {
                        if (v === "load")
                            Screens.loadProfile(modelData.id);
                        else
                            Screens.forgetProfile(modelData.id);
                    }
                }
            }
        }

        // -- the writer's last word ------------------------------------------

        Text {
            width: parent.width
            visible: Screens.status.length > 0
            text: Screens.status
            color: Screens.status.indexOf("refused") === 0 ? Theme.verm : Theme.iconDim
            font.family: Theme.font
            font.pixelSize: 9 * root.s
            wrapMode: Text.WordWrap
        }
    }
}
