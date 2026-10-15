pragma ComponentBehavior: Bound

import QtQuick
import "../Singletons"

/**
 * The SCREENS canvas: one card per screen, laid out on the reflowed grid.
 *
 * The arrangement itself is not this file's decision. It reads
 * `Screens.layout`, which recomputes the footprints whenever the draft changes,
 * so a scale or rotation edit moves its neighbours here as a consequence rather
 * than as a second step that has to be kept in sync.
 *
 * The focused card is the lit one; every other desaturates toward the icon
 * colour, and a disabled screen draws as a dashed outline at no fill, so "off"
 * reads as absent from the arrangement without removing the card. Workspace
 * chips reuse the Workspaces component's dot vocabulary -- a stick for the
 * active workspace, a dot otherwise.
 *
 * Clicking a card picks it; arranging is the arrow keys' job, so there is no
 * drag here.
 */
Rectangle {
    id: canvas

    property real s: 1
    property var draft: []
    property int focusIndex: -1

    signal focusPicked(int index)

    readonly property var boxes: Screens.refit(draft)

    readonly property real spanX: {
        var n = 0;
        for (var i = 0; i < boxes.length; i++)
            n = Math.max(n, boxes[i].x + boxes[i].ew);
        return n;
    }

    readonly property real spanY: {
        var n = 0;
        for (var i = 0; i < boxes.length; i++)
            n = Math.max(n, boxes[i].y + boxes[i].eh);
        return n;
    }

    /** Shrink to fit the width we were given, and never past 1:1. */
    readonly property real fit: {
        var w = canvas.width - 8 * s;
        var h = 170 * s;
        var fx = canvas.spanX > 0 ? w / canvas.spanX : 1;
        var fy = canvas.spanY > 0 ? h / canvas.spanY : 1;
        var f = Math.min(fx, fy, 1);
        return f > 0 ? f : 1;
    }

    function indexOfName(name) {
        for (var i = 0; i < canvas.draft.length; i++) {
            if ((canvas.draft[i].name || "") === (name || ""))
                return i;
        }
        return -1;
    }

    function isFocused(name) {
        if (canvas.focusIndex < 0 || canvas.focusIndex >= canvas.draft.length)
            return false;
        return ((canvas.draft[canvas.focusIndex].name || "") === (name || ""));
    }

    width: parent ? parent.width : 0
    height: Math.max(2 * s, canvas.spanY * canvas.fit) + 8 * s
    color: Theme.tileBg
    radius: 12 * s

    Repeater {
        model: canvas.boxes

        delegate: Rectangle {
            required property var modelData

            readonly property int cardIndex: canvas.indexOfName(modelData.name)

            readonly property var screenInfo: cardIndex >= 0 ? canvas.draft[cardIndex] : null
            readonly property bool isFocus: canvas.isFocused(modelData.name)
            readonly property bool isOff: screenInfo ? !screenInfo.enabled : false

            x: modelData.x * canvas.fit
            y: modelData.y * canvas.fit
            width: Math.max(3 * s, modelData.ew * canvas.fit)
            height: Math.max(3 * s, modelData.eh * canvas.fit)

            radius: 8 * s
            color: isFocus ? Theme.cream : Theme.iconDim
            opacity: isOff ? 0 : (isFocus ? 1 : 0.55)
            border.width: isOff ? 1 : 0
            border.color: Theme.iconDim

            Behavior on opacity {
                NumberAnimation { duration: Motion.fast; easing.type: Motion.easeStandard }
            }

            Text {
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.topMargin: 5 * s
                anchors.leftMargin: 6 * s
                text: modelData.name || ""
                color: isFocus ? Theme.tileBg : Theme.cream
                font.family: Theme.font
                font.pixelSize: 11 * s
                font.weight: Font.DemiBold
            }

            Text {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 5 * s
                anchors.rightMargin: 6 * s
                text: (Math.round((screenInfo ? screenInfo.scale : 1) * 100) / 100).toString()
                color: isFocus ? Theme.tileBg : Theme.cream
                font.family: Theme.font
                font.pixelSize: 8 * s
            }

            Text {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.bottomMargin: 5 * s
                anchors.leftMargin: 6 * s
                text: modelData.width + "x" + modelData.height
                color: isFocus ? Theme.tileBg : Theme.cream
                font.family: Theme.font
                font.pixelSize: 8 * s
            }

            Row {
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                anchors.bottomMargin: 5 * s
                anchors.rightMargin: 6 * s
                spacing: 4 * s

                Repeater {
                    model: screenInfo ? (screenInfo.workspaces || []) : []

                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool chipActive: !!screenInfo
                            && screenInfo.activeWsName !== ""
                            && screenInfo.activeWsName !== undefined
                            && String(modelData.name) === String(screenInfo.activeWsName)

                        Behavior on width {
                            NumberAnimation { duration: Motion.glide; easing.type: Motion.easeStandard }
                        }
                        width: chipActive ? 17 * s : 5 * s
                        height: 5 * s
                        radius: height / 2
                        color: chipActive ? Theme.vermLit : Theme.cream
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: (mouse) => {
            // The canvas is a target, not a drag surface: arrangement is the
            // arrow keys' work, so a click's only job is to pick a screen.
            var px = (mouse.x) / Math.max(0.001, canvas.fit);
            var py = (mouse.y) / Math.max(0.001, canvas.fit);
            var boxes = canvas.boxes;
            for (var i = 0; i < boxes.length; i++) {
                var b = boxes[i];
                if (px >= b.x && px <= b.x + b.ew && py >= b.y && py <= b.y + b.eh) {
                    canvas.focusPicked(canvas.indexOfName(b.name));
                    return;
                }
            }
        }
    }
}
