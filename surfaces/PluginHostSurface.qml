pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"

/**
 * PLUGIN surface: hosts a bar-widget plugin's own QML in the morphing pill,
 * so clicking a plugin entry expands the bar into the plugin content exactly
 * the way a native cell expands into its surface.
 *
 * Where the calendar and wifi surfaces are shapes written for this shell, this
 * one is generic: it loads whatever `barWidget` entry point the plugin ships
 * (the same file PluginButton mounts into the strip cell) at full size, injects
 * the same host contract it expects (`bar`, `settings`, `moduleName`), and
 * reports the content's implicit size back so the pill morphs to fit. The
 * widget's own `open()` (PanelController/IPC path) is never driven here — the
 * content IS the panel, shown in-window — so nothing floats on a second window.
 *
 * Panel-root entries report 0x0 until they lay out, so the host falls back to
 * the default dimensions when the content has no size to offer yet. Content
 * taller than `maxH` scrolls inside the surface rather than stretching the pill
 * over the whole monitor.
 */
PillSurface {
    id: root

    required property string pluginId
    property real barHeightOverride: -1
    property bool panelWasOpened: false
    readonly property bool popupActive: !!(widget.item && ("opened" in widget.item) && widget.item.opened)

    onOpenChanged: {
        if (!open && root.panelWasOpened && widget.item && widget.item.opened)
            widget.item.close();
    }

    mTop: 14
    mLeft: 16
    mRight: 16
    mBottom: 14

    readonly property string defaultEntry: Plugins.barEntryFor(root.pluginId)

    /**
     * What to host in here. The default is the plugin's strip barWidget; a
     * right-click on the cell passes the settings surface instead, which the
     * pill resolves for the plugin. Falling back to the bar widget on a bad
     * source keeps one unmpt plugin manifest from collapsing the cell.
     */
    property string entryPoint: defaultEntry

    readonly property var plugin: Plugins.byId(root.pluginId)

    /**
     * The JSON snapshot the plugin's own service writes and the stock
     * BarWidget polls — the replacement bar has no shared object with the
     * Omarchy host for the service, so this is the only channel the live
     * state reaches our panel through. Declared per id; absent plugins
     * simply leave `serviceState` empty (enough, e.g. audio pulls its
     * state straight from Pipewire).
     */
    readonly property string serviceStateFile: (root.pluginId === "pix.recast")
        ? ((Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/px-gsr/state.json")
        : ""

    Process {
        id: stateRead
        running: false
        command: ["true"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var target = widget.item;
                if (!target || !("serviceState" in target))
                    return;
                try {
                    var parsed = JSON.parse(String(text || "").trim() || "{}");
                    if (parsed && typeof parsed === "object")
                        target.serviceState = parsed;
                } catch (e) {}
            }
        }
    }

     Timer {
        id: stateTimer
        interval: 1000
        repeat: true
        running: root.serviceStateFile.length > 0
        onTriggered: {
            var target = widget.item;
            if (!target || !("serviceState" in target))
                return;
            stateRead.command = ["cat", root.serviceStateFile];
            stateRead.running = true;
        }
    }

    readonly property real maxW: 560 * s
    readonly property real maxH: 600 * s
    readonly property real defaultW: 340 * s
    readonly property real defaultH: 360 * s

    /**
     * The widget's size as reported after it has laid out, or the defaults
     * while it still reports nothing (panel roots read 0x0 until their data
     * lands). Measured imperatively in `onLoaded`, not live-bound, because
     * every label in the loaded panel sizes itself against the width it is
     * given — binding this back to the loader's size and the loader's
     * implicit is a circular reference. This drives both the morph size and
     * the scroll content, so a live plugin gets a pill wrapped around it,
     * and a still-loading one still gets a pill that does not collapse.
     */
    property real measuredW: 0
    property real measuredH: 0
    readonly property real contentW: Math.min(maxW, Math.max(defaultW, measuredW > 0 ? measuredW : defaultW))
    readonly property real contentH: Math.min(maxH, Math.max(defaultH, measuredH > 0 ? measuredH : defaultH))

    implicitWidth: contentW
    implicitHeight: contentH
    ameForm: "off"

    /**
     * The host contract, standing in for the bar the host can no longer show.
     * Sized to the surface body so a widget that drives its panel from the bar
     * overrides (a popup positioned under "the bar") lays out against the
     * actual room it is given rather than the 17*s strip cell.
     */
    PluginBarStub {
        id: barStub
        moduleId: root.pluginId
        barHeightOverride: root.barHeightOverride > 0 ? root.barHeightOverride : root.height
        barWidthOverride: root.width
        barSize: Math.round(26 * root.s)
    }

    Flickable {
        id: view
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: widget.width
        contentHeight: widget.height
        rightMargin: 4 * root.s
        bottomMargin: 4 * root.s

        Loader {
            id: widget
            active: true
            source: root.entryPoint || root.defaultEntry
            width: Math.max(view.width, root.contentW)
            height: Math.max(view.height, root.contentH)
            opacity: root.popupActive ? 0 : 1
            onStatusChanged: {
                if (widget.status === Loader.Error && root.entryPoint !== root.defaultEntry && root.defaultEntry.length > 0)
                    widget.source = root.defaultEntry;
            }
            onLoaded: root.inject()
        }
    }

    Connections {
        target: widget.item
        ignoreUnknownSignals: true
        function onOpenedChanged() { root.panelOpenedChanged(); }
    }

    function panelOpenedChanged() {
        var item = widget.item;
        if (!item || !("opened" in item))
            return;
        if (item.opened) {
            root.panelWasOpened = true;
            return;
        }
        if (root.panelWasOpened) {
            root.panelWasOpened = false;
            if (root.open)
                root.requestClose();
        }
    }

    function inject() {
        root.panelWasOpened = false;
        var target = widget.item;
        if (!target)
            return;
        // Mirrors BarWidget.injectPanel: when the mounted file is the plugin's
        // own settings panel it needs the same contract the bar widget gives it.
        if ("bar" in target)
            target.bar = barStub;
        if ("moduleName" in target && !target.moduleName)
            target.moduleName = root.pluginId;
        if ("settings" in target)
            target.settings = Plugins.settingsFor(root.pluginId);
        if ("anchorItem" in target)
            target.anchorItem = root;
        if ("hostWidget" in target)
            target.hostWidget = null;
        if ("serviceState" in target && !target.serviceState)
            target.serviceState = ({});

        // Click-grace: the click that expands the pill into a plugin panel is
        // the same click whose release lands in the panel's dismissal area
        // (KeyboardPanel.dismissArea), so the panel would auto-close instantly.
        // Defer the open() call to the next event-loop tick so the click
        // release is consumed first and cannot dismiss the panel.
        Qt.callLater(function() {
            var item = widget.item;
            if (item && typeof item.open === "function")
                item.open();
            root.measuredW = item && item.implicitWidth > 0 ? item.implicitWidth : 0;
            root.measuredH = item && item.implicitHeight > 0 ? item.implicitHeight : 0;
        });

        // Panels a plugin mounts from a bar button are inert until their
        // controller's open state is real: audio renders no rows, recast no
        // sliders. The popout contract reports opened through the item step to
        // show its content in whichever window hosts it -- this surface is
        // that window -- so drive the same open a click would.
        // open() and size measurement are deferred via Qt.callLater above
        // to dodge the same-click-dismiss race.
    }
}