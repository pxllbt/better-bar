pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import "../Singletons"

/**
 * One reorderable slot in the pill's status row. Renders whatever the row's
 * resolved entry asks for: a native cell's content (a Loader over the
 * component the pill selects by id), an enabled plugin's PluginButton, or a
 * separator hairline.
 *
 * Reorder is a drag: hold the left or middle button, move, release (the
 * neighbours settle into the new order then). A left press without travel is
 * still a normal click, so every cell keeps opening its surface on click --
 * the drag only takes over once motion clears the drag threshold. A middle
 * click on a cell opens a small layout menu for it -- insert a gap before,
 * drop a gap, reset the whole strip.
 */
Item {
    id: root

    required property string kind
    required property string cellId
    required property string pluginId
    property Component cellComponent: null
    property real s: 1
    property bool hoverLive: true
    property real barHeightOverride: 0
    property real barWidthOverride: 0

    // Position in the resolved strip. Computed from the model (id + kind match)
    // rather than handed in, so the delegate never has to fight the Repeater's
    // own `index` context property, which a same-named class property shadows.
    // Read only at drag start/release, so it re-evaluating on reorder is fine.
    readonly property int index: StripLayout.resolved.findIndex(e =>
        e.kind === root.kind && e.id === root.cellId)

    // The loaded native cell root (null for separators/plugins). The pill maps
    // its soul anchors through this, because the cell ids inside the
    // Components are scoped to each component instance.
    readonly property Item nativeItem: cellLoader.item

    width: root.kind === "cell" ? cellLoader.width
         : root.kind === "sep" ? 1
         : pluginView.width
    height: root.kind === "cell" ? cellLoader.height
          : root.kind === "sep" ? 17 * root.s
          : pluginView.height

    // Whether the loaded native cell currently wants to paint. Tracked through
    // a dedicated `cellPresent` flag exposed by each cell root, NOT through
    // `cellLoader.item.visible`: QQuickLoader mirrors its own visibility onto
    // the loaded item, so gating the cell on `item.visible` just reads the
    // mirror (a hidden cell forces the item "invisible", which reads back false,
    // so the cell can never unhide -- a chicken-and-egg that pins everything
    // hidden). `cellPresent` is a plain property binding on the item side, so it
    // is immune to the mirror and stays live as the cell's state changes.
    property bool cellVisible: false
    visible: root.kind === "sep" || root.kind === "plugin"
             || (root.cellComponent !== null && root.cellVisible)
    Binding {
        target: root
        property: "cellVisible"
        value: cellLoader.item ? cellLoader.item.cellPresent : false
    }
    onHoverLiveChanged: if (!root.hoverLive) menuCard.visible = false

    // Drag is tracked over the resolved model, not over pixel offsets: the
    // target index is derived from how many cell pitches the pointer has
    // travelled, so hidden cells (a battery that is not present, an empty
    // tray) never skew the crossing.
    property int dragFrom: -1
    property int dragTo: -1
    property real step: 0

    Loader {
        id: cellLoader
        active: root.kind === "cell"
        sourceComponent: root.cellComponent
        anchors.verticalCenter: parent.verticalCenter
    }

    Rectangle {
        id: sepView
        visible: root.kind === "sep"
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: 17 * root.s
        color: Theme.hair
        opacity: 0.7
    }

    PluginButton {
        id: pluginView
        visible: root.kind === "plugin"
        anchors.verticalCenter: parent.verticalCenter
        pluginId: root.pluginId
        s: root.s
        hoverLive: root.hoverLive
        barHeightOverride: root.barHeightOverride
        barWidthOverride: root.barWidthOverride
        openSurfaceRequest: (id, settingsMode) => pill.requestPluginSurface(id, settingsMode)
    }

    DragHandler {
        id: orderDrag
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        target: null
        enabled: root.hoverLive

        onActiveChanged: {
            if (orderDrag.active) {
                root.dragFrom = root.index;
                root.dragTo = root.index;
                root.step = Math.max(1, root.width + 12 * root.s);
            } else if (root.dragFrom >= 0) {
                var from = root.dragFrom;
                var to = root.dragTo;
                var dragged = root.step;
                root.dragFrom = -1;
                root.dragTo = -1;
                if (dragged >= 0 && to >= 0 && to !== from)
                    StripLayout.move(from, to);
            }
        }

        onTranslationChanged: {
            if (!orderDrag.active || root.dragFrom < 0) return;
            var shift = Math.round(orderDrag.translation.x / root.step);
            root.dragTo = Math.max(0, Math.min(StripLayout.resolved.length - 1, root.dragFrom + shift));
        }
    }

    // A quick middle press with no travel is the layout menu, not a move. The
    // DragHandler above grabs once movement crosses its threshold, so a real
    // drag never reaches here and a tap never reorders.
    TapHandler {
        id: menuTap
        acceptedButtons: Qt.MiddleButton
        enabled: root.hoverLive
        onTapped: root.openMenu()
    }

    function openMenu() {
        const wasOpen = menuCard.visible;
        pill.closeStripMenus();
        if (wasOpen) return;
        menuCard.visible = true;
    }

    function closeMenu() {
        menuCard.visible = false;
    }

    // Layout menu: a tooltip-flavoured bubble under the cell -- same chrome as
    // the pill's info bubbles (card gradient, active ring, contrast veil,
    // soft drop shadow, pointer), but interactive. One-click affordances, no
    // submenus: insert a gap before this slot, drop the gap under the cursor
    // (separator cells only), or wipe the stored order.
    Item {
        id: menuCard
        visible: false
        z: 200
        width: bubble.width
        height: bubble.height + pointerH
        anchors.top: parent.bottom
        anchors.topMargin: 6 * root.s
        anchors.horizontalCenter: parent.horizontalCenter

        // While any card is up, the pill latches itself open and grows its
        // input mask down to cover this card, so the cursor can travel from
        // the cell into the menu without collapsing the strip.
        onVisibleChanged: pill.stripMenuOpen = menuCard.visible

        readonly property real pointerH: 5 * root.s
        property int rowH: 26 * root.s

        readonly property string title: root.kind === "sep" ? "Strip gap"
            : root.kind === "plugin" ? root.pluginId
            : ({"weather": "Weather", "tray": "Status", "dnd": "Do not disturb",
                "wifi": "Network", "bt": "Bluetooth", "battery": "Battery",
                "inbox": "Inbox", "mixer": "Sound", "sysmon": "System",
                "wallpaper": "Wallpaper", "clipboard": "Clipboard",
                "launcher": "Launcher", "appearance": "Appearance",
                "power": "Power"}[root.cellId] || root.cellId)

        Rectangle {
            id: bubble
            anchors.horizontalCenter: parent.horizontalCenter
            width: 176 * root.s
            height: myRows.implicitHeight + 10 * root.s
            radius: 9 * root.s
            border.width: 1
            border.color: Theme.border
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.omarchyBackground ? Theme.omarchyBackground : Theme.cardTop }
                GradientStop { position: 1.0; color: Theme.omarchyBackground ? Qt.darker(Theme.omarchyBackground, 1.3) : Theme.cardBot }
            }

            ActiveBorderRing {
                anchors.fill: parent
                radius: bubble.radius
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: parent.radius - 1
                color: Qt.rgba(0, 0, 0, 0.22)
            }

            ActiveBorderRing {
                anchors.fill: parent
                radius: bubble.radius
            }

            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: Qt.rgba(0, 0, 0, 0.7)
                shadowBlur: 0.7
                shadowVerticalOffset: 5 * root.s
            }

            Column {
                id: myRows
                anchors.centerIn: parent
                spacing: 1

                Rectangle {
                    width: bubble.width
                    height: menuCard.rowH
                    color: "transparent"

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 12 * root.s
                        text: menuCard.title
                        color: Theme.cream
                        font.family: Theme.font
                        font.pixelSize: 11 * root.s
                        font.weight: Font.Bold
                        opacity: 0.9
                    }
                }

                Repeater {
                    model: [
                        { label: "Insert gap before", sep: false },
                        { label: "Remove gap", sep: true },
                        { label: "Reset strip order", sep: false }
                    ]

                    delegate: Rectangle {
                        required property string label
                        required property bool sep
                        property bool hot: false
                        width: bubble.width
                        height: menuCard.rowH
                        color: "transparent"

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: 3 * root.s
                            radius: 6 * root.s
                            color: parent.hot ? Theme.sheen : "transparent"
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 9 * root.s
                            text: parent.label
                            color: Theme.cream
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                            opacity: parent.sep && root.kind !== "sep" ? 0.4 : 1
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !parent.sep || root.kind === "sep"
                            onContainsMouseChanged: parent.hot = containsMouse
                            onClicked: {
                                menuCard.visible = false;
                                if (root.kind === "sep" && parent.sep)
                                    StripLayout.removeSeparator(root.index);
                                else if (parent.label.indexOf("Insert gap") === 0)
                                    StripLayout.insertSeparator(root.index);
                                else
                                    StripLayout.reset();
                            }
                        }
                    }
                }
            }
        }

        Canvas {
            width: 11 * root.s
            height: menuCard.pointerH
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: bubble.bottom
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var c = Theme.cardBot;
                ctx.fillStyle = Qt.rgba(c.r * 0.78, c.g * 0.78, c.b * 0.78, 1);
                ctx.beginPath();
                ctx.moveTo(0, height);
                ctx.lineTo(width, height);
                ctx.lineTo(width / 2, 0);
                ctx.closePath();
                ctx.fill();
            }
        }
    }
}