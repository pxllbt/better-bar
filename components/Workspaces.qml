pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import Quickshell.Hyprland
import "../Singletons"

/**
 * Workspace dots for one monitor. No numbers, no icons. Active one is a larger
 * filled vermillion dot; the rest are small and dim, brightening on hover.
 * Clicking a dot focuses that workspace (Hyprland workspace dispatcher). Active
 * marker tracks the monitor's live active workspace name.
 *
 * The dot range unions this monitor's workspace rules ([[Workspacerules]]) with
 * the workspaces Hyprland currently has on it, so a rule-driven setup (e.g.
 * monitors.lua splitting 1-5 / 6-10 across two screens) always shows every
 * assigned dot while a workspace outside the rules (r+1 past the last ruled
 * one) still appears instead of vanishing from the strip.
 *
 * The workspace list and active workspace are read straight from hyprctl
 * (monitors -j / workspaces -j) rather than the Quickshell Hyprland models:
 * on a fresh launch `Hyprland.monitors.values` stays empty, workspace entries
 * carry a null monitor, and `focusedWorkspace` is null — so the dots would
 * only appear after the first switch re-populates the models. A raw hyprctl
 * fetch is deterministic from the first frame and matches the pattern
 * [[Workspacerules]] already uses for the rule map.
 */
Item {
    id: workspaces

    property string screenName: ""
    property real s: 1
    property real stickW: 17 * s
    property real dotW: 5 * s
    property real gap: 4 * s

    /**
     * When false, the watcher is fully inert: no hyprctl fetches, no Hyprland
     * event hooks, no boot polling. The hidden OSD controller in Pill.qml owns a
     * copy of this component that is never rendered, and gating it here stops
     * it from spawning sh + hyprctl on every workspace event. The OSD popup
     * instance stays watched, so visible workspace flashes keep fresh dots.
     * Input (enabled) is untouched: the strip face must stay live while
     * hovering, and the OSD dots are never interactive regardless.
     */
    property bool watch: true

    /**
     * The dot range and active marker are plain properties, recomputed
     * imperatively by rebuild() from the last hyprctl snapshot rather than
     * chained computed bindings. A switch onto an already-created workspace
     * only changes the active workspace — the list itself stays untouched —
     * so a computed binding could be left empty or stale, which is the "dots
     * missing until the next switch" glitch. rebuild always includes this
     * monitor's active workspace, so the strip never sits empty once the
     * monitor's data is known.
     */
    property var range: []
    property string activeName: ""

    property string activeWs: ""
    property var wsList: []

    function refreshData() {
        if (!workspaces.watch)
            return;
        debounce.restart();
    }

    Timer {
        id: debounce
        interval: 60
        repeat: false
        onTriggered: {
            if (!proc.running)
                proc.running = true;
        }
    }

    function rebuild() {
        var out = [];
        var seen = ({});
        var ruled = Workspacerules.byMonitor[screenName];
        if (ruled && ruled.length) {
            for (var r = 0; r < ruled.length; r++) {
                if (!seen[ruled[r]]) {
                    seen[ruled[r]] = true;
                    out.push(ruled[r]);
                }
            }
        }

        var wss = workspaces.wsList;
        for (var i = 0; i < wss.length; i++) {
            var w = wss[i];
            if (w && w.id >= 1 && w.monitor === screenName && !seen[w.id]) {
                seen[w.id] = true;
                out.push(w.id);
            }
        }
        var a = parseInt(workspaces.activeWs);
        if (a >= 1 && !seen[a])
            out.push(a);
        out.sort(function (x, y) { return x - y; });
        activeName = workspaces.activeWs;
        if (!rangesEqual(range, out))
            range = out;
        if (hoverIndex >= range.length)
            hoverIndex = -1;
    }

    function rangesEqual(a, b) {
        if (a.length !== b.length)
            return false;
        for (var i = 0; i < a.length; i++)
            if (a[i] !== b[i])
                return false;
        return true;
    }

    property int hoverIndex: -1

    /** When true, dots are in "clock-hovered" state — faded in with staggered pulse. */
    property bool pulseMode: false

    property int pulseTick: 0
    Timer {
        id: pulseTimer
        interval: 80
        repeat: true
        running: workspaces.pulseMode
        onTriggered: workspaces.pulseTick += 1
    }

    /**
     * Drives the agent badge's breath, and unlike the hover pulse it is never
     * optional: a running timer is what makes the badge animate, and a badge
     * that only animates while the clock happens to be hovered would be dead
     * most of the time. It only runs while something is actually badged, so it
     * costs nothing on an idle bar.
     */
    property int agentTick: 0
    readonly property bool anyAgent: Agents.urgent > 0 || Object.keys(Agents.badges).length > 0
    Timer {
        id: agentTimer
        interval: 90
        repeat: true
        running: workspaces.anyAgent
        triggeredOnStart: true
        onTriggered: workspaces.agentTick += 1
    }

    readonly property int activeIndex: range.indexOf(parseInt(activeName))

    readonly property real clockHoverPhase: {
        if (workspaces.pulseMode) {
            return Math.sin(workspaces.pulseTick * 0.5);
        }
        return 0;
    }
    readonly property real pulseDelay: 80

    /**
     * Centre x of a dot slot from target layout widths (active stick is wider).
     * Uses the animation end values, so a focus marker aimed here lands where
     * the dot settles and doesn't chase the width Behavior.
     */
    function slotCenterX(idx) {
        let x = 0;
        for (let i = 0; i < idx; i++)
            x += (i === activeIndex ? stickW : dotW) + gap;
        return x + (idx === activeIndex ? stickW : dotW) / 2;
    }

    readonly property point activeDotPoint: {
        void workspaces.activeName;
        void workspaces.width;
        return Qt.point(slotCenterX(Math.max(0, activeIndex)), height / 2);
    }

    property int bootTries: 0

    /**
     * The first hyprctl fetch runs on load, but a slow compositor reply could
     * still beat us to the first frame. Poll briefly until a snapshot lands
     * (or give up after the window), then rely on events from there on.
     */
    Timer {
        id: bootPoll
        interval: 250
        repeat: true
        running: workspaces.watch
        onTriggered: {
            workspaces.refreshData();
            workspaces.bootTries += 1;
            if (workspaces.wsList.length > 0 || workspaces.bootTries >= 8)
                bootPoll.running = false;
        }
    }

    Component.onCompleted: refreshData()
    onScreenNameChanged: refreshData()
    onWatchChanged: if (workspaces.watch) workspaces.refreshData()

    Connections {
        target: Hyprland
        enabled: workspaces.watch
        function onRawEvent(event) {
            var n = event.name;
            if (n === "workspace" || n === "workspacev2"
                || n === "createworkspace" || n === "destroyworkspace"
                || n === "moveworkspace" || n === "renameworkspace"
                || n === "focusedmon" || n === "focusedmonv2"
                || n === "monitoradded" || n === "monitorremoved")
                workspaces.refreshData();
        }
    }

    Connections {
        target: Workspacerules
        enabled: workspaces.watch
        function onByMonitorChanged() { workspaces.rebuild() }
    }

    Process {
        id: proc
        command: ["sh", "-c", "hyprctl monitors -j; printf '@@@'; hyprctl workspaces -j"]
        stdout: StdioCollector {
            id: wsStdout
            onStreamFinished: {
                var text = wsStdout.text || "";
                var sep = text.indexOf("@@@");
                var monJson = sep >= 0 ? text.slice(0, sep) : "[]";
                var wsJson = sep >= 0 ? text.slice(sep + 3) : text;
                var act = "";
                try {
                    var mons = JSON.parse(monJson);
                    for (var m = 0; m < mons.length; m++) {
                        if (mons[m] && mons[m].name === workspaces.screenName && mons[m].activeWorkspace)
                            act = String(mons[m].activeWorkspace.name);
                    }
                } catch (e) { }
                var list = [];
                try {
                    var arr = JSON.parse(wsJson);
                    for (var w = 0; w < arr.length; w++)
                        list.push({ id: arr[w].id, monitor: arr[w].monitor || "" });
                } catch (e) { }
                workspaces.activeWs = act;
                workspaces.wsList = list;
                workspaces.rebuild();
            }
        }
    }

    implicitWidth: row.implicitWidth
    implicitHeight: row.implicitHeight

    RowLayout {
        id: row
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: workspaces.gap

        Repeater {
            model: workspaces.range

            delegate: Item {
                id: slot

                required property var modelData
                required property int index

                readonly property string wsName: String(modelData)
                readonly property bool isActive: workspaces.activeName === wsName

                /**
                 * "" / "working" / "waiting" for this workspace. Read per
                 * delegate rather than cached, so a session that ends drops its
                 * badge on the next read rather than on a timer of its own.
                 */
                readonly property string agentState: Agents.badgeFor(wsName)

                Layout.preferredWidth: slot.isActive ? workspaces.stickW : workspaces.dotW
                Layout.preferredHeight: 22 * workspaces.s
                Behavior on Layout.preferredWidth { NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard } }

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width
                    height: workspaces.dotW
                    radius: height / 2
                    color: slot.isActive ? Theme.vermLit : Theme.cream
                    opacity: {
                        if (slot.isActive) {
                            if (workspaces.pulseMode)
                                return 0.5 + 0.5 * Math.sin((workspaces.pulseTick - slot.index) * 0.5);
                            return 1.0;
                        }
                        return area.containsMouse ? 0.7 : 0.3;
                    }
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                }

                /**
                 * Agent badge, on the dot rather than beside it: the dot is
                 * already the thing that means "this workspace", and a badge
                 * floating next to it would have to be told which dot it belongs
                 * to. `working` breathes, `waiting` is the one that pulses hard
                 * because it is the only state worth interrupting you for, and
                 * `done` deliberately shows nothing — a check that never clears
                 * is a check you stop seeing.
                 */
                Item {
                    id: agentBadge
                    anchors.centerIn: parent
                    width: parent.width + 3 * workspaces.s
                    height: parent.height + 3 * workspaces.s
                    visible: slot.agentState !== ""

                    readonly property color ink: slot.agentState === "waiting"
                        ? Theme.vermLit : Theme.verm
                    readonly property real beat: slot.agentState === "waiting" ? 0.85 : 0.45

                    Rectangle {
                        anchors.centerIn: parent
                        width: workspaces.dotW
                        height: workspaces.dotW
                        radius: height / 2
                        color: "transparent"
                        border.width: 1.4 * workspaces.s
                        border.color: agentBadge.ink
                        opacity: 0.25 + 0.75 * (0.5 + 0.5 * Math.sin(workspaces.agentTick * agentBadge.beat))
                        Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                    }

                    // A "!" rather than a glyph: it reads at 5px, where a word
                    // or an icon cannot, and it is the shape people already
                    // associate with "this wants you".
                    Text {
                        anchors.centerIn: parent
                        visible: slot.agentState === "waiting"
                        text: "!"
                        color: agentBadge.ink
                        font.family: Theme.font
                        font.pixelSize: 7 * workspaces.s
                        font.weight: Font.Bold
                    }
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    anchors.leftMargin: -workspaces.gap / 2
                    anchors.rightMargin: -workspaces.gap / 2
                    anchors.topMargin: -8 * workspaces.s
                    anchors.bottomMargin: -8 * workspaces.s
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Hyprland.dispatch("hl.dsp.focus({ workspace = " + slot.wsName + " })")
                    onWheel: (wheel) => {
                        if (wheel.angleDelta.y < 0)
                            Hyprland.dispatch("workspace e+1");
                        else if (wheel.angleDelta.y > 0)
                            Hyprland.dispatch("workspace e-1");
                    }
                    onContainsMouseChanged: {
                        if (containsMouse)
                            workspaces.hoverIndex = slot.index;
                        else if (workspaces.hoverIndex === slot.index)
                            workspaces.hoverIndex = -1;
             }
         }
     }
}
    }
}
