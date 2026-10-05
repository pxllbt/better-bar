import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    //* How long the session lock is held after an unlock is accepted.
    //*
    //* LockSurface spends its first `releaseMs` relaxing the backdrop blur and
    //* must still be locked for all of it. Dropping the lock early hands the
    //* screen back mid-blur, so the desktop appears sharp and the *lock* is
    //* then revealed on top of it — the same flash this arrangement exists to
    //* avoid, just relocated. The surplus over releaseMs is deliberate headroom
    //* so the blur is fully relaxed before the compositor ever takes over.
    //*
    //* Keep this above LockSurface's `releaseMs` (200).
    readonly property int lockOutMs: 260

    LockContext {
        id: lockContext

        onUnlocked: {
            //* Let the blur relax first, then release the lock + quit. This used
            //* to fade the whole surface to opacity 0, which revealed the
            //* WlSessionLockSurface's own backing colour — a 40ms hold of solid
            //* black between the end of the fade and the lock dropping, visible
            //* as a black flash on every unlock. Nothing fades to nothing now;
            //* the lock *becomes* the desktop.
            lockContext.closing = true;
            quitTimer.start();
        }
    }

    Timer {
        id: quitTimer

        interval: root.lockOutMs
        repeat: false
        onTriggered: {
            lock.locked = false;
            Qt.quit();
        }
    }

    WlSessionLock {
        id: lock

        locked: true

        WlSessionLockSurface {
            id: surf

            //* Opaque so a frame can never flash through to the desktop. It is
            //* deliberately NOT relied on as the backdrop any more: it used to
            //* be what the exit fade revealed, which is exactly why the unlock
            //* flashed black. Now the capture is painted from the first frame
            //* and the unlock hands back a relaxed copy of it, so this only
            //* ever covers the one-frame window before anything is drawn.
            color: "#0b0d0c"

            LockSurface {
                anchors.fill: parent
                context: lockContext
                lockSurface: surf
            }

        }

    }

}
