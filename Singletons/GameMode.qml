pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

/**
 * Game mode: one flag that strips Hyprland's eye-candy and quiets the desktop for
 * gaming or deep focus. Entering snapshots the focus flags, forces do-not-disturb
 * and keep-awake on, pauses the visualizer, switches the power profile to
 * Performance (when power-profiles-daemon is running and the hardware offers it),
 * and runs the visual strip; leaving restores each to what it was before. The
 * strip itself lives in gamemode.sh so the original decoration values survive a
 * pill restart. `Flags.gameMode` is the single source of truth, flipped by the
 * mixer chip, the keybind, or IPC.
 *
 * Auto-Shadowplay: When `Flags.autoGameReplay` is active, GameMode automatically
 * signals Better Recast to arm its replay buffer in the background on game launch,
 * and cleanly disarms it when leaving game mode.
 */
Singleton {
    id: root

    readonly property bool active: Flags.gameMode
    readonly property string script: Config.hyprPath("scripts", "gamemode.sh")
    property string pending: ""
    property bool _autoReplayArmed: false

    onActiveChanged: active ? root.enter() : root.leave()

    Component.onCompleted: if (root.active) root.run("on");

    function enter() {
        Flags.gamePrevDnd = Flags.dnd;
        Flags.gamePrevViz = Flags.musicViz;
        Flags.gamePrevAwake = Flags.keepAwake;
        if (Battery.daemonReady && Battery.hasPerformance) {
            Flags.gamePrevProfile = String(Battery.profile);
            Battery.setProfile(PowerProfile.Performance);
        } else {
            Flags.gamePrevProfile = "";
        }
        Flags.dnd = true;
        Flags.musicViz = false;
        Flags.keepAwake = true;
        root.run("on");

        if (Flags.autoGameReplay) {
            root._autoReplayArmed = true;
            recastActionProc.running = false;
            recastActionProc.command = ["omarchy-shell", "px-recast", "startReplay"];
            recastActionProc.running = true;
        }
    }

    function leave() {
        root.run("off");
        Flags.dnd = Flags.gamePrevDnd;
        Flags.musicViz = Flags.gamePrevViz;
        Flags.keepAwake = Flags.gamePrevAwake;
        if (Flags.gamePrevProfile !== "") {
            var prev = parseInt(Flags.gamePrevProfile, 10);
            if (!isNaN(prev))
                Battery.setProfile(prev);
            Flags.gamePrevProfile = "";
        }

        if (root._autoReplayArmed) {
            root._autoReplayArmed = false;
            recastActionProc.running = false;
            recastActionProc.command = ["omarchy-shell", "px-recast", "stopReplay"];
            recastActionProc.running = true;
        }
    }

    function run(arg) {
        if (proc.running) {
            root.pending = arg;
            return;
        }
        proc.command = ["bash", root.script, arg];
        proc.running = true;
    }

    Process {
        id: proc
        onExited: {
            if (root.pending.length === 0)
                return;
            var a = root.pending;
            root.pending = "";
            proc.command = ["bash", root.script, a];
            proc.running = true;
        }
    }

    Process {
        id: recastActionProc
        running: false
    }
}
