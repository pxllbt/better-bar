import QtQuick
import Quickshell
import Quickshell.Hyprland
import "Singletons"

// Drives Singletons/Agents.qml directly: inject sessions + clients, then read
// back the derived badges. The pure derivation is what matters, so it is called
// rather than the Process round trip.
Item {
    id: probe
    width: 100
    height: 100

    Component.onCompleted: Qt.callLater(function () {
        var a = Agents;

        // Two terminals on different workspaces, three sessions.
        var clients = [
            { pid: 1001, workspace: { id: 1, name: "1" } },
            { pid: 1002, workspace: { id: 2, name: "2" } },
            { pid: 1003, workspace: { id: 3, name: "3" } }
        ];
        a.apply([
            { id: "a", status: "working", pids: "1001" },
            { id: "b", status: "waiting", pids: "1002" },
            { id: "c", status: "done",    pids: "1003" },
            { id: "d", status: "working", pids: "9999" },   // pid not a terminal
            { id: "e", status: "working", pids: "" }         // unattributable
        ], clients);

        console.log("PROBE sessions      = " + a.sessions.length);
        console.log("PROBE badge ws1     = '" + a.badgeFor("1") + "'   (expect working)");
        console.log("PROBE badge ws2     = '" + a.badgeFor("2") + "'   (expect waiting)");
        console.log("PROBE badge ws3     = '" + a.badgeFor("3") + "'   (expect '' -- done leaves nothing)");
        console.log("PROBE urgent        = " + a.urgent + "   (expect 1)");
        console.log("PROBE stateDir set  = " + (a.stateDir.length > 0));

        // A workspace with both a waiting and a working agent shows the waiting
        // one: it is the only badge worth interrupting you for.
        a.apply([
            { id: "x", status: "working", pids: "1001,1002" },
            { id: "y", status: "waiting", pids: "1002" }
        ], clients);
        console.log("PROBE mixed ws1     = '" + a.badgeFor("1") + "'   (expect working)");
        console.log("PROBE mixed ws2     = '" + a.badgeFor("2") + "'   (expect waiting)");
        console.log("PROBE mixed urgent  = " + a.urgent + "   (expect 1)");
        console.log("PROBE OK");
        Qt.quit();
    })
}
