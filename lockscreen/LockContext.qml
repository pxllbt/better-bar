import QtQuick
import Quickshell
import Quickshell.Services.Pam

Scope {
    id: root

    property string currentText: ""
    property bool unlockInProgress: false
    property bool showFailure: false
    // set on success — surfaces fade out while the compositor still holds the lock
    property bool closing: false
    // Last PAM message for UI (e.g. "Account locked", "Password: ")
    property string pamMessage: ""
    property bool pamIsError: false
    // Shown on the lock surface. PAM's own idea of who it is authenticating is
    // authoritative; the environment is only a fallback for the moment before
    // the first start(), when pam.user may not be resolved yet.
    readonly property string userName: pam.user || Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""

    signal unlocked()
    signal failed()

    //* Seconds to wait on a PAM that never reports back. pam_authenticate on
    //* a network directory home, or against a wedged helper, can hang with no
    //* result and no error. Without a ceiling the lock sits on "Authenticating"
    //* forever with the keyboard disabled by the unlockInProgress guard, and
    //* the only way out is a TTY -- the exact situation this lockscreen exists
    //* to prevent. Aborting lets the user simply try again.
    readonly property int authTimeoutMs: 15000

    function tryUnlock() {
        if (currentText === "" || unlockInProgress) {
            console.log("[lock] tryUnlock ignored empty/active");
            return ;
        }
        console.log("[lock] tryUnlock len=" + currentText.length);
        unlockInProgress = true;
        showFailure = false;
        pamMessage = "";
        authTimer.restart();
        var ok = pam.start();
        console.log("[lock] pam.start()=" + ok + " active=" + pam.active);
        if (!ok) {
            unlockInProgress = false;
            authTimer.stop();
            showFailure = true;
            pamMessage = "Could not start PAM";
        }
    }

    // Stop the countdown the moment PAM gives any verdict. onCompleted and
    // onError both call this, so a normal unlock never leaves it running.
    function finishAuth() {
        authTimer.stop();
        unlockInProgress = false;
    }

    Timer {
        id: authTimer

        interval: root.authTimeoutMs
        repeat: false
        onTriggered: {
            console.log("[lock] PAM timed out after " + root.authTimeoutMs + "ms, aborting");
            if (pam.active)
                pam.abort();
            root.pamMessage = "Timed out, try again";
            root.currentText = "";
            root.showFailure = true;
            root.finishAuth();
            root.failed();
        }
    }

    onCurrentTextChanged: {
        // typing clears failure banner (but not while checking)
        if (!unlockInProgress)
            showFailure = false;

    }

    PamContext {
        id: pam

        // Relative like official example — resolves to lockscreen/pam/
        configDirectory: "pam"
        config: "password.conf"
        onMessageChanged: {
            root.pamMessage = message;
            root.pamIsError = messageIsError;
            // keep any PAM-supplied text ("Password: ", and whatever
            // pam_unix says about a bad account) for the UI
            if (message && message.length > 0)
                console.log("[lock] pam msg: [" + message + "] err=" + messageIsError);

        }
        // The ONE place a password is handed to PAM.
        //
        // Do not also respond from onMessageChanged: the `message` property
        // changes *before* `responseRequired` flips, so that handler sees
        // req=false and does nothing, while onPamMessage fires after. Wiring
        // all three makes PAM receive two responses for one prompt and log
        // "PamContext response was ignored as this context does not require
        // one" on every unlock. responseRequiredChanged is the only signal
        // that is true exactly when a response is owed — and going true again
        // on a retry re-arms it for PAM's second prompt, which is what we
        // want.
        onResponseRequiredChanged: {
            if (!responseRequired)
                return ;
            console.log("[lock] responding len=" + root.currentText.length);
            respond(root.currentText);
        }
        onCompleted: (result) => {
            console.log("[lock] completed=" + result + " (0=Success 1=Failed 2=Error 3=MaxTries)");
            if (result === PamResult.Success) {
                root.unlocked();
            } else {
                if (result === PamResult.MaxTries)
                    root.pamMessage = "Too many tries";
                else if (result === PamResult.Error)
                    root.pamMessage = (root.pamMessage.length > 0 ? root.pamMessage : "PAM error");
                else if (result === PamResult.Failed)
                    root.pamMessage = (root.pamMessage.indexOf("locked") >= 0 ? root.pamMessage : "Incorrect password");
                root.currentText = "";
                root.showFailure = true;
                root.failed();
            }
            root.finishAuth();
        }
        onError: (error) => {
            console.log("[lock] pam error=" + error);
            root.pamMessage = "Auth error " + error;
            root.currentText = "";
            root.showFailure = true;
            root.finishAuth();
        }
    }

}
