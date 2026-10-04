import QtQuick
import Quickshell
import "../Singletons"

/**
 * Stand-in for the Omarchy bar, for hosting a plugin's panel inside Better Bar.
 *
 * The host shell is the only thing that can build a real bar surface, and its
 * bar is docked off-screen now that Better Bar replaced it. Panels a plugin
 * mounts from a bar button (KeyboardPanel, and any widget reading `bar.*`) are
 * therefore handed this facade instead.
 *
 * Two upstream contracts are mirrored deliberately:
 *   - qs.Ui/KeyboardPanel.qml reads `position`, `barSize`, `barForeground`,
 *     `activePopout`, `clickTargets`, `requestPopout`, `releasePopout`,
 *     `targetBelongsToWindow` and `switchPanelFrom` off `bar`, several of them
 *     unguarded, so all of them exist here.
 *   - qs.Ui/PluginBarApi.qml is the facade the host hands to third-party bar
 *     widgets, so a plugin's own BarWidget.qml finds the members it expects
 *     (vertical, foreground, tooltip/click-target registration, moduleWidgets,
 *     run, ...).
 *
 * `barHeightOverride` / `barWidthOverride` are ours: the pill renders inside a
 * full-screen overlay window, so KeyboardPanel would otherwise measure the
 * whole screen as the bar band and collapse the card. The mirrored
 * Ui/KeyboardPanel.qml honours these.
 */
QtObject {
    id: stub

    // Set by the host button before the plugin loads.
    property real barHeightOverride: -1
    property real barWidthOverride: -1
    property var shell: null
    property string fontFamily: Theme.font

    // This stub's own plugin id, so moduleWidgets() can answer the way the
    // real bar does for the widget it is hosting.
    property string moduleId: ""

    // The hosted BarWidget instance, published once the Loader resolves.
    // moduleWidgets() reports it, which is what makes BarWidget.broadcast()
    // reach this host instead of finding no peers.
    property var hostedWidget: null

    // ---- the host shell facade ------------------------------------------

    /**
     * The `shell` stock panels expect on their `bar`.
     *
     * The stock bar hands its panels a facade over the host
     * shell's IPC target, so a panel can summon another
     * plugin's panel or persist its own widget settings
     * without knowing who renders it. Better Bar is a bar,
     * not the host, so the facade forwards to the same door
     * everything else here uses: `omarchy-shell`, the running
     * Omarchy shell's IPC. On any Omarchy setup that shell is
     * the process that owns the plugins, so a stock panel
     * behaves exactly as it does under the stock bar.
     */
    QtObject {
        id: shellApi

        function summon(target, payload) {
            if (!target)
                return;
            Quickshell.execDetached([
                "omarchy-shell", "-q", "shell", "summon",
                String(target), payload || "{}"
            ]);
        }

        // The stock shell rewrites the widget's layout entry
        // with the given keys; setBarWidget writes one key per
        // call, which adds up to the same entry.
        function updateEntryInline(moduleName, entry) {
            if (!moduleName || !entry)
                return;
            for (var key in entry) {
                if (key === "id")
                    continue;
                Quickshell.execDetached([
                    "omarchy-shell", "-q", "shell", "setBarWidget",
                    String(moduleName), String(key),
                    JSON.stringify(entry[key])
                ]);
            }
        }
    }

    Component.onCompleted: shell = shellApi

    // ---- bar geometry / presentation ---------------------------------------

    property string position: "top"
    // 0 keeps the base BarWidget's `bar ? bar.barSize : default` fallbacks
    // meaningful; KeyboardPanel max()es this against its own measured band.
    property int barSize: 0
    property bool vertical: false
    property bool transparent: true
    property color background: "transparent"
    // Theme.cream is already theme-derived: Theme.qml resolves it to Omarchy's
    // foreground, then to textOverride, which sync_theme.py always writes from
    // the active theme. It is the correct source for a *foreground* — swapping
    // it for the accent would tint panel labels with the highlight colour.
    property color foreground: Theme.cream
    property color barForeground: Theme.cream
    property color urgent: Theme.verm
    property bool foregroundAnimationEnabled: true
    property bool centerSectionRevealHeld: false
    property bool centerHoverRevealSuppressed: false
    property var layoutConfig: ({})
    readonly property var foreignPopoutMarker: ({ foreign: true })

    // ---- popout coordination ------------------------------------------------

    property var activePopout: null

    /**
     * Every widget in this host that wants presses, newest last.
     *
     * Not decoration: `WidgetButton` registers itself here the moment it is given
     * a `bar` (`Ui/WidgetButton.qml`, `syncClickRegistration`), and both the real
     * bar and a hosted `KeyboardPanel` look the target up by walking this list to
     * decide what a click landed on. Left empty, every secondary click was
     * unroutable — the audio widget's right-click mutes, its middle-click opens
     * the panel, and neither could reach the handler that implements them.
     */
    property var clickTargets: []

    function registerClickTarget(target) {
        if (!target || stub.clickTargets.indexOf(target) !== -1)
            return;
        stub.clickTargets = stub.clickTargets.concat([target]);
    }

    function unregisterClickTarget(target) {
        var at = stub.clickTargets.indexOf(target);
        if (at === -1)
            return;
        var next = stub.clickTargets.slice();
        next.splice(at, 1);
        stub.clickTargets = next;
    }

    /**
     * The same eligibility test the real bar applies
     * (`Bar.qml` `moduleTargetClickable`), so a hidden or already-consumed widget
     * is not pressed on the widget's behalf.
     */
    function clickableTarget(target) {
        return !!target
            && target.visible !== false
            && target.opacity !== 0
            && target.interactive !== false
            && target.pressable !== false
            && typeof target.triggerPress === "function";
    }

    /**
     * Route a press to whichever registered widget owns it.
     *
     * Newest registration wins, matching the bar's reverse iteration: a plugin
     * that loads a second button over the first expects the front one to answer.
     * With nothing registered the caller falls back to opening the panel itself,
     * which is what a widget with no button of its own needs.
     */
    function pressAny(button) {
        for (var i = stub.clickTargets.length - 1; i >= 0; i--) {
            var target = stub.clickTargets[i];
            if (!stub.clickableTarget(target))
                continue;
            stub.hideTooltip(target);
            target.triggerPress(button);
            return true;
        }
        return false;
    }

    function requestPopout(key) {
        stub.activePopout = key;
    }

    function releasePopout(key) {
        if (stub.activePopout === key)
            stub.activePopout = null;
    }

    // One host window hosts at most one panel, so nothing else can own it.
    function targetBelongsToWindow() {
        return true;
    }

    // No neighbouring panel to hand off to: the strip has a single popup.
    // The real bar answers `switchPanelFrom(identity, direction)` by moving
    // the popout to the next panel that way; the stock clock and weather
    // panels call it from their arrow keys, guarded by a typeof check, so
    // answering false keeps those keys inert instead of throwing.
    function switchPanel() {
        return false;
    }

    function switchPanelFrom(identity, direction) {
        return false;
    }

    // ---- widget plumbing (PluginBarApi surface) -----------------------------

    // The pill draws no tooltips; plugins that call these are no-ops rather than
    // errors, which is what the host's facade does for an absent tooltip sink.
    function showTooltip() {
    }

    function hideTooltip() {
    }

    function setCenterHoverRevealSuppressed() {
    }

    // The real bar answers with every live slot for that module; a single host
    // has exactly one, and only for its own id.
    function moduleWidgets(moduleName) {
        var id = String(moduleName || "");
        if (!id || !stub.hostedWidget || id !== stub.moduleId)
            return [];
        return [stub.hostedWidget];
    }

    // Plugins use `bar.run` to fire a shell command. The real bar hands the
    // string to Util.execDetached, which is exactly this: a command string run
    // by a login shell so GUI targets keep the session PATH.
    function run(command) {
        if (!command)
            return;
        Quickshell.execDetached(["bash", "-lc", String(command)]);
    }
}
