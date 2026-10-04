pragma Singleton
import QtQuick
import Quickshell

/**
 * 空 Dock state shared by every monitor's DockBar.
 *
 * `empty` is the single source of truth for "does the dock have anything to
 * show" (pinned apps, running apps, or a frequent-app shelf). `DockBar`
 * publishes it after every item rebuild; the reserve window consults it so the
 * exclusive bottom band is released while the dock is retracted empty — windows
 * may then tile all the way down instead of floating above a dead strip.
 *
 * `ordinalOf` backs the running-apps order. It hands out a first-seen ordinal
 * per app key and keeps it for the life of the session, so the shelf holds
 * still: it used to be sorted by lowest workspace, which made the dock
 * reshuffle every time a window moved between workspaces. The registry lives
 * here, not in DockBar, so two monitors never disagree about the order. It is
 * read imperatively from DockBar's poll rather than bound to, so the plain
 * object needs no change signal.
 */
Singleton {
    id: root

    property bool empty: true

    property var sessionOrder: ({})
    property int sessionCounter: 0

    /** First-seen ordinal for `key`, assigned on the sight of a new app. Keys
     *  that are somehow empty sort last instead of colliding at ordinal 0. */
    function ordinalOf(key) {
        if (!key)
            return 2147483647;
        var o = root.sessionOrder[key];
        if (o === undefined) {
            root.sessionCounter += 1;
            o = root.sessionCounter;
            root.sessionOrder[key] = o;
        }
        return o;
    }
}