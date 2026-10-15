pragma Singleton

import QtQuick
import Quickshell

/**
 * PLYMOUTH settings model: the custom unlock choices Better Bar keeps for the
 * Plymouth boot screen, and the command string Omarchy needs to publish them.
 *
 * The stock desktop theme path is only one preset. A custom unlock is a
 * background/text hex pair plus a logo file, applied through
 * `omarchy-plymouth-set`; that path does not consult the Omarchy desktop theme
 * at all. Keeping the derivation here means the settings surface, the doctor's
 * dead-flag sweep and any future status logic all read the same truth instead
 * of each re-implementing the stock fallback.
 */
Singleton {
    id: root

    /** The packaged Omarchy unlock logo, used when the user picks no file. */
    readonly property string stockLogo: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/default/plymouth/logo.png"

    /** The logo to publish: the user's file, else the stock one. */
    readonly property string activeLogo: Flags.plymouthLogo.length > 0 ? Flags.plymouthLogo : root.stockLogo

    /** True when both custom colours are usable as #RRGGBB. */
    readonly property bool valid: root.isHex(Flags.plymouthBg) && root.isHex(Flags.plymouthText)

    function isHex(v) {
        return /^#[0-9a-fA-F]{6}$/.test(String(v || ""));
    }

    /** Single-quote one shell argument for the privileged terminal command. */
    function shellArg(v) {
        return "'" + String(v || "").replace(/'/g, "'\\''") + "'";
    }
}
