pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import "../Singletons"

/**
 * System tray. Draws StatusNotifier items as warm-tinted icons. Left-click
 * activates (preferring the resolved desktop entry), middle-click does the
 * secondary action, right-click opens the item's native menu in a floating
 * washi card, wheel scrolls the item. The menu gets its own overlay window so
 * it can grab keyboard focus for dismissal.
 */
Item {
    id: tray

    property real s: 1
    property var barWindow
    /** The widget's own shell.json entry, when a host injects one. */
    property var settings: null

    /**
     * Item ids the user chose to hide, and where that choice is kept.
     *
     * Persisted to the widget's own shell.json entry rather than kept in
     * memory: the symptom this exists for is an icon that outlives its app --
     * a Steam tray item that stays registered after the client exits, or an app
     * that registers once and never unregisters. With no way to hide it, the
     * dead icon sits there permanently, and clicking it does nothing. That
     * reads as "opening apps from the tray is broken" when in fact one icon is
     * a ghost. Omarchy's own tray carries the same hide list for the same
     * reason.
     *
     * `bar.shell.updateEntryInline` is the stock facade for this and writes
     * `pinned`/`hidden` onto the widget's own entry, one key per process; the
     * two arrays are small, so this is not a hot path.
     */
    property var hiddenIds: {
        if (settings && settings.hidden instanceof Array)
            return settings.hidden.slice();
        return readHiddenFile();
    }

    /** Written through the widget entry, with a file fallback for a host that has no facade. */
    property string hiddenPath: (Quickshell.env("XDG_STATE_HOME")
        || (Quickshell.env("HOME") + "/.local/state")) + "/better/tray-hidden.json"

    function readHiddenFile() {
        if (!hiddenFile.loaded)
            hiddenFile.reload();
        try {
            var parsed = JSON.parse(String(hiddenFile.text() || "[]").trim());
            return parsed instanceof Array ? parsed : [];
        } catch (e) {
            return [];
        }
    }

    /**
     * Write the hide list.
     *
     * The widget-entry facade is the stock route, used when the host provides
     * it. When it does not -- a standalone bar with no Omarchy shell behind it --
     * the list is written to XDG_STATE_HOME instead, so the choice survives a
     * restart either way rather than being silently dropped. Both writes are
     * best effort: losing the preference is not worth failing the hide.
     */
    function persistHidden(next) {
        tray.hiddenIds = next;
        var bar = tray.barWindow && tray.barWindow.bar;
        if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") {
            bar.shell.updateEntryInline("pix.bar", { id: "pix.bar", hidden: next });
        }
        hiddenFile.setText(JSON.stringify(next));
    }

    FileView {
        id: hiddenFile
        path: tray.hiddenPath
        watchChanges: false
        printErrors: false
    }

    function isHidden(iid) {
        return tray.hiddenIds.indexOf(String(iid || "")) !== -1;
    }

    function toggleHide(iid) {
        var id = String(iid || "");
        if (!id)
            return;
        var next = tray.hiddenIds.slice();
        var at = next.indexOf(id);
        if (at !== -1)
            next.splice(at, 1);
        else
            next.push(id);
        tray.persistHidden(next);
    }

    /**
     * An item with no identity left is a ghost: no icon and no title means there
     * is nothing to click and nothing to name in the manage list, so it is
     * dropped rather than drawn as an empty box that looks like a live app.
     */
    function isDead(it) {
        if (!it)
            return true;
        return !(it.id || it.title || it.tooltipTitle || it.icon);
    }

    /**
     * StatusNotifier items shown in the tray. nm-applet and blueman are hidden:
     * the pill draws its own wifi and bluetooth module icons with dedicated
     * surfaces, so their tray icons would only duplicate the same status.
     * Matching runs across id, title and tooltip so applet renames stay covered.
     * User-hidden ids and identity-less ghosts are dropped here, once, rather
     * than in every reader.
     */
    readonly property var trayItems: SystemTray.items.values.filter(function (it) {
        if (tray.isDead(it))
            return false;
        if (tray.isHidden(it.id))
            return false;
        var key = ((it.id || "") + " " + (it.title || "") + " " + (it.tooltipTitle || "")).toLowerCase();
        return !/(nm[ _-]?applet|blueman|network[- ]?manager|bluetooth[- ]?manager)/.test(key);
    })

    /**
     * Every item, hidden ones included, for the manage list. A hidden item that
     * cannot be listed cannot be un-hidden either, so the manage list is built
     * from the unfiltered set -- which is also why a ghost is left out: there is
     * no id to persist, so hiding one would never be reversible.
     */
    function manageRows() {
        var values = SystemTray.items.values;
        var out = [];
        for (var i = 0; i < values.length; i++) {
            var it = values[i];
            if (tray.isDead(it))
                continue;
            if (tray.suppressedByBar(it))
                continue;
            out.push({
                id: String(it.id || it.title || ""),
                label: it.tooltipTitle || it.title || it.id,
                hidden: tray.isHidden(it.id)
            });
        }
        return out;
    }

    /** The applets the bar already draws itself, so manage does not offer them. */
    function suppressedByBar(it) {
        var key = ((it.id || "") + " " + (it.title || "") + " " + (it.tooltipTitle || "")).toLowerCase();
        return /(nm[ _-]?applet|blueman|network[- ]?manager|bluetooth[- ]?manager)/.test(key);
    }

    function showManage(anchorItem) {
        manageOpen = true;
        var p = anchorItem.mapToItem(null, anchorItem.width / 2, 0);
        manage.anchorX = p.x;
    }

    property bool manageOpen: false

    visible: tray.trayItems.length > 0 || tray.manageOpen
    implicitWidth: visible ? row.implicitWidth + (tray.manageOpen ? 0 : 0) : 0
    implicitHeight: 24 * tray.s

    function showMenu(item, anchorItem) {
        if (!item.hasMenu)
            return;
        card.expandedIdx = -1;
        opener.menu = item.menu;
        var p = anchorItem.mapToItem(null, anchorItem.width / 2, 0);
        menu.anchorX = p.x;
        menu.open = true;
    }

    /**
     * One open menu's rows, with the holes taken out.
     *
     * `children.values` is a snapshot of an ObjectList, and a tray app that
     * re-registers its menu — or drops one while this card is open — repopulates
     * that list underneath the read, so the snapshot can come back with a null in
     * it. Every MenuRow reads `entryData` unconditionally across a dozen
     * properties, so a single hole threw a TypeError per property per row and
     * still left a blank line where the entry should be. Dropping the nulls here
     * fixes that once at the boundary, instead of guarding twelve reads, and the
     * row it would have drawn is a row that no longer exists.
     */
    function menuRows(menuOpener) {
        if (!menuOpener || !menuOpener.children)
            return [];
        var values = menuOpener.children.values;
        var out = [];
        for (var i = 0; i < values.length; i++) {
            if (values[i])
                out.push(values[i]);
        }
        return out;
    }

    QsMenuOpener {
        id: opener
    }

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: 2 * tray.s

        Repeater {
            model: tray.trayItems

            delegate: Item {
                id: slot

                required property var modelData

                Layout.preferredWidth: 24 * tray.s
                Layout.preferredHeight: 24 * tray.s

                Rectangle {
                    anchors.fill: parent
                    radius: 6 * tray.s
                    color: Theme.frameBg
                    border.width: 1
                    border.color: Theme.frameBorder
                    opacity: area.containsMouse ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: Motion.fast } }
                }

                Image {
                    anchors.centerIn: parent
                    source: slot.modelData.icon
                    sourceSize.width: 32
                    sourceSize.height: 32
                    width: 16 * tray.s
                    height: 16 * tray.s
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    cache: true
                    asynchronous: true
                }

                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    onClicked: (mouse) => {
                        if (mouse.button === Qt.MiddleButton) {
                            slot.modelData.secondaryActivate();
                        } else if (mouse.button === Qt.RightButton) {
                            tray.showMenu(slot.modelData, slot);
                        } else if (slot.modelData.onlyMenu) {
                            tray.showMenu(slot.modelData, slot);
                        } else {
                            slot.modelData.activate();
                        }
                    }
                    onWheel: (wheel) => {
                        slot.modelData.scroll(wheel.angleDelta.y, false);
                    }
                }

                Tooltip {
                    s: tray.s
                    placement: "below"
                    title: slot.modelData.tooltipTitle || slot.modelData.title || slot.modelData.id
                    show: area.containsMouse && !menu.open
                }
            }
        }
    }

    /**
     * One menu line: separator, or a row with optional checkbox/radio state,
     * icon, label and a submenu chevron that rotates when expanded. Used for
     * both top-level entries and indented submenu children.
     */
    component MenuRow: Item {
        id: mrow

        /**
         * Defaults to an empty entry, never null.
         *
         * `menuRows()` drops the holes a torn-down `ObjectList` leaves behind,
         * but a tray app can also drop an entry between that snapshot and the
         * delegate being created, and the delegate's own `modelData` is then
         * null. Every row below reads `entryData` unconditionally across a dozen
         * properties, so that one hole threw a TypeError per property per row
         * and still drew a blank line where an entry used to be. Defaulting here
         * contains it at the boundary instead of guarding every read.
         */
        property var entryData: ({})
        /** True for a torn-down entry, so the row can hide itself instead of
         *  drawing a line of defaults for an app that is no longer there. */
        readonly property bool gone: entryData === null
        property real indent: 0
        property bool expanded: false
        signal activated()

        // A torn-down entry collapses to nothing. `entryData` is explicitly assigned
        // `modelData`, and a Repeater delegate whose model dropped the entry can
        // still be holding the last value while a re-evaluation reads it as null
        // -- which is what turned every read below into a TypeError. Collapsing
        // on it costs nothing: the row it would have drawn no longer exists.
        height: mrow.gone ? 0 : (entryData.isSeparator ? 9 * tray.s : 32 * tray.s)

        Rectangle {
            visible: !mrow.gone && mrow.entryData.isSeparator
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8 * tray.s + mrow.indent
            anchors.rightMargin: 8 * tray.s
            height: 1
            color: Theme.hair
        }

        Rectangle {
            visible: !mrow.gone && !mrow.entryData.isSeparator
            anchors.fill: parent
            anchors.leftMargin: mrow.indent
            radius: 8 * tray.s
            color: mrowArea.containsMouse && mrow.entryData.enabled
                ? Theme.frameBg : "transparent"

            Rectangle {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 6 * tray.s
                width: 2 * tray.s
                height: parent.height * 0.46
                radius: width / 2
                color: Theme.vermLit
                opacity: mrowArea.containsMouse && mrow.entryData.enabled ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Motion.fast } }
            }

            Rectangle {
                id: stateBox
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 16 * tray.s
                readonly property bool isCheck: mrow.entryData.buttonType === QsMenuButtonType.CheckBox
                readonly property bool isRadio: mrow.entryData.buttonType === QsMenuButtonType.RadioButton
                readonly property bool present: isCheck || isRadio
                readonly property bool checked: mrow.entryData.checkState === Qt.Checked
                visible: present
                width: present ? 11 * tray.s : 0
                height: 11 * tray.s
                radius: isRadio ? width / 2 : 3 * tray.s
                color: "transparent"
                border.width: 1
                border.color: checked ? Theme.vermLit : Theme.border

                Rectangle {
                    anchors.centerIn: parent
                    visible: stateBox.checked
                    width: 5 * tray.s
                    height: 5 * tray.s
                    radius: stateBox.isRadio ? width / 2 : 1.5 * tray.s
                    color: Theme.vermLit
                }
            }

            Image {
                id: entryIcon
                anchors.left: stateBox.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: stateBox.present ? 8 * tray.s : 0
                width: mrow.gone || !mrow.entryData.icon ? 0 : 15 * tray.s
                height: 15 * tray.s
                source: mrow.gone ? "" : mrow.entryData.icon
                sourceSize.width: 30
                sourceSize.height: 30
                fillMode: Image.PreserveAspectFit
                smooth: true
                cache: true
                visible: !mrow.gone && !!mrow.entryData.icon
            }

            Text {
                anchors.left: entryIcon.right
                anchors.leftMargin: (!mrow.gone && mrow.entryData.icon) ? 9 * tray.s : 0
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: chevron.visible ? chevron.left : parent.right
                anchors.rightMargin: 14 * tray.s
                text: mrow.entryData.text
                color: !mrow.entryData.enabled ? Theme.dim
                    : (mrowArea.containsMouse ? Theme.cream : Theme.creamMenu)
                font.family: Theme.font
                font.pixelSize: 13 * tray.s
                font.weight: mrowArea.containsMouse ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }

            GlyphIcon {
                id: chevron
                anchors.right: parent.right
                anchors.rightMargin: 10 * tray.s
                anchors.verticalCenter: parent.verticalCenter
                visible: !mrow.gone && mrow.entryData.hasChildren === true
                width: 10 * tray.s
                height: 10 * tray.s
                name: "chevron-right"
                color: mrow.expanded ? Theme.vermLit : Theme.iconDim
                stroke: 2
                rotation: mrow.expanded ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: Motion.fast } }
            }

            MouseArea {
                id: mrowArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !mrow.gone && mrow.entryData.enabled
                cursorShape: Qt.PointingHandCursor
                onClicked: mrow.activated()
            }
        }
    }

    PanelWindow {
        id: menu

        property bool open: false
        property real anchorX: 0

        onOpenChanged: {
            if (!open) {
                card.expandedIdx = -1;
                opener.menu = null;
            }
        }

        screen: tray.barWindow ? tray.barWindow.screen : null
        visible: open
        color: "transparent"

        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "better-tray"

        anchors { top: true; left: true; right: true; bottom: true }

        MouseArea {
            anchors.fill: parent
            onClicked: menu.open = false
        }

        FocusScope {
            anchors.fill: parent
            focus: menu.open

            Keys.onEscapePressed: menu.open = false

            Rectangle {
                id: card

                x: Math.max(8 * tray.s, Math.min(menu.anchorX - width / 2, menu.width - width - 8 * tray.s))
                y: 50 * tray.s
                width: 220 * tray.s
                radius: 12 * tray.s
                clip: true

                /** Screen height this window reports, for the card's cap. */
                readonly property real screenH: menu.height
                readonly property real maxCardH: Math.max(80 * tray.s, screenH - y - 8 * tray.s)

                gradient: Gradient {
                    GradientStop { position: 0.0; color: Theme.cardTop }
                    GradientStop { position: 1.0; color: Theme.cardBot }
                }
                border.width: 1
                border.color: Theme.border

                property int expandedIdx: -1

                implicitHeight: Math.min(col.implicitHeight + 12 * tray.s, card.maxCardH)
                height: implicitHeight

                Rectangle {
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: 1
                    anchors.leftMargin: 10 * tray.s
                    anchors.rightMargin: 10 * tray.s
                    height: 1
                    color: Theme.sheen
                }

                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: Theme.shadow
                    shadowBlur: 0.9
                    shadowVerticalOffset: 4 * tray.s
                }

                MouseArea { anchors.fill: parent }

                Flickable {
                    id: trayFlick
                    anchors.fill: parent
                    contentWidth: width
                    contentHeight: col.implicitHeight + 12 * tray.s
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true
                    Column {
                        id: col
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6 * tray.s
                        spacing: 0

                        Repeater {
                            model: tray.menuRows(opener)

                            delegate: Column {
                                id: entry

                                required property var modelData
                                required property int index
                                readonly property bool expanded: card.expandedIdx === index

                                width: col.width

                                MenuRow {
                                    width: parent.width
                                    entryData: entry.modelData
                                    expanded: entry.expanded
                                    onActivated: {
                                        if (entry.modelData.hasChildren) {
                                            card.expandedIdx = entry.expanded ? -1 : entry.index;
                                        } else {
                                            entry.modelData.triggered();
                                            menu.open = false;
                                        }
                                    }
                                }

                                QsMenuOpener {
                                    id: childOpener
                                    menu: entry.expanded ? entry.modelData : null
                                }

                                Repeater {
                                    model: tray.menuRows(childOpener)

                                    delegate: MenuRow {
                                        required property var modelData
                                        width: entry.width
                                        indent: 14 * tray.s
                                        entryData: modelData
                                        onActivated: {
                                            if (!modelData.hasChildren) {
                                                modelData.triggered();
                                                menu.open = false;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
