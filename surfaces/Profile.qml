pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import "../Singletons"
import "../components"

/**
 * PROFILE sub-surface: user identity, avatar customization, and live system specs.
 *
 * Reached from the pill's distro mark or hover row, and folds back to the
 * resting pill on back chevron or empty click.
 *
 * Features:
 *   - Avatar with auto-detection (~/.face*) and persistent override (Flags.profileAvatar)
 *   - Interactive avatar customizer:
 *       * Native image-picker summoning (omarchy.image-picker over ~/Pictures)
 *       * Quick-pick carousel from ~/Pictures
 *       * Direct path input with validation
 *       * Reset-to-default button syncing to ~/.face
 *   - Full-width Processor and Graphics specifications without truncation
 *   - Memory and Disk gauge cards with real-time percentage progress meters
 *   - Distro, Kernel, Host, Uptime, Packages, Shell and Compositor badges
 */
SettingsSurface {
    id: root

    backSurface: ""
    implicitHeight: content.implicitHeight

    // Purely informational -- no rows for the keyboard cursor to walk.
    rows: []

    // ── Avatar & Image Settings ──────────────────────────────────────────

    property string detectedFace: ""
    readonly property string faceFile: {
        if (Flags.profileAvatar && Flags.profileAvatar.length > 0)
            return root.expandPath(Flags.profileAvatar);
        if (root.detectedFace.length > 0)
            return root.detectedFace;
        return "";
    }

    function expandPath(p) {
        if (!p || p === "")
            return "";
        if (p === "~")
            return Quickshell.env("HOME") || "";
        if (p.indexOf("~/") === 0)
            return (Quickshell.env("HOME") || "") + p.slice(1);
        return p;
    }

    Process {
        id: faceProc
        running: true
        command: ["sh", "-c", "for f in \"$HOME/.face\" \"$HOME/.face.icon\" \"$HOME/.face.png\" \"$HOME/.face.jpg\"; do if [ -f \"$f\" ]; then echo \"$f\"; break; fi; done"]
        stdout: SplitParser { onRead: (line) => root.detectedFace = line.trim() }
    }

    function setAvatar(path) {
        if (!path) return;
        var p = root.expandPath(path.trim());
        Flags.profileAvatar = p;
        syncFaceProc.command = ["bash", "-c", "cp -f " + JSON.stringify(p) + " \"$HOME/.face\" 2>/dev/null; cp -f " + JSON.stringify(p) + " \"$HOME/.face.icon\" 2>/dev/null || true"];
        syncFaceProc.running = true;
    }

    function resetAvatar() {
        Flags.profileAvatar = "";
        syncFaceProc.command = ["bash", "-c", "rm -f \"$HOME/.face\" \"$HOME/.face.icon\" 2>/dev/null || true"];
        syncFaceProc.running = true;
        faceProc.running = true;
    }

    Process {
        id: syncFaceProc
        running: false
    }

    property bool settingsOpen: false

    readonly property string selectionPath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better/avatar-selection"
    readonly property string donePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/better/avatar-done"

    function openImagePicker() {
        pickerPrepProc.command = ["bash", "-c", "mkdir -p \"$(dirname \"" + root.selectionPath + "\")\" && : > \"" + root.selectionPath + "\" && : > \"" + root.donePath + "\""];
        pickerPrepProc.running = true;
    }

    Process {
        id: pickerPrepProc
        running: false
        onExited: {
            var payload = JSON.stringify({
                imageDirs: Quickshell.env("HOME") + "/Pictures",
                selectionFile: root.selectionPath,
                doneFile: root.donePath,
                showLabels: true,
                filterable: true
            });
            summonProc.command = ["omarchy-shell", "shell", "summon", "omarchy.image-picker", payload];
            summonProc.running = true;
        }
    }

    Process { id: summonProc; running: false }

    FileView {
        id: selectionWatcher
        path: "file://" + root.selectionPath
        watchChanges: true
        printErrors: false
        onFileChanged: root.checkSelectedAvatar()
        onLoaded: root.checkSelectedAvatar()
    }

    function checkSelectedAvatar() {
        var txt = String(selectionWatcher.text() || "").trim();
        if (txt.length > 0 && txt !== Flags.profileAvatar) {
            root.setAvatar(txt);
        }
    }

    property var recentPictures: []
    Process {
        id: scanPicsProc
        running: true
        command: ["bash", "-c", "find \"$HOME/Pictures\" -maxdepth 2 -type f \\( -iname \"*.png\" -o -iname \"*.jpg\" -o -iname \"*.jpeg\" -o -iname \"*.webp\" \\) 2>/dev/null | head -n 8"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var lines = String(text || "").trim().split("\n").filter(function(l) { return l.length > 0; });
                root.recentPictures = lines;
            }
        }
    }

    // ── Live system facts ──────────────────────────────────────────────

    property string distro: ""
    property string distroId: ""
    FileView {
        id: osRelease
        path: "file:///etc/os-release"
        printErrors: false
        onLoaded: {
            const t = osRelease.text();
            let name = "", id = "";
            const lines = t.split("\n");
            for (const line of lines) {
                if (line.indexOf("PRETTY_NAME=") === 0)
                    name = line.slice(12).replace(/^"|"$/g, "");
                else if (line.indexOf("NAME=") === 0 && name === "")
                    id = line.slice(5).replace(/^"|"$/g, "");
                else if (line.indexOf("ID=") === 0)
                    root.distroId = line.slice(3).replace(/^"|"$/g, "").toLowerCase();
            }
            root.distro = name !== "" ? name : id;
        }
    }

    readonly property var distroGlyphs: ({
        "omarchy": 0xf303, "cachyos": 0xf385, "arch": 0xf303, "ubuntu": 0xf31b, "debian": 0xf306,
        "fedora": 0xf30a, "nixos": 0xf313, "manjaro": 0xf312, "garuda": 0xf337,
        "void": 0xf32e, "kali": 0xf327, "linuxmint": 0xf30e, "elementary": 0xf309,
        "solus": 0xf32d, "parrot": 0xf329, "slackware": 0xf318, "gentoo": 0xf30d,
        "centos": 0xf304, "alpine": 0xf300, "mx": 0xf33f, "pop": 0xf32a,
        "zorin": 0xf32f, "opensuse-tumbleweed": 0xf37d, "tumbleweed": 0xf37d,
        "opensuse-leap": 0xf37e, "leap": 0xf37e, "opensuse": 0xf314
    })
    readonly property string distroGlyph: String.fromCodePoint(
        root.distroGlyphs[root.distroId] !== undefined ? root.distroGlyphs[root.distroId] : 0xf303)

    property string hostName: ""
    FileView {
        id: etcHostname
        path: "file:///etc/hostname"
        printErrors: false
        onLoaded: root.hostName = etcHostname.text().trim()
    }

    property string kernel: ""
    Process {
        running: true
        command: ["uname", "-r"]
        stdout: SplitParser { onRead: (line) => root.kernel = line.trim() }
    }

    readonly property string shellName: {
        const sh = Quickshell.env("SHELL") || "";
        const i = sh.lastIndexOf("/");
        return i >= 0 ? sh.slice(i + 1) : sh;
    }
    readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
    readonly property string wmName: Quickshell.env("XDG_CURRENT_DESKTOP") || (Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") ? "Hyprland" : "")

    property string gpuRaw: ""
    Process {
        running: true
        command: ["sh", "-c", "lspci 2>/dev/null | grep -iE 'VGA|3D controller|Display controller' | head -n 1"]
        stdout: SplitParser { onRead: (line) => root.gpuRaw = line.trim() }
    }

    readonly property string gpu: {
        let t = root.gpuRaw.replace(/^[0-9a-fA-F:.]+\s+.*?:\s*/, "");
        t = t.replace(/^(Advanced Micro Devices,?\s*Inc\.?(\s*\[AMD\/ATI\])?|NVIDIA Corporation|Intel Corporation)\s*/i, "");
        t = t.replace(/\s*\(rev\s+[^)]*\)\s*$/i, "");
        return t.trim();
    }

    property real uptimeSec: 0
    FileView {
        id: procUptime
        path: "file:///proc/uptime"
        printErrors: false
        onLoaded: {
            const v = parseFloat(procUptime.text().split(" ")[0]);
            if (!isNaN(v))
                root.uptimeSec = v;
        }
    }
    readonly property string uptime: {
        let s = Math.floor(root.uptimeSec);
        const d = Math.floor(s / 86400); s -= d * 86400;
        const h = Math.floor(s / 3600);  s -= h * 3600;
        const m = Math.floor(s / 60);
        if (d > 0) return d + "d " + h + "h";
        if (h > 0) return h + "h " + m + "m";
        return m + "m";
    }

    property string pkgCount: ""
    Process {
        running: true
        command: ["sh", "-c", "if command -v pacman >/dev/null; then pacman -Q | wc -l; elif command -v dpkg-query >/dev/null; then dpkg-query -f '${binary:Package}\\n' -W | wc -l; elif command -v rpm >/dev/null; then rpm -qa | wc -l; fi"]
        stdout: SplitParser { onRead: (line) => root.pkgCount = line.trim() }
    }

    property string cpu: ""
    FileView {
        id: procCpuinfo
        path: "file:///proc/cpuinfo"
        printErrors: false
        onLoaded: {
            const txt = procCpuinfo.text();
            const m = txt.match(/model name\s*:\s*(.+)/);
            if (!m) return;
            let name = m[1].trim();
            name = name.replace(/^(AMD|Intel|Apple|AuthenticAMD)\s+/i, "");
            name = name.replace(/\s+with\s+.*(Graphics|graphics)$/i, "");
            name = name.replace(/\s+CPU\s+/i, " ");
            const cores = (txt.match(/^processor\s*:/gm) || []).length;
            root.cpu = name + (cores > 0 ? " (" + cores + ")" : "");
        }
    }

    property string memUsed: ""
    property real memPct: 0
    FileView {
        id: procMeminfo
        path: "file:///proc/meminfo"
        printErrors: false
        onLoaded: {
            const t = procMeminfo.text();
            const m1 = t.match(/MemTotal:\s+(\d+)/);
            const m2 = t.match(/MemAvailable:\s+(\d+)/);
            if (m1 && m2) {
                const total = parseInt(m1[1], 10);
                const avail = parseInt(m2[1], 10);
                if (total > 0) {
                    root.memPct = Math.max(0, Math.min(1, (total - avail) / total));
                    root.memUsed = ((total - avail) / 1048576).toFixed(1) + " / " + (total / 1048576).toFixed(1) + " GiB";
                }
            }
        }
    }

    property string diskUsed: ""
    property real diskPct: 0
    Process {
        running: true
        command: ["sh", "-c", "df -B1 / | awk 'NR==2 {printf \"%.1f / %.1f GiB\\t%.2f\", $3/1073741824, $2/1073741824, $3/$2}'"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var parts = String(text || "").trim().split("\t");
                if (parts.length > 0) root.diskUsed = parts[0];
                if (parts.length > 1) root.diskPct = Math.max(0, Math.min(1, parseFloat(parts[1]) || 0));
            }
        }
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 12 * root.s

        SettingsHeader {
            s: root.s
            title: "PROFILE"
            showBack: true
        }

        // ── HERO CARD ────────────────────────────────────────────────────────
        Item {
            anchors.left: parent.left
            anchors.leftMargin: 18 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 18 * root.s
            implicitHeight: Math.max(avatarContainer.height, heroInfoCol.implicitHeight)

            // Avatar with camera badge and interactive click
            Item {
                id: avatarContainer
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 78 * root.s
                height: 78 * root.s

                Rectangle {
                    id: avatarCircle
                    anchors.fill: parent
                    radius: width / 2
                    color: Theme.frameBg
                    border.width: 2 * root.s
                    border.color: Theme.accent
                    clip: true

                    Image {
                        id: faceImg
                        anchors.fill: parent
                        source: root.faceFile !== "" ? "file://" + root.faceFile : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: status === Image.Ready
                        sourceSize: Qt.size(160 * root.s, 160 * root.s)
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: !faceImg.visible
                        text: "\uf007"
                        color: Theme.dim
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 30 * root.s
                    }

                    // Hover overlay
                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(0, 0, 0, 0.6)
                        opacity: avatarMouse.containsMouse ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: Motion.fast } }

                        Column {
                            anchors.centerIn: parent
                            spacing: 2 * root.s
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "\uf030"
                                color: Theme.bright
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 15 * root.s
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "EDIT"
                                color: Theme.bright
                                font.family: Theme.font
                                font.pixelSize: 8 * root.s
                                font.weight: Font.Bold
                            }
                        }
                    }
                }

                // Camera pill badge
                Rectangle {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: -2 * root.s
                    width: 22 * root.s
                    height: 22 * root.s
                    radius: 11 * root.s
                    color: Theme.accent
                    border.width: 1.5 * root.s
                    border.color: Theme.cardBot

                    Text {
                        anchors.centerIn: parent
                        text: "\uf030"
                        color: Theme.bright
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 10 * root.s
                    }
                }

                MouseArea {
                    id: avatarMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.settingsOpen = !root.settingsOpen
                }

                Tooltip {
                    s: root.s
                    placement: "below"
                    title: "Profile Picture"
                    desc: "Click to change avatar photo"
                    show: avatarMouse.containsMouse
                }
            }

            // User Info Column
            Column {
                id: heroInfoCol
                anchors.left: avatarContainer.right
                anchors.leftMargin: 18 * root.s
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5 * root.s

                Text {
                    text: root.userName !== "" ? root.userName : "User"
                    color: Theme.bright
                    font.family: Theme.font
                    font.pixelSize: 18 * root.s
                    font.weight: Font.Bold
                    elide: Text.ElideRight
                    width: parent.width
                }

                Row {
                    spacing: 8 * root.s

                    // Distro Badge
                    Rectangle {
                        height: 20 * root.s
                        width: distroRow.implicitWidth + 12 * root.s
                        radius: 5 * root.s
                        color: Qt.alpha(Theme.accent, 0.12)
                        border.width: 1
                        border.color: Qt.alpha(Theme.accent, 0.28)

                        Row {
                            id: distroRow
                            anchors.centerIn: parent
                            spacing: 5 * root.s
                            Text {
                                text: root.distroGlyph
                                color: Theme.accent
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 12 * root.s
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: root.distro !== "" ? root.distro : "Linux"
                                color: Theme.cream
                                font.family: Theme.font
                                font.pixelSize: 10.5 * root.s
                                font.weight: Font.SemiBold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    // Host Badge
                    Rectangle {
                        height: 20 * root.s
                        width: hostRow.implicitWidth + 12 * root.s
                        radius: 5 * root.s
                        color: Theme.frameBg
                        border.width: 1
                        border.color: Theme.hair

                        Row {
                            id: hostRow
                            anchors.centerIn: parent
                            spacing: 4 * root.s
                            Text {
                                text: "@"
                                color: Theme.dim
                                font.family: Theme.font
                                font.pixelSize: 10.5 * root.s
                                font.weight: Font.Bold
                            }
                            Text {
                                text: root.hostName !== "" ? root.hostName : "localhost"
                                color: Theme.subtle
                                font.family: Theme.font
                                font.pixelSize: 10.5 * root.s
                                font.weight: Font.Medium
                            }
                        }
                    }
                }

                Row {
                    spacing: 12 * root.s

                    Text {
                        text: "up " + root.uptime
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: 11 * root.s
                    }
                    Text {
                        text: "·"
                        color: Theme.hair
                        font.pixelSize: 11 * root.s
                    }
                    Text {
                        text: root.wmName + " · " + root.shellName
                        color: Theme.dim
                        font.family: Theme.font
                        font.pixelSize: 11 * root.s
                    }
                }

                // Action links
                Row {
                    spacing: 10 * root.s

                    Rectangle {
                        height: 22 * root.s
                        width: changePicText.implicitWidth + 16 * root.s
                        radius: 5 * root.s
                        color: changePicMouse.containsMouse ? Qt.alpha(Theme.accent, 0.18) : Qt.alpha(Theme.accent, 0.08)
                        border.width: 1
                        border.color: Qt.alpha(Theme.accent, 0.35)

                        Row {
                            anchors.centerIn: parent
                            spacing: 5 * root.s
                            Text {
                                text: "\uf030"
                                color: Theme.accent
                                font.family: "JetBrainsMono Nerd Font"
                                font.pixelSize: 10 * root.s
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                id: changePicText
                                text: root.settingsOpen ? "Close Picker" : "Change Picture"
                                color: Theme.cream
                                font.family: Theme.font
                                font.pixelSize: 10 * root.s
                                font.weight: Font.SemiBold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        MouseArea {
                            id: changePicMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.settingsOpen = !root.settingsOpen
                        }
                    }

                    Rectangle {
                        visible: Flags.profileAvatar.length > 0
                        height: 22 * root.s
                        width: resetPicText.implicitWidth + 14 * root.s
                        radius: 5 * root.s
                        color: resetPicMouse.containsMouse ? Qt.alpha(Theme.verm, 0.18) : Theme.frameBg
                        border.width: 1
                        border.color: resetPicMouse.containsMouse ? Theme.verm : Theme.hair

                        Text {
                            id: resetPicText
                            anchors.centerIn: parent
                            text: "Reset"
                            color: resetPicMouse.containsMouse ? Theme.vermLit : Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.Medium
                        }

                        MouseArea {
                            id: resetPicMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.resetAvatar()
                        }
                    }
                }
            }
        }

        // ── AVATAR SETTINGS DRAWER (COLLAPSIBLE) ──────────────────────────────
        Rectangle {
            anchors.left: parent.left
            anchors.leftMargin: 18 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 18 * root.s
            visible: root.settingsOpen
            radius: 8 * root.s
            color: Theme.frameBg
            border.width: 1
            border.color: Theme.hair
            implicitHeight: drawerCol.implicitHeight + 20 * root.s

            Column {
                id: drawerCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 10 * root.s
                spacing: 8 * root.s

                Row {
                    width: parent.width
                    spacing: 8 * root.s

                    Text {
                        text: "CHOOSE PROFILE PICTURE"
                        color: Theme.accent
                        font.family: Theme.font
                        font.pixelSize: 10 * root.s
                        font.weight: Font.Bold
                        font.letterSpacing: 1
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Main Image Picker Summon Button
                Rectangle {
                    width: parent.width
                    height: 30 * root.s
                    radius: 6 * root.s
                    color: pickButtonMouse.containsMouse ? Qt.alpha(Theme.accent, 0.25) : Qt.alpha(Theme.accent, 0.14)
                    border.width: 1
                    border.color: Theme.accent

                    Row {
                        anchors.centerIn: parent
                        spacing: 8 * root.s
                        Text {
                            text: "\uf07c"
                            color: Theme.accent
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "Browse with Omarchy Image Picker (Visual Grid)..."
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                            font.weight: Font.SemiBold
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        id: pickButtonMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openImagePicker()
                    }
                }

                // Quick Pick Thumbnails from ~/Pictures
                Text {
                    visible: root.recentPictures.length > 0
                    text: "Quick pick from ~/Pictures:"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 10 * root.s
                }

                Row {
                    visible: root.recentPictures.length > 0
                    spacing: 8 * root.s

                    Repeater {
                        model: root.recentPictures
                        delegate: Rectangle {
                            required property var modelData
                            width: 36 * root.s
                            height: 36 * root.s
                            radius: 18 * root.s
                            color: Theme.cardBot
                            clip: true
                            border.width: (Flags.profileAvatar === modelData) ? 2 : 1
                            border.color: (Flags.profileAvatar === modelData) ? Theme.accent : (thumbMouse.containsMouse ? Theme.cream : Theme.hair)

                            Image {
                                anchors.fill: parent
                                source: "file://" + modelData
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }

                            MouseArea {
                                id: thumbMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setAvatar(modelData)
                            }
                        }
                    }
                }

                // Manual Path Input
                Row {
                    width: parent.width
                    spacing: 8 * root.s

                    Rectangle {
                        width: parent.width - 68 * root.s
                        height: 28 * root.s
                        radius: 5 * root.s
                        color: Theme.cardBot
                        border.width: 1
                        border.color: pathInput.activeFocus ? Theme.accent : Theme.hairSoft

                        TextInput {
                            id: pathInput
                            anchors.fill: parent
                            anchors.leftMargin: 8 * root.s
                            anchors.rightMargin: 8 * root.s
                            verticalAlignment: Text.AlignVCenter
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                            clip: true
                            readOnly: true
                            selectByMouse: false
                            onActiveFocusChanged: cursorVisible = activeFocus
                            Keys.onPressed: (e) => {
                                TextEntry.handle(pathInput, e);
                                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                    if (text.trim().length > 0) root.setAvatar(text.trim());
                                    e.accepted = true;
                                }
                            }
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 8 * root.s
                            anchors.verticalCenter: parent.verticalCenter
                            text: Flags.profileAvatar.length > 0 ? Flags.profileAvatar : "Paste or type image path..."
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                            visible: pathInput.text.length === 0
                            elide: Text.ElideMiddle
                            width: parent.width - 16 * root.s
                        }
                    }

                    Rectangle {
                        width: 60 * root.s
                        height: 28 * root.s
                        radius: 5 * root.s
                        color: applyBtnMouse.containsMouse ? Theme.accent : Qt.alpha(Theme.accent, 0.2)
                        border.width: 1
                        border.color: Theme.accent

                        Text {
                            anchors.centerIn: parent
                            text: "Apply"
                            color: applyBtnMouse.containsMouse ? Theme.bright : Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 10.5 * root.s
                            font.weight: Font.SemiBold
                        }

                        MouseArea {
                            id: applyBtnMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (pathInput.text.trim().length > 0)
                                    root.setAvatar(pathInput.text.trim());
                            }
                        }
                    }
                }
            }
        }

        // ── HARDWARE SPECIFICATIONS ──────────────────────────────────────────
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 18 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 18 * root.s
            spacing: 6 * root.s

            // CPU Card
            Rectangle {
                width: parent.width
                implicitHeight: cpuRow.implicitHeight + 14 * root.s
                radius: 7 * root.s
                color: Theme.frameBg
                border.width: 1
                border.color: Theme.hair

                Row {
                    id: cpuRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 10 * root.s
                    spacing: 12 * root.s

                    Rectangle {
                        width: 30 * root.s
                        height: 30 * root.s
                        radius: 6 * root.s
                        color: Qt.alpha(Theme.accent, 0.12)
                        border.width: 1
                        border.color: Qt.alpha(Theme.accent, 0.25)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            anchors.centerIn: parent
                            text: "\uf2db"
                            color: Theme.accent
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 15 * root.s
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2 * root.s
                        width: parent.width - 42 * root.s

                        Text {
                            text: "PROCESSOR"
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 9 * root.s
                            font.weight: Font.Bold
                            font.letterSpacing: 1
                        }

                        Text {
                            text: root.cpu !== "" ? root.cpu : "—"
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 12.5 * root.s
                            font.weight: Font.SemiBold
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                }
            }

            // GPU Card
            Rectangle {
                width: parent.width
                implicitHeight: gpuRow.implicitHeight + 14 * root.s
                radius: 7 * root.s
                color: Theme.frameBg
                border.width: 1
                border.color: Theme.hair

                Row {
                    id: gpuRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 10 * root.s
                    spacing: 12 * root.s

                    Rectangle {
                        width: 30 * root.s
                        height: 30 * root.s
                        radius: 6 * root.s
                        color: Qt.alpha(Theme.accent, 0.12)
                        border.width: 1
                        border.color: Qt.alpha(Theme.accent, 0.25)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            anchors.centerIn: parent
                            text: "\uf108"
                            color: Theme.accent
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 15 * root.s
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2 * root.s
                        width: parent.width - 42 * root.s

                        Text {
                            text: "GRAPHICS"
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 9 * root.s
                            font.weight: Font.Bold
                            font.letterSpacing: 1
                        }

                        Text {
                            text: root.gpu !== "" ? root.gpu : "—"
                            color: Theme.bright
                            font.family: Theme.font
                            font.pixelSize: 12.5 * root.s
                            font.weight: Font.SemiBold
                            elide: Text.ElideRight
                            width: parent.width
                        }
                    }
                }
            }
        }

        // ── LIVE METRICS (MEMORY & DISK GAUGES) ──────────────────────────────
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 18 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 18 * root.s
            spacing: 8 * root.s

            // Memory Card
            Rectangle {
                width: (parent.width - 8 * root.s) / 2
                implicitHeight: memCol.implicitHeight + 16 * root.s
                radius: 7 * root.s
                color: Theme.frameBg
                border.width: 1
                border.color: Theme.hair

                Column {
                    id: memCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 10 * root.s
                    spacing: 5 * root.s

                    Item {
                        width: parent.width
                        height: memTitleText.implicitHeight
                        Text {
                            id: memTitleText
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "MEMORY"
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 9 * root.s
                            font.weight: Font.Bold
                            font.letterSpacing: 1
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: Math.round(root.memPct * 100) + "%"
                            color: Theme.accent
                            font.family: Theme.font
                            font.pixelSize: 10.5 * root.s
                            font.weight: Font.Bold
                        }
                    }

                    Text {
                        text: root.memUsed !== "" ? root.memUsed : "—"
                        color: Theme.bright
                        font.family: Theme.font
                        font.pixelSize: 12 * root.s
                        font.weight: Font.SemiBold
                    }

                    // Progress Bar
                    Rectangle {
                        width: parent.width
                        height: 4 * root.s
                        radius: 2 * root.s
                        color: Theme.hairSoft

                        Rectangle {
                            height: parent.height
                            radius: 2 * root.s
                            color: Theme.accent
                            width: Math.max(4 * root.s, parent.width * root.memPct)
                        }
                    }
                }
            }

            // Disk Card
            Rectangle {
                width: (parent.width - 8 * root.s) / 2
                implicitHeight: diskCol.implicitHeight + 16 * root.s
                radius: 7 * root.s
                color: Theme.frameBg
                border.width: 1
                border.color: Theme.hair

                Column {
                    id: diskCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 10 * root.s
                    spacing: 5 * root.s

                    Item {
                        width: parent.width
                        height: diskTitleText.implicitHeight
                        Text {
                            id: diskTitleText
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: "ROOT DISK"
                            color: Theme.faint
                            font.family: Theme.font
                            font.pixelSize: 9 * root.s
                            font.weight: Font.Bold
                            font.letterSpacing: 1
                        }
                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: Math.round(root.diskPct * 100) + "%"
                            color: Theme.accent
                            font.family: Theme.font
                            font.pixelSize: 10.5 * root.s
                            font.weight: Font.Bold
                        }
                    }

                    Text {
                        text: root.diskUsed !== "" ? root.diskUsed : "—"
                        color: Theme.bright
                        font.family: Theme.font
                        font.pixelSize: 12 * root.s
                        font.weight: Font.SemiBold
                    }

                    // Progress Bar
                    Rectangle {
                        width: parent.width
                        height: 4 * root.s
                        radius: 2 * root.s
                        color: Theme.hairSoft

                        Rectangle {
                            height: parent.height
                            radius: 2 * root.s
                            color: Theme.accent
                            width: Math.max(4 * root.s, parent.width * root.diskPct)
                        }
                    }
                }
            }
        }

        // ── DETAILS BADGES ──────────────────────────────────────────────────
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 18 * root.s
            anchors.right: parent.right
            anchors.rightMargin: 18 * root.s
            spacing: 6 * root.s

            Repeater {
                model: [
                    { label: "KERNEL", val: root.kernel },
                    { label: "PACKAGES", val: root.pkgCount + " pkgs" },
                    { label: "COMPOSITOR", val: root.wmName },
                    { label: "SHELL", val: root.shellName }
                ]
                delegate: Rectangle {
                    required property var modelData
                    height: 22 * root.s
                    width: (parent.width - 18 * root.s) / 4
                    radius: 5 * root.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.hairSoft

                    Row {
                        anchors.centerIn: parent
                        spacing: 4 * root.s
                        Text {
                            text: modelData.val !== "" ? modelData.val : "—"
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }

        Item { width: 1; height: 8 * root.s }
    }
}
