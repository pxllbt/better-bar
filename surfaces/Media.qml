pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Widgets
import "../Singletons"
import "../components"

/**
 * Now Playing surface: Physical audio deck aesthetics (Teenage Engineering,
 * Braun, Bang & Olufsen, modern visionOS Now Playing). A centered circular
 * media card — a vinyl-framed album art disc — serves as the visual focal point,
 * with transport controls arranged beneath, a tabular seek bar below that, and
 * a right utility rail for volume and status. The disc rotates while a track
 * plays; tactile buttons and tabular figures give the deck a physical heft.
 */
PillSurface {
    id: root

    /** Squared top corners when the pill is in strip mode; 0 = rounded everywhere. */
    property real topFlat: 0
    Behavior on topFlat { NumberAnimation { duration: Motion.morph; easing.type: Motion.easeMorph; easing.bezierCurve: Motion.morphCurve } }

    /**
     * True when the card is a floating island above a live strip rather than
     * the pill's own face.
     */
    property bool floats: false

    signal requestExpand()

    /**
     * With expandTo "media" the card is hover-driven in every auto-hide mode:
     * leaving it (past a small margin + grace window) closes the surface again
     * so the pill shrinks back to rest (or hides). Only arms once the card has
     * actually been hovered, so keyboard / IPC summon does not immediately drop.
     */
    property bool wasHovered: false
    onOpenChanged: if (!open) wasHovered = false

    Timer {
        id: leaveGuardT
        interval: 160
        onTriggered: root.requestClose()
    }

    /**
     * Full-pill hover overlay. In centred mode the media card IS the pill face,
     * but child controls host their own MouseAreas with hoverEnabled, and Qt Quick
     * does not guarantee the parent HoverHandler sees those moves. The overlay at
     * z: -1 keeps the leave-guard honest across the entire pill footprint.
     */
    Item {
        anchors.fill: parent
        z: -1
        HoverHandler {
            id: leaveGuard
            enabled: root.open && !root.floats && Flags.expandTo === "media" && !root.pinned
            margin: 24 * root.s
            onHoveredChanged: {
                if (hovered) {
                    root.wasHovered = true;
                    leaveGuardT.stop();
                } else if (enabled && root.wasHovered) {
                    leaveGuardT.start();
                }
            }
        }
    }

    readonly property var player: Players.active
    readonly property bool hasPlayer: player !== null
    readonly property bool playing: Players.playing
    readonly property string title: Players.has && Players.title ? Players.title : "Nothing playing"
    readonly property string artist: Players.artist
    readonly property string album: Players.album
    readonly property bool live: Players.live
    readonly property string serviceLabel: Players.serviceLabel

    /** artist · album, whichever of the two exists */
    readonly property string sub: {
        var parts = [];
        if (root.artist.length > 0) parts.push(root.artist);
        if (root.album.length > 0) parts.push(root.album);
        return parts.join(" · ");
    }

    /** Loop toggle. MprisLoopState walks None -> Track -> Playlist -> None. */
    readonly property bool loopOk: Boolean(hasPlayer && root.player && root.player.loopSupported && root.player.canControl)
    readonly property bool loopNone: Boolean(!hasPlayer || !root.loopOk || (root.player && root.player.loopState === MprisLoopState.None))
    readonly property bool loopTrack: Boolean(hasPlayer && root.loopOk && root.player && root.player.loopState === MprisLoopState.Track)
    function nextLoop() {
        if (!root.player)
            return;
        if (root.player.loopState === MprisLoopState.None)
            root.player.loopState = MprisLoopState.Track;
        else if (root.player.loopState === MprisLoopState.Track)
            root.player.loopState = MprisLoopState.Playlist;
        else
            root.player.loopState = MprisLoopState.None;
    }

    /** Live throughput (MB/s) read straight from /proc/net/dev while the card is open. */
    property real netDown: 0
    property real netUp: 0
    property bool netOk: false
    property real netPrevRx: 0
    property real netPrevTx: 0
    property real netPrevTime: 0
    function fmtNet(v) {
        if (!(v > 0))
            return "0";
        if (v >= 1)
            return v.toFixed(1) + "M";
        var kb = v * 1024;
        return (kb >= 10 ? Math.round(kb) : kb.toFixed(1)) + "K";
    }

    /** First connected Bluetooth device plus its battery, when BlueZ reports one. */
    readonly property var btDevices: (typeof Bluetooth !== "undefined" && Bluetooth && Bluetooth.devices) ? Bluetooth.devices.values : []
    readonly property var btConnected: {
        var out = [];
        for (var i = 0; i < root.btDevices.length; i++)
            if (root.btDevices[i] && root.btDevices[i].connected) out.push(root.btDevices[i]);
        return out;
    }
    function batteryOf(d) {
        if (!d || d.battery === undefined || d.battery === null || d.battery <= 0)
            return -1;
        var b = d.battery;
        if (b <= 1)
            b = b * 100;
        return Math.round(b);
    }
    readonly property var btPick: {
        var first = null;
        for (var i = 0; i < root.btConnected.length; i++) {
            var d = root.btConnected[i];
            if (!first)
                first = d;
            if (root.batteryOf(d) >= 0)
                return d;
        }
        return first;
    }
    readonly property string btName: btPick ? (btPick.deviceName || btPick.name || "Bluetooth device") : ""
    readonly property int btBat: btPick ? root.batteryOf(btPick) : -1
    readonly property color btBatColor: root.btBat >= 50 ? Theme.cream : root.btBat >= 20 ? Theme.dim : Theme.vermDeep
    readonly property string btGlyph: {
        var icon = btPick ? (btPick.icon || "") : "";
        var n = btName.toLowerCase();
        switch (icon) {
        case "audio-headset":
        case "audio-headphones":
        case "audio-headset-mic":
            return "headphones";
        case "audio-card":
            return "speaker";
        case "audio-input-mic":
            return "mic";
        case "phone":
            return "phone";
        case "watch":
            return "watch";
        case "computer":
        case "laptop":
            return "computer";
        case "input-keyboard":
            return "keyboard";
        case "input-mouse":
        case "input-tablet":
            return "mouse";
        case "input-gaming":
            return "gamepad";
        case "tv":
            return "tv";
        case "printer":
        case "scanner":
        case "multifunction-printer":
            return "printer";
        case "camera-video":
        case "camera-photo":
            return "camera";
        }
        if (n.indexOf("earbud") >= 0 || n.indexOf("buds") >= 0 || n.indexOf("headphone") >= 0 || n.indexOf("headset") >= 0)
            return "headphones";
        if (n.indexOf("phone") >= 0 || n.indexOf("mobile") >= 0)
            return "phone";
        if (n.indexOf("watch") >= 0)
            return "watch";
        if (n.indexOf("keyboard") >= 0)
            return "keyboard";
        if (n.indexOf("mouse") >= 0)
            return "mouse";
        if (n.indexOf("speaker") >= 0)
            return "speaker";
        return "bluetooth";
    }

    /**
     * Art only decodes while this monitor's surface is open, keyed on the track
     * so a browser reusing one file path still reloads on a new song.
     */
    readonly property string coverSource: {
        if (!root.active)
            return "";
        var u = Players.artUrl;
        if (u)
            return u.indexOf("file:") === 0 ? u + "#" + Players.trackKey : u;
        return Players.appIconFor(root.player);
    }
    property bool everReady: false
    onCoverSourceChanged: if (coverSource.length === 0) everReady = false

    readonly property real lengthSec: Players.lengthSec
    readonly property real positionSec: hasPlayer ? player.position : 0
    readonly property real playFrac: lengthSec > 0 ? Math.max(0, Math.min(1, positionSec / lengthSec)) : 0
    property real dragFrac: 0
    property bool dragging: false
    readonly property real frac: dragging ? dragFrac : playFrac

    /** Source picker is open; only reachable when more than one player runs. */
    property bool picking: false
    readonly property bool canPick: Players.pickable.length > 1
    onCanPickChanged: if (!canPick) picking = false
    onPickingChanged: if (picking) pickFlick.contentX = 0

    /** Card geometry tokens, all scaled to the monitor. */
    readonly property real pad: 12 * s
    readonly property real artMargin: 16 * s
    readonly property real railInset: 16 * s
    readonly property real railW: 112 * s

    /** Diameter of the centered circular media card. */
    readonly property real discD: Math.min(180 * root.s, Math.min(width - 2 * root.artMargin, height - 110 * root.s))

    property real sealPulse: 0

    readonly property point seamHead: {
        void root.width;
        void root.height;
        void root.frac;
        void stroke.x;
        void stroke.width;
        return stroke.mapToItem(root, stroke.headX, stroke.headY);
    }
    readonly property real seamHeadX: seamHead.x
    readonly property real seamHeadY: seamHead.y

    ameForm: "seam"
    amePoint: Qt.point(seamHeadX, seamHeadY)

    function fmt(sec) {
        if (!(sec > 0))
            return "0:00";
        var t = Math.floor(sec);
        var m = Math.floor(t / 60);
        var ss = t % 60;
        return m + ":" + (ss < 10 ? "0" + ss : ss);
    }

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1);
    }

    onTitleChanged: if (playing && active) pulseAnim.restart()

    Timer {
        interval: 500
        running: root.active && root.playing
        repeat: true
        onTriggered: if (root.player) root.player.positionChanged();
    }

    Process {
        id: netProc
        command: ["sh", "-c", "awk 'NR>2{gsub(\":\",\" \");if($1!=\"lo\"){rx+=$2;tx+=$10}}END{print \"NET\",rx+0,tx+0}' /proc/net/dev; for i in /sys/class/net/wl*/; do [ -d \"$i\" ] && [ \"$(cat \"$i/operstate\")\" = up ] && { echo WIFI up; exit 0; }; done; echo WIFI down"]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split(/\s+/);
                if (p.length < 3 || p[0] !== "NET")
                    return;
                var rx = parseFloat(p[1]);
                var tx = parseFloat(p[2]);
                var now = Date.now();
                var dt = (now - root.netPrevTime) / 1000;
                if (root.netPrevTime > 0 && dt > 0) {
                    root.netDown = Math.max(0, (rx - root.netPrevRx) / dt / 1048576);
                    root.netUp = Math.max(0, (tx - root.netPrevTx) / dt / 1048576);
                }
                root.netPrevRx = rx;
                root.netPrevTx = tx;
                root.netPrevTime = now;
                root.netOk = p.indexOf("WIFI") >= 0 && p[p.indexOf("WIFI") + 1] === "up";
            }
        }
    }

    Timer {
        interval: 1000
        running: root.settled
        repeat: true
        onTriggered: if (!netProc.running) netProc.running = true
    }
    onActiveChanged: {
        if (!active) {
            picking = false;
            netProc.running = false;
        }
    }
    onSettledChanged: {
        if (settled) {
            if (!netProc.running)
                netProc.running = true;
        }
    }

    SequentialAnimation {
        id: pulseAnim
        NumberAnimation { target: root; property: "sealPulse"; to: 1; duration: Motion.fast; easing.type: Motion.easeStandard }
        NumberAnimation { target: root; property: "sealPulse"; to: 0; duration: Motion.standard; easing.type: Motion.easeStandard }
    }

component ArtDot: Rectangle {
    id: dot
    property string url: ""
    clip: true
    width: 10 * root.s
    height: 10 * root.s
    radius: width / 2
    color: Theme.tileBg
    Image {
        anchors.fill: parent
        source: dot.url
        sourceSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: status === Image.Ready
    }
    }
    LiquidGlass {
        id: card
        anchors.fill: parent
        radius: 20 * root.s
        topLeftRadius: radius * (1 - root.topFlat)
        topRightRadius: radius * (1 - root.topFlat)

        themeBackgroundFill: true
        style: "clear"
        legacyOpacity: 1
        accent: 0.08
        veil: 0.08
        borderColor: Theme.frameBorder
    }

    Column {
        id: discCol
        anchors.left: parent.left
        anchors.right: infoStack.left
        anchors.rightMargin: 14 * root.s
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.pad
        spacing: 10 * root.s

        // Source pill badge row / player picker
        Item {
            id: srcHeader
            width: discCol.width
            height: root.picking ? 22 * root.s : 18 * root.s
            Behavior on height { NumberAnimation { duration: Motion.fast } }

            Item {
                id: infoRow
                anchors.fill: parent
                visible: opacity > 0.01
                opacity: root.picking ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    id: srcBadge
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: 18 * root.s
                    width: Math.min(parent.width, badgeRow.width + 14 * root.s)
                    radius: height / 2
                    color: Qt.alpha(Theme.accent, 0.12)
                    border.width: 1
                    border.color: Qt.alpha(Theme.accent, 0.28)

                    Row {
                        id: badgeRow
                        anchors.centerIn: parent
                        spacing: 5 * root.s

                        ArtDot {
                            visible: root.canPick
                            anchors.verticalCenter: parent.verticalCenter
                            url: Players.artUrlFor(root.player)
                        }

                        GlyphIcon {
                            visible: !root.canPick
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10 * root.s
                            height: 10 * root.s
                            name: "music"
                            color: Theme.accent
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.serviceLabel.length > 0 ? root.serviceLabel : "Media"
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 9 * root.s
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        GlyphIcon {
                            visible: root.canPick
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8 * root.s
                            height: 8 * root.s
                            name: "chevron-down"
                            color: Theme.accent
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: root.canPick
                        hoverEnabled: true
                        cursorShape: root.canPick ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: root.picking = true
                    }
                }
            }

            // Multi-player picker
            Flickable {
                id: pickFlick
                anchors.fill: parent
                clip: true
                visible: opacity > 0.01
                opacity: root.picking ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                contentWidth: pickRow.width
                contentHeight: height
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds

                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (e) => {
                        var step = e.angleDelta.y !== 0 ? e.angleDelta.y : e.angleDelta.x;
                        var max = Math.max(0, pickFlick.contentWidth - pickFlick.width);
                        pickFlick.contentX = Math.max(0, Math.min(max, pickFlick.contentX - step));
                    }
                }

                Row {
                    id: pickRow
                    height: pickFlick.height
                    spacing: 6 * root.s

                    Repeater {
                        model: root.picking ? Players.pickable : []
                        delegate: Rectangle {
                            id: bub
                            required property var modelData
                            readonly property bool isActive: modelData === Players.active
                            anchors.verticalCenter: parent.verticalCenter
                            height: 20 * root.s
                            width: bubInner.width + 12 * root.s
                            radius: 6 * root.s
                            color: isActive ? Qt.alpha(Theme.accent, 0.22) : Qt.alpha(Theme.cream, 0.06)
                            border.width: 1
                            border.color: isActive ? Theme.accent : Qt.alpha(Theme.cream, 0.12)

                            Row {
                                id: bubInner
                                anchors.centerIn: parent
                                spacing: 4 * root.s
                                ArtDot {
                                    anchors.verticalCenter: parent.verticalCenter
                                    url: Players.artUrlFor(bub.modelData)
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Players.labelOf(bub.modelData)
                                    color: bub.isActive ? Theme.bright : Theme.dim
                                    font.family: Theme.font
                                    font.pixelSize: 9 * root.s
                                    font.weight: Font.DemiBold
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Players.select(bub.modelData);
                                    root.picking = false;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Track Title: Bold, crisp typography (Theme.bright, 15px)
        Item {
            width: discCol.width
            height: 19 * root.s

            Marquee {
                id: titleLbl
                anchors.fill: parent
                text: root.title
                color: Theme.bright
                pixelSize: 15 * root.s
                weight: Font.Bold
                active: root.active
            }
        }

        // Artist & Album: Subtly muted in Theme.dim (12px)
        Item {
            width: discCol.width
            height: 15 * root.s
            visible: root.sub.length > 0

            Marquee {
                id: subLbl
                anchors.fill: parent
                text: root.sub
                color: Theme.dim
                pixelSize: 12 * root.s
                weight: Font.Medium
                active: root.active
            }
        }

        // Seek progress bar: sleek 4px track with accent fill, draggable head, tabular time
        Item {
            id: seekRow
            width: discCol.width
            height: 16 * root.s

            Text {
                id: posLbl
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.fmt(root.dragging ? root.dragFrac * root.lengthSec : root.positionSec)
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 9 * root.s
                font.features: { "tnum": 1 }
            }

            Text {
                id: durLbl
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.live ? "LIVE" : root.fmt(root.lengthSec)
                color: Theme.dim
                font.family: Theme.font
                font.pixelSize: 9 * root.s
                font.features: { "tnum": 1 }
            }

            Item {
                id: stroke
                anchors.left: posLbl.right
                anchors.leftMargin: 8 * root.s
                anchors.right: durLbl.left
                anchors.rightMargin: 8 * root.s
                anchors.verticalCenter: parent.verticalCenter
                height: 14 * root.s

                property real targetF: root.frac
                property real lastFrac: 0
                property real drawF: targetF

                readonly property real headX: trackBg.x + drawF * trackBg.width
                readonly property real headY: trackBg.y + trackBg.height / 2

                Behavior on drawF {
                    enabled: Math.abs(root.frac - stroke.lastFrac) < 0.02
                    NumberAnimation { duration: Math.round(500 * Motion.mult); easing.type: Easing.Linear }
                }
                onTargetFChanged: Qt.callLater(() => { stroke.lastFrac = root.frac; })

                // Track groove background
                Rectangle {
                    id: trackBg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: 4 * root.s
                    radius: height / 2
                    color: Qt.alpha(Theme.cream, 0.12)

                    // Track active accent fill
                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Math.max(0, Math.min(parent.width, parent.width * stroke.drawF))
                        radius: parent.radius
                        color: Theme.accent
                    }
                }

                // Draggable seek head (soul-bead docking target)
                Rectangle {
                    id: seekThumb
                    anchors.verticalCenter: trackBg.verticalCenter
                    x: stroke.headX - width / 2
                    width: (seekArea.containsMouse || root.dragging ? 9 : 7) * root.s
                    height: width
                    radius: width / 2
                    color: Theme.bright
                    border.width: 1.5
                    border.color: Theme.accent
                    Behavior on width { NumberAnimation { duration: Motion.fast } }
                }

                MouseArea {
                    id: seekArea
                    anchors.fill: parent
                    anchors.margins: -5 * root.s
                    enabled: Boolean(root.hasPlayer && root.player && root.player.canSeek && root.player.positionSupported && root.lengthSec > 0 && !root.live)
                    cursorShape: Qt.PointingHandCursor
                    function fracAt(mx) {
                        return Math.max(0, Math.min(1, (mx - trackBg.x) / trackBg.width));
                    }
                    onPressed: (e) => {
                        root.dragFrac = fracAt(e.x);
                        root.dragging = true;
                    }
                    onPositionChanged: (e) => { if (pressed) root.dragFrac = fracAt(e.x); }
                    onReleased: {
                        if (root.player)
                            root.player.position = root.dragFrac * root.lengthSec;
                        root.dragging = false;
                    }
                }
            }
        }

        // Transport controls row: -10s, prev, Play/Pause (36x36), next, +10s, loop
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8 * root.s
            height: 36 * root.s

            // Seek -10s micro-chip
            Item {
                id: r10Btn
                anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                height: 22 * root.s
                opacity: (root.hasPlayer && root.player && root.player.canSeek && root.lengthSec > 0 && !root.live) ? 1.0 : 0.4
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: r10Mouse.containsMouse ? Qt.alpha(Theme.cream, 0.1) : Qt.alpha(Theme.cream, 0.04)
                    border.width: 1
                    border.color: r10Mouse.containsMouse ? Qt.alpha(Theme.cream, 0.2) : Qt.alpha(Theme.cream, 0.08)
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 2 * root.s

                        GlyphIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10 * root.s
                            height: 10 * root.s
                            name: "rotate-ccw"
                            color: r10Mouse.containsMouse ? Theme.bright : Theme.dim
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "10"
                            font.family: Theme.font
                            font.pixelSize: 8 * root.s
                            font.weight: Font.Bold
                            font.features: { "tnum": 1 }
                            color: r10Mouse.containsMouse ? Theme.bright : Theme.dim
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }
                    }
                }

                MouseArea {
                    id: r10Mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: Boolean(root.hasPlayer && root.player && root.player.canSeek && root.lengthSec > 0 && !root.live)
                    onClicked: if (root.player) root.player.position = Math.max(0, (root.player.position || 0) - 10)
                }
            }

            // Previous button
            Item {
                id: prevBtn
                anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                height: 28 * root.s
                opacity: Boolean(root.hasPlayer && root.player && root.player.canGoPrevious) ? 1.0 : 0.4
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: prevMouse.containsMouse ? Qt.alpha(Theme.cream, 0.1) : "transparent"
                    border.width: 1
                    border.color: prevMouse.containsMouse ? Qt.alpha(Theme.cream, 0.16) : "transparent"
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    GlyphIcon {
                        anchors.centerIn: parent
                        width: 14 * root.s
                        height: 14 * root.s
                        name: "prev"
                        color: prevMouse.containsMouse ? Theme.bright : Theme.cream
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                    }
                }

                MouseArea {
                    id: prevMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: Boolean(root.hasPlayer && root.player && root.player.canGoPrevious)
                    onClicked: if (root.player) root.player.previous()
                }
            }

            // Center Play/Pause button: prominent 36x36px circular button
            Rectangle {
                id: playBtn
                anchors.verticalCenter: parent.verticalCenter
                width: 36 * root.s
                height: 36 * root.s
                radius: width / 2
                scale: playMouse.pressed ? 0.94 : (playMouse.containsMouse ? 1.05 : 1.0)
                Behavior on scale { NumberAnimation { duration: Motion.fast; easing.type: Easing.OutBack } }

                color: playMouse.containsMouse ? Theme.vermLit : Theme.accent
                Behavior on color { ColorAnimation { duration: Motion.fast } }

                border.width: 1
                border.color: Qt.alpha(Theme.bright, 0.28)

                GlyphIcon {
                    anchors.centerIn: parent
                    width: 16 * root.s
                    height: 16 * root.s
                    name: root.playing ? "pause" : "play"
                    color: Theme.bright
                }

                MouseArea {
                    id: playMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: Boolean(root.hasPlayer && root.player && root.player.canTogglePlaying)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.player) root.player.togglePlaying()
                }
            }

            // Next button
            Item {
                id: nextBtn
                anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                height: 28 * root.s
                opacity: Boolean(root.hasPlayer && root.player && root.player.canGoNext) ? 1.0 : 0.4
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: nextMouse.containsMouse ? Qt.alpha(Theme.cream, 0.1) : "transparent"
                    border.width: 1
                    border.color: nextMouse.containsMouse ? Qt.alpha(Theme.cream, 0.16) : "transparent"
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    GlyphIcon {
                        anchors.centerIn: parent
                        width: 14 * root.s
                        height: 14 * root.s
                        name: "next"
                        color: nextMouse.containsMouse ? Theme.bright : Theme.cream
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                    }
                }

                MouseArea {
                    id: nextMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: Boolean(root.hasPlayer && root.player && root.player.canGoNext)
                    onClicked: if (root.player) root.player.next()
                }
            }

            // Seek +10s micro-chip
            Item {
                id: f10Btn
                anchors.verticalCenter: parent.verticalCenter
                width: 28 * root.s
                height: 22 * root.s
                opacity: (root.hasPlayer && root.player && root.player.canSeek && root.lengthSec > 0 && !root.live) ? 1.0 : 0.4
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: f10Mouse.containsMouse ? Qt.alpha(Theme.cream, 0.1) : Qt.alpha(Theme.cream, 0.04)
                    border.width: 1
                    border.color: f10Mouse.containsMouse ? Qt.alpha(Theme.cream, 0.2) : Qt.alpha(Theme.cream, 0.08)
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 2 * root.s

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "10"
                            font.family: Theme.font
                            font.pixelSize: 8 * root.s
                            font.weight: Font.Bold
                            font.features: { "tnum": 1 }
                            color: f10Mouse.containsMouse ? Theme.bright : Theme.dim
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }

                        GlyphIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10 * root.s
                            height: 10 * root.s
                            name: "rotate-cw"
                            color: f10Mouse.containsMouse ? Theme.bright : Theme.dim
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }
                    }
                }

                MouseArea {
                    id: f10Mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: Boolean(root.hasPlayer && root.player && root.player.canSeek && root.lengthSec > 0 && !root.live)
                    onClicked: if (root.player) root.player.position = Math.min(root.lengthSec, (root.player.position || 0) + 10)
                }
            }

            // Loop chip toggle
            Item {
                id: loopBtn
                anchors.verticalCenter: parent.verticalCenter
                width: 22 * root.s
                height: 22 * root.s
                visible: root.loopOk
                opacity: root.loopNone ? 0.45 : 1.0
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                Rectangle {
                    anchors.fill: parent
                    radius: 5 * root.s
                    color: loopArea.containsMouse ? Qt.alpha(Theme.cream, 0.1) : (root.loopNone ? "transparent" : Qt.alpha(Theme.accent, 0.16))
                    border.width: 1
                    border.color: loopArea.containsMouse ? Theme.frameBorder : (root.loopNone ? "transparent" : Theme.accent)
                }

                GlyphIcon {
                    anchors.centerIn: parent
                    width: 11 * root.s
                    height: 11 * root.s
                    name: "refresh"
                    color: root.loopNone ? Theme.dim : Theme.accent
                    Behavior on color { ColorAnimation { duration: Motion.fast } }
                }

                Rectangle {
                    id: oneBadge
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: -2 * root.s
                    anchors.rightMargin: -2 * root.s
                    width: 5 * root.s
                    height: 5 * root.s
                    radius: width / 2
                    color: Theme.accent
                    visible: root.loopTrack
                }

                MouseArea {
                    id: loopArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.nextLoop()
                }
            }
        }
    }

    /**
     * Right Column: Utility & Volume Rail.
     * Connected Bluetooth device badge or compact muted chip, sleek horizontal
     * volume slider with speaker mute toggle, and expand button.
     */
    Item {
        id: infoStack
        anchors.right: parent.right
        anchors.rightMargin: root.railInset
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: root.railW
        height: infoCol.height

        Column {
            id: infoCol
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 8 * root.s

            // Bluetooth / device status badge or compact muted chip
            Rectangle {
                width: infoStack.width
                height: 22 * root.s
                radius: 6 * root.s
                color: root.btPick ? Qt.alpha(Theme.cream, 0.06) : Qt.alpha(Theme.cream, 0.03)
                border.width: 1
                border.color: root.btPick ? Qt.alpha(Theme.cream, 0.12) : Qt.alpha(Theme.cream, 0.06)

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: 6 * root.s
                    anchors.rightMargin: 6 * root.s
                    spacing: 5 * root.s

                    GlyphIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12 * root.s
                        height: 12 * root.s
                        name: root.btPick ? root.btGlyph : "bluetooth"
                        color: root.btPick ? Theme.accent : Theme.faint
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width - 12 * root.s - 5 * root.s - (root.btBat >= 0 ? 24 * root.s : 0) - (root.btPick ? 0 : 16 * root.s))
                        text: root.btPick ? root.btName : "No device"
                        elide: Text.ElideRight
                        color: root.btPick ? Theme.bright : Theme.faint
                        font.family: Theme.font
                        font.pixelSize: 9.5 * root.s
                        font.features: { "tnum": 1 }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.btBat >= 0
                        width: 24 * root.s
                        text: root.btBat >= 0 ? root.btBat + "%" : ""
                        horizontalAlignment: Text.AlignRight
                        color: root.btBatColor
                        font.family: Theme.font
                        font.pixelSize: 9 * root.s
                        font.weight: Font.Bold
                        font.features: { "tnum": 1 }
                    }

                    // Compact wifi indicator when Bluetooth is idle
                    GlyphIcon {
                        visible: !root.btPick
                        anchors.verticalCenter: parent.verticalCenter
                        width: 11 * root.s
                        height: 11 * root.s
                        name: "wifi"
                        color: root.netOk ? Theme.iconDim : Theme.faint
                    }
                }
            }

            // Volume fader: sleek horizontal slider with mute toggle & tabular digits
            Row {
                width: infoStack.width
                height: 18 * root.s
                spacing: 5 * root.s

                GlyphIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 13 * root.s
                    height: 13 * root.s
                    name: (root.player && root.player.volume === 0) ? "speaker-off" : "speaker"
                    color: volMouse.containsMouse ? Theme.cream : Theme.iconDim
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4 * root.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.player && root.player.volume !== undefined)
                                root.player.volume = root.player.volume > 0 ? 0 : 0.5;
                        }
                    }
                }

                Rectangle {
                    id: volTrack
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, parent.width - 13 * root.s - 5 * root.s - 26 * root.s - 5 * root.s)
                    height: 4 * root.s
                    radius: height / 2
                    color: Qt.alpha(Theme.cream, 0.12)

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * Math.max(0, Math.min(1, (root.player && root.player.volume !== undefined) ? root.player.volume : 0))
                        radius: parent.radius
                        color: volMouse.containsMouse ? Theme.vermLit : Theme.accent
                        Behavior on color { ColorAnimation { duration: Motion.fast } }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        x: Math.max(0, Math.min(volTrack.width - width, volTrack.width * Math.max(0, Math.min(1, (root.player && root.player.volume !== undefined) ? root.player.volume : 0)) - width / 2))
                        width: 6 * root.s
                        height: 6 * root.s
                        radius: width / 2
                        color: Theme.bright
                        visible: volMouse.containsMouse
                    }

                    MouseArea {
                        id: volMouse
                        anchors.fill: parent
                        anchors.margins: -6 * root.s
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPositionChanged: (e) => {
                            if (pressed && root.player && root.player.volume !== undefined) {
                                var frac = Math.max(0, Math.min(1, (e.x - 6 * root.s) / volTrack.width));
                                root.player.volume = frac;
                            }
                        }
                        onPressed: (e) => {
                            if (root.player && root.player.volume !== undefined) {
                                var frac = Math.max(0, Math.min(1, (e.x - 6 * root.s) / volTrack.width));
                                root.player.volume = frac;
                            }
                        }
                        onWheel: (wheel) => {
                            if (root.player && root.player.volume !== undefined) {
                                var delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05;
                                root.player.volume = Math.max(0.0, Math.min(1.0, root.player.volume + delta));
                            }
                        }
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 26 * root.s
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(((root.player && root.player.volume !== undefined) ? root.player.volume : 0) * 100) + "%"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 9.5 * root.s
                    font.features: { "tnum": 1 }
                }
            }

            // Expand control: explicit scaled height 15 * root.s, no polish loop
            Item {
                id: expandCtl
                height: 15 * root.s
                width: infoStack.width

                Rectangle {
                    anchors.centerIn: parent
                    width: 64 * root.s
                    height: 15 * root.s
                    radius: 4 * root.s
                    color: expandMouse.containsMouse ? Qt.alpha(Theme.cream, 0.1) : Qt.alpha(Theme.cream, 0.04)
                    border.width: 1
                    border.color: expandMouse.containsMouse ? Qt.alpha(Theme.cream, 0.2) : Qt.alpha(Theme.cream, 0.08)
                    Behavior on color { ColorAnimation { duration: Motion.fast } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 4 * root.s

                        GlyphIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 10 * root.s
                            height: 10 * root.s
                            name: "layers"
                            color: expandMouse.containsMouse ? Theme.bright : Theme.dim
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Expand"
                            color: expandMouse.containsMouse ? Theme.bright : Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 9 * root.s
                            font.weight: Font.Medium
                            Behavior on color { ColorAnimation { duration: Motion.fast } }
                        }
                    }

                    MouseArea {
                        id: expandMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (mouse) => {
                            mouse.accepted = true;
                            root.requestExpand();
                        }
                    }
                }
            }
        }
    }
}
