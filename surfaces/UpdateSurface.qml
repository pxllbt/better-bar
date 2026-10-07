pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Singletons"
import "../components"

/**
 * 更新 UPDATE sub-surface: pulls the latest from GitHub and reloads the shell
 * in place. Reached from the Appearance index and folds back to it on the
 * back chevron or an empty click.
*/
SettingsSurface {
    id: root

    backSurface: "appearance"
    implicitHeight: content.implicitHeight

    property string status: ""
    property bool busy: false
    /** True once a probe has run successfully and knows the remote state. */
    property bool checked: false
    /** Commits on origin/master that this checkout is behind. */
    property int pending: 0
    /** True when checked and origin/master has new commits to pull. */
    readonly property bool updateAvailable: checked && !busy && pending > 0
    /**
     * The install has commits the update path would throw away.
     *
     * The update runs `git reset --hard origin/master` against the install,
     * which is the only way to survive a force-push or a diverged history. It
     * also discards every local commit in the checkout without asking. That is
     * correct for a managed deployment and wrong for a checkout someone is
     * working in — which is the common case here, because this bar is a git
     * clone people edit. So this is checked before the fetch, and a non-zero
     * commits-behind-HEAD answer routes the update through a second
     * confirmation instead of straight into the reset.
     */
    property bool localCommits: false
    /**
     * The install has uncommitted changes or untracked files, which
     * `reset --hard` would delete outright.
     *
     * `status --porcelain` counts untracked files, so a scratch file someone
     * left in the checkout is enough to raise this. That is intentional: the
     * question is "is this directory carrying work", and an untracked QML file
     * someone is mid-way through wiring is exactly that.
     *
     * This is the check that would have saved the lock work. Ten files in that
     * checkout carried git's skip-worktree bit, so `git status` reported it
     * almost clean and the work was invisible to every surface in the bar —
     * including this one. An invisible-worktree guard is not a guard, so the
     * count comes from a subprocess that reads the index itself rather than
     * from anything cached here.
     */
    property bool localDirty: false
    /** True when the install carries work an update would destroy. */
    readonly property bool updateRisky: localCommits || localDirty
    /** Inline result of the manual dependency check; empty until one has run. */
    property string depStatus: ""
    property bool depBusy: false
    /** True once a manual check has run, so the report link knows it is useful. */
    property bool depChecked: false
    /** Full records for what is missing: [{ id, why, pkg }], required first. */
    property var depList: []
    /** How many of depList are required rather than optional. */
    property int depRequiredCount: 0
    /**
     * Has a verdict for the run currently in flight arrived yet?
     *
     * Both halves of the answer are needed and neither alone is enough.
     * onStreamFinished fires before onExited, so the two callbacks for one run
     * are not interchangeable: only the first can carry the output, and only
     * the second reliably fires — a run that produced nothing never gets a
     * verdict at all. The flag is what tells onExited whether applyDepVerdict
     * already ran, and so whether an empty result means this check produced
     * nothing or that it simply has not reported yet. Reset on exit, so it can
     * never carry over into the next run and suppress its verdict.
    */
    property bool depVerdictSeen: false
    /**
     * Entries actually rendered, capped so the surface cannot grow without
     * bound. The cap guards a real failure mode, not a hypothetical one: the
     * check runs in a child process, and if that process ever inherits a
     * stripped environment then `command -v` fails for everything at once and
     * every dependency in the manifest reads as missing — fifteen entries of
     * three lines each, well past the screen. The generated report is the full
     * set, so the overflow is handed off there rather than dropped silently.
    */
    readonly property int depVisibleCap: 6
    readonly property var depVisible: depList.length > depVisibleCap
        ? depList.slice(0, depVisibleCap)
        : depList
    readonly property int depHiddenCount: depList.length - depVisible.length
    /**
     * The one-line verdict. Deliberately a count and not a list of names: the
     * list is rendered directly below, so repeating the names here would just
     * be the same information twice on one screen.
    */
    readonly property bool depCheckFailed: depStatus.startsWith("Could not")
    readonly property bool depReportUseful: depChecked && depList.length > 0 && !depCheckFailed
    /**
     * Cooldown between background probes. The surface re-probes on every open
     * (so a stale result can't stick around), but a bare `git fetch` round-trips
     * to GitHub each time — throttle that so rapid re-opens don't hammer the
     * network. First open always probes.
    */
    readonly property int probeCooldown: 60 * 1000
    /** Epoch ms of the last probe attempt; 0 = never ran, so the first open probes. */
    property real lastProbeMs: 0

    /** Re-probe for updates whenever the surface (re)opens — surfaces stay
     *  resident, so Component.onCompleted alone would only ever check once per
     *  session.
     *
     *  The dependency check deliberately does NOT ride along. It is a tap, not
     *  a background poll: a verdict the user did not ask for is an assertion
     *  about their machine that they cannot have made themselves, and a surface
     *  that reports "everything is fine" unprompted is indistinguishable from
     *  one that never checked. So the row reads as an offer, and nothing about
     *  dependencies appears on screen until the row is activated. The post-update
     *  path still opens the full report on its own, so the one case that cannot
     *  wait for a tap — an update that just changed the requirements — is still
     *  covered. */
    Connections {
        target: root
        function onOpenChanged() {
            if (root.open) {
                root.checkUpdates();
            }
        }
    }

    rows: [
        { item: updateRow, kind: "activate", activate: function () { root.doUpdate(); } },
        {
            item: confirmRow,
            kind: "activate",
            // Only reachable while updateRisky, and it runs the same path the
            // first tap would have: the user is choosing to discard, not
            // choosing a different update.
            activate: function () { root.runUpdate(); }
        },
        { item: depsRow, kind: "activate", activate: function () { root.checkDeps(); } }
    ]

    // First creation. The onOpenChanged handler above covers every later open,
    // but this Loader is created and shown in the same pass on the very first one.
    Component.onCompleted: {
        root.checkUpdates();
    }

    /** Lightweight fetch + count so the surface can flag an available update. */
    function checkUpdates() {
        if (root.busy)
            return;
        var elapsed = Date.now() - root.lastProbeMs;
        if (root.lastProbeMs > 0 && elapsed < root.probeCooldown)
            return;
        root.lastProbeMs = Date.now();
        fetchProc.running = true;
    }

    /**
     * Two-stage update. The first tap probes the checkout for work the reset
     * would destroy; the second runs the fetch, but only once the probe has
     * actually reported. The probe has to finish before `busy` is set, or the
     * button would read as done before the answer arrived.
     */
    function doUpdate() {
        if (root.busy)
            return;
        root.busy = true;
        root.status = "Checking for local changes...";
        dirtProbeProc.running = true;
    }

    /** Probe said the checkout is clean, or the user said go anyway. */
    function applyLocalCommits(n) { commitCountProc.ahead = n; }
    function applyPending(n) { countProc.ahead = n; }
    function runUpdate() {
        root.busy = true;
        root.status = "Fetching latest master...";
        pullProc.running = true;
    }

    /**
     * Dependency check. Deliberately shells out to the same
     * scripts/check-deps.sh the installer and the post-update path use, so the
     * answer here cannot drift from what those report.
     *
     * Called automatically on every open, and again on tap. Deliberately does
     * *not* clear depList/depStatus up front: the previous verdict is still
     * true, and blanking it would make the surface flicker empty on each reopen
     * for the few milliseconds the check takes. applyDepVerdict() owns the
     * post-state, including every failure path.
    */
    function checkDeps() {
        if (root.depBusy)
            return;
        root.depBusy = true;
        root.depVerdictSeen = false;
        depProc.running = true;
    }

    /**
     * Turn one line of `check-deps.sh --json` into the surface's list.
     *
     * Reached from a StdioCollector, not from Process.onExited: that signal is
     * (int exitCode, QProcess::ExitStatus) and carries no stdout. Reading a
     * second parameter as if it were the output is not a crash — for a normal
     * exit it is the string "0", and JSON.parse("0") happily returns the number
     * 0 — so every field then reads as absent, both lists come out empty, and
     * the surface reports "All dependencies satisfied" on a system that is
     * missing things. A silent, confidently wrong answer, which is the worst
     * kind this feature could produce.
    */
    function applyDepVerdict(text) {
        // Output arrived at all, which means a check did run. Set before parsing
        // so that a parse failure is reported as such, rather than being
        // overwritten by the onExited "produced nothing" fallback.
        root.depVerdictSeen = true;
        root.depChecked = true;
        var r = null;
        try {
            r = JSON.parse(String(text).trim());
        } catch (e) {
            r = null;
        }
        // Checking that the parse did not throw is not enough. JSON.parse accepts
        // plenty of things that are not a report: parse("0") is the number 0 and
        // parse("null") is null, neither of which throws. Both would go on to
        // read as a report with no missing dependencies in it, and the surface
        // would say "All dependencies satisfied" about a system it had learned
        // nothing at all. So the shape is checked, not just the parse.
        if (r === null || typeof r !== "object" || Array.isArray(r)) {
            root.depList = [];
            root.depRequiredCount = 0;
            root.depStatus = "Could not read the dependency report";
            return;
        }
        // Required first so the alarming entries sit at the top of the list,
        // with `required` carried per-entry for the delegate to colour by.
        // `why` is dropped here even though the script sends it: the list does
        // not render it, and a field nothing reads is one more thing to keep
        // true. It is still in the report, which is where it belongs.
        var core = r.missingCore || [];
        var opt = r.missingOptional || [];
        var all = [];
        core.forEach(function (d) { all.push({ id: d.id, pkg: d.pkg, required: true }); });
        opt.forEach(function (d) { all.push({ id: d.id, pkg: d.pkg, required: false }); });
        root.depList = all;
        root.depRequiredCount = core.length;
        if (core.length > 0) {
            root.depStatus = core.length + (core.length === 1 ? " required dependency missing" : " required dependencies missing");
        } else if (opt.length > 0) {
            root.depStatus = "All required present · " + opt.length + " optional not installed";
        } else {
            root.depStatus = "All dependencies satisfied";
        }
    }

    function openDepReport() {
        depPageProc.running = true;
    }

    Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 0

        SettingsHeader {
            s: root.s
            title: "UPDATE"
            showBack: true
        }

Item { width: 1; height: 10 * root.s }
        SettingsRow {
            id: updateRow
            surface: root
            name: root.busy ? "Updating..." : (root.status.length > 0 ? root.status : "Check for updates")
            // "refresh", not "refresh-cw". GlyphIcon holds no such name, and an
            // unknown name is not a fallback shape — the lookup ends at
            // { d: "" }, which draws nothing at all. The row was rendering its
            // leading glyph as empty space, which is part of why the two sections
            // here read as one row with an icon and one without.
            icon: "refresh"
            // The verdict goes in the row's own caption, not in a separate
            // full-width line underneath. Three stacked standalone Texts read as
            // a column of disconnected grey sentences floating between the two
            // rows, and each one had to be inset and aligned by hand. In the
            // caption slot the answer sits directly under the label it belongs
            // to and SettingsRow does the insetting, so there is only ever one
            // left edge to agree with.
            //
            // Busy says nothing: the label already reads "Updating...".
            sub: {
                if (root.busy || root.status.length > 0)
                    return "";
                if (root.updateAvailable)
                    return root.pending + (root.pending === 1 ? " commit behind" : " commits behind");
                if (root.checked)
                    return "You're up to date";
                return "";
            }

            // The spinner, and only the spinner. This is the trailing control
            // slot, which is a different slot from the leading `icon` above —
            // that is why a glyph can live here without doubling up on `icon`.
            // Visible only while running, because a second `refresh` sitting
            // still beside the row's own `refresh` while nothing is happening
            // would be the same glyph twice for no reason. The resting state
            // leaves the slot to the update-available dot.
            GlyphIcon {
                visible: root.busy
                width: 16 * root.s
                height: 16 * root.s
                name: "refresh"
                color: root.focusRowItem === updateRow ? Theme.cream : Theme.iconDim
                stroke: 1.9

                RotationAnimation on rotation {
                    running: root.busy
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 8 * root.s
                visible: root.updateAvailable
                width: 7 * root.s
                height: 7 * root.s
                radius: width / 2
                color: Theme.vermLit

                SequentialAnimation on opacity {
                    running: root.updateAvailable
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                }
            }
        }

        /**
         * The discard confirmation, shown only once the probe has found work
         * the reset would destroy.
         *
         * It is a separate row rather than a second tap on the update row
         * because "Update" is the row people have already learned to press, and
         * the whole failure here is that the row's own action was not the
         * thing being confirmed. Naming the consequence in the label — the
         * uncommitted changes, then the local commits — is the point; a generic
         * "are you sure?" would hide which of the two is at stake.
         *
         * Hidden while busy so it cannot be pressed into a second fetch
         * mid-update, and so a successful update clears the prompt rather than
         * leaving it up over a freshly-reset tree.
         */
        SettingsRow {
            id: confirmRow
            visible: root.updateRisky && !root.busy
            surface: root
            name: root.localDirty ? "Discard changes and update?" : "Discard local commits and update?"
            sub: root.localDirty
                ? "This install has uncommitted changes. Updating resets it and deletes them."
                : "This install has commits not on origin/master. Updating resets it and deletes them."

            GlyphIcon {
                width: 16 * root.s
                height: 16 * root.s
                name: "chevron-right"
                color: root.focusRowItem === confirmRow ? Theme.cream : Theme.vermLit
                stroke: 1.9
            }
        }

        /**
         * The gap that makes two sections out of what used to be one list.
         *
         * SettingsRow already draws a hairline under every row that is not
         * `last`, so there is a rule between these two. A rule alone is not
         * enough to read as a boundary, though — rows are separated by rules
         * too, and at 12 units the pair sat close enough to look like four
         * consecutive lines with two of them suddenly carrying a caption. The
         * extra space is what turns the rule into a division.
        */
        Item { width: 1; height: 10 * root.s }

        SettingsRow {
            id: depsRow
            surface: root
            name: root.depBusy ? "Checking dependencies..." : (root.depChecked ? "Check again" : "Check dependencies")
            // "layers" for the same reason the row above got a working `icon`:
            // the two sections should be recognisable apart at a glance, and
            // right now one of them owns the leading glyph column while the other
            // leaves it empty. Two rows, two glyphs, one shape.
            icon: "layers"
            // Before the first check the caption says what the button does; after
            // it, the caption *is* the answer. One slot, never both, so the row
            // cannot show an instruction and a verdict at once and leave the
            // reader unsure which one is current.
            sub: root.depChecked ? root.depStatus : "verify this system has what the current code needs"
            last: true

            /**
             * The verdict mark, and the only thing on this row that says a check
             * has actually run — so it must not exist before one is asked for.
             *
             * The leading `icon` above and this trailing glyph are separate
             * slots, which is why `layers` here adds no second mark. This one is
             * a check when nothing required is missing and a cross when something
             * is, because a tick that appeared whether or not the answer was yes
             * would be asserting a result the check never gave — the exact
             * failure the gating below exists to prevent, one level up.
             *
             * Dimmed rather than spun while running. "check" is a real glyph, not
             * a spinner frame, and rotating it would read as nonsense; the check
             * takes well under a second, so the dim is enough to acknowledge it.
            */
            GlyphIcon {
                visible: root.depBusy || root.depChecked
                width: 16 * root.s
                height: 16 * root.s
                name: root.depRequiredCount > 0 ? "close" : "check"
                color: root.depRequiredCount > 0
                       ? Theme.vermLit
                       : (root.focusRowItem === depsRow ? Theme.cream : Theme.iconDim)
                stroke: 1.9
                opacity: root.depBusy ? 0.45 : 1

                Behavior on opacity {
                    NumberAnimation { duration: 120 }
                }
            }
        }

        /**
         * The dependency result, inset to line up with the row labels above it.
         *
         * The inset is not cosmetic. SettingsRow places its own text 14 + 17 +
         * 13 = 44 scale units in, to clear the leading icon, and leaves 30 more
         * at the right for the trailing control. A list laid out from the
         * surface's own left edge therefore sat a full icon-width to the left of
         * the "Check dependencies" it belongs to — two unrelated-looking columns
         * stacked in one panel. Insetting everything below puts it on the same
         * left edge as every row, and the right inset stops the last entry
         * running under the tick.
         *
         * The wrapper is a plain Item rather than a Column, and that is the
         * whole trick: this sits inside `content`, which is itself a Column, and
         * a Positioner places its own children — anchors on them are ignored,
         * with a warning. An Item can be anchored; the Column goes one level
         * deeper, inside it, where anchoring is allowed again.
        */
        Item {
            id: depBlock
            width: content.width
            height: depCol.implicitHeight

            Column {
                id: depCol
                anchors.left: parent.left
                anchors.leftMargin: 44 * root.s
                anchors.right: parent.right
                anchors.rightMargin: 30 * root.s
                spacing: 0

                /**
                 * Section label, shown only when that half of the list is non-empty.
                 * Left-aligned, not centred: the entries underneath it are left-
                 * aligned to the row label's own edge, and a centred heading over a
                 * left-aligned list is the one combination that makes a column look
                 * accidental. Every line in this block now shares a single left edge,
                 * which is the whole reason the block reads as one unit.
                */
                Text {
                    visible: root.depRequiredCount > 0
                    width: parent.width
                    text: "REQUIRED"
                    color: Theme.vermDim
                    font.family: Theme.font
                    font.pixelSize: 9 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.1
                    topPadding: 14 * root.s
                    bottomPadding: 2 * root.s
                }

                Text {
                    visible: root.depRequiredCount === 0 && root.depList.length > 0
                    width: parent.width
                    text: "OPTIONAL"
                    color: Theme.faint
                    font.family: Theme.font
                    font.pixelSize: 9 * root.s
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.1
                    topPadding: 14 * root.s
                    bottomPadding: 2 * root.s
                }

                /**
                 * One entry per missing dependency: the id, and the package that
                 * provides it. Required entries are inked in the alarm colour and
                 * optional ones stay dim, so the list reads in priority order
                 * without needing to be split into two repeaters.
                 *
                 * Two things are deliberately absent. The manifest's `why`, because
                 * it is written for the report page — a sentence, in a column wide
                 * enough to read a sentence in — and under every id it turned a list
                 * of six into a wall of prose to scroll past to reach the package
                 * name. And the package line when it is just the id again, which for
                 * most entries it is: showing "ghostty" over "ghostty" is noise, and
                 * noise in a list this short costs a visible row. The report has the
                 * pairing in full either way.
                */
                Repeater {
                    model: root.depVisible

                    delegate: Column {
                        id: depItem
                        required property var modelData

                        // depCol.width by id, not parent.width: a Repeater's
                        // delegates are not reliably parented to the positioner, and
                        // parent.width would collapse to the Repeater's own zero
                        // width without any error. Referencing the inset column
                        // explicitly is what keeps the entries aligned with the
                        // labels above — depBlock is the full surface width, so
                        // sizing to that would put them back out at the left edge.
                        width: depCol.width
                        spacing: 1 * root.s
                        topPadding: 4 * root.s
                        bottomPadding: 4 * root.s

                        // The package line, minus anything that just repeats the id
                        // above it. Most entries are named after their own package,
                        // and "ghostty" printed over "ghostty" is a wasted row in a
                        // list this short; but an entry can list several packages and
                        // only one of them be the id, so the whole list is filtered
                        // rather than the line dropped on a single comparison. If
                        // nothing survives the filter the line is not rendered at all.
                        readonly property var pkgOnly: {
                            var out = [];
                            var pk = modelData.pkg || [];
                            for (var i = 0; i < pk.length; i++) {
                                if (pk[i] !== modelData.id) out.push(pk[i]);
                            }
                            return out;
                        }
                        readonly property string pkgText: pkgOnly.join(", ")

                        Text {
                            width: parent.width
                            text: depItem.modelData.id
                            color: depItem.modelData.required ? Theme.vermLit : Theme.subtle
                            font.family: Theme.font
                            font.pixelSize: 11 * root.s
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            visible: depItem.pkgText.length > 0
                            // "install X" is the actual next step, and the id is often
                            // not the package name — bluetoothctl comes from
                            // bluez-utils, the power profiles from a unit with no
                            // binary at all.
                            text: depItem.pkgText
                            color: Theme.dim
                            font.family: Theme.font
                            font.pixelSize: 10 * root.s
                            elide: Text.ElideRight
                        }
                    }
                }

                /**
                 * What the cap held back. Says how many, so the list reads as
                 * truncated on purpose rather than as the whole answer — a list that
                 * silently stops at six is indistinguishable from one where six is
                 * the truth.
                 *
                 * Left-aligned like everything else in this block. Centring it put
                 * the one line that refers back to the list somewhere the list was
                 * not.
                */
                Text {
                    visible: root.depHiddenCount > 0
                    width: parent.width
                    text: "+" + root.depHiddenCount + " more — see the full report"
                    color: Theme.dim
                    font.family: Theme.font
                    font.pixelSize: 10 * root.s
                    wrapMode: Text.WordWrap
                    topPadding: 4 * root.s
                }

                /**
                 * Opens the same generated HTML report the post-update path uses, for
                 * the install commands and anything the compact list above leaves
                 * out. One fixed file, rewritten in place, so repeated checks never
                 * pile up copies and this link always points at the current report.
                */
                Item {
                    id: depLink
                    visible: root.depReportUseful && !root.depBusy
                    width: parent.width
                    height: visible ? 26 * root.s : 0

                    TapHandler {
                        onTapped: root.openDepReport()
                    }

                    Text {
                        // Left, not centred, and vertically centred in the tap target
                        // so the whole row stays clickable. Centring the label made
                        // the one interactive line in the block the one line that did
                        // not line up with anything above it.
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Open full report with install commands"
                        color: depLinkHover.hovered ? Theme.cream : Theme.dim
                        font.family: Theme.font
                        font.pixelSize: 10 * root.s
                        font.underline: depLinkHover.hovered
                    }

                    HoverHandler { id: depLinkHover }
                }
            }
        }
    }

    /**
     * Dirty-worktree probe. Runs before the fetch so the confirmation has an
     * answer to show rather than asking about a risk it has not checked.
     *
     * Two separate questions, because they need separate commands and they
     * fail differently:
     *
     *   status --porcelain  -> uncommitted changes and untracked files, which
     *                          `reset --hard` deletes outright.
     *   rev-list --count    -> commits in the checkout that origin/master does
     *                          not have, which the same reset also discards.
     *
     * The commit count needs a remote-tracking ref that is current at the
     * moment of asking, and `origin/master` only moves when something fetches
     * it. So the probe fetches that ref itself before counting. Without this
     * the count would be against a stale ref, where 0 means "no local commits
     * as of whenever we last looked" rather than "no local commits".
     *
     * Both counts are read off stdout as bare numbers. A failure leaves the
     * property false, which is the permissive direction: an unreadable probe
     * must not block every update. The risk being guarded here is losing work
     * to a command that ran fine, not a command that failed loudly.
     */
    Process {
        id: dirtProbeProc
        property bool dirty: false
        command: ["git", "-C", Config.configDir, "status", "--porcelain"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: dirtProbeProc.dirty = text.trim().length > 0
        }
        onExited: function (exitCode) {
            root.localDirty = exitCode === 0 ? dirtProbeProc.dirty : false;
            skipProbeProc.running = true;
        }
    }

    Process {
        id: skipProbeProc
        property bool dirty: false
        command: ["git", "-C", Config.configDir, "ls-files", "-v"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: skipProbeProc.dirty = /^(S|h) /m.test(text)
        }
        onExited: function (exitCode) {
            if (exitCode === 0)
                root.localDirty = root.localDirty || skipProbeProc.dirty;
            headRefProbeProc.running = true;
        }
    }

    Process {
        id: headRefProbeProc
        command: ["git", "-C", Config.configDir, "fetch", "--quiet", "origin", "+master:refs/remotes/origin/update-probe"]
        onExited: function () {
            // Count regardless of the fetch's exit code: a network failure means
            // the ref is unchanged, which still gives a usable answer about
            // local commits, and refusing to probe on a flaky network would
            // block the update for no reason.
            commitCountProc.running = true;
        }
    }

    Process {
        id: commitCountProc
        property int ahead: -1
        command: ["git", "-C", Config.configDir, "rev-list", "--count", "refs/remotes/origin/update-probe..HEAD"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyLocalCommits(parseInt(text.trim(), 10))
        }
        onExited: function (exitCode) {
            var n = exitCode === 0 ? commitCountProc.ahead : NaN;
            root.localCommits = !isNaN(n) && n > 0;
            commitCountProc.ahead = -1;
            root.busy = false;
            root.status = "";
            if (root.updateRisky)
                root.checkUpdates();
            else
                root.runUpdate();
        }
    }

    /**
     * Update path: the deployment must mirror origin/master exactly. A plain
     * `git pull` fatals with "Need to specify how to reconcile divergent
     * branches" whenever the checkout's history has diverged from the remote
     * (e.g. after a force-push) and, worse, blames the network. So instead we
     * fetch master into its tracking ref and hard-reset the checkout onto it:
     * that handles fast-forwards, diverged histories and even replaced
     * histories, treating remote master as ground truth. Any local drift in
     * the install is discarded — this is a managed deployment. Only the fetch
     * can fail from a network problem; a reset failure is local, so its error
     * doesn't mention the network.
    */
    Process {
        id: pullProc
        command: ["git", "-C", Config.configDir, "fetch", "--quiet", "origin", "+master:refs/remotes/origin/master"]
        onExited: function (exitCode) {
            if (exitCode !== 0) {
                root.busy = false;
                root.status = "Update failed — check network";
                return;
            }
            resetProc.running = true;
        }
    }

    Process {
        id: resetProc
        command: ["git", "-C", Config.configDir, "reset", "--hard", "refs/remotes/origin/master"]
        onExited: function (exitCode) {
            root.busy = false;
            if (exitCode !== 0) {
                root.status = "Update failed";
                return;
            }
            root.pending = 0;
            root.checked = true;
            root.status = "Updated! Reloading...";
            postUpdateProc.running = true;
        }
    }

    /**
     * Non-blocking availability probe: refetch origin/master into the offset
     * ref then count how many of its commits this checkout is missing. A stale
     * remote-tracking ref is fine to read on open, but we refresh it first so
     * the badge reflects the true latest state. Network failure just leaves the
     * surface quiet — no error surfaced for a background check.
     */
    Process {
        id: fetchProc
        command: ["git", "-C", Config.configDir, "fetch", "--quiet", "origin", "+master:refs/remotes/origin/update-probe"]
        onExited: function (exitCode) {
            if (exitCode !== 0) {
                // Couldn't reach the network: leave the surface quiet rather
                // than claiming "up to date" on a check that never happened.
                root.checked = false;
                return;
            }
            countProc.running = true;
        }
    }

    Process {
        id: countProc
        property int ahead: -1
        command: ["git", "-C", Config.configDir, "rev-list", "--count", "HEAD..refs/remotes/origin/update-probe"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyPending(parseInt(text.trim(), 10))
        }
        onExited: function (exitCode) {
            var n = exitCode === 0 ? countProc.ahead : NaN;
            if (isNaN(n)) {
                // Count failed (e.g. no update-probe ref): don't claim anything.
                root.checked = false;
                countProc.ahead = -1;
                return;
            }
            root.checked = true;
            root.pending = n;
            countProc.ahead = -1;
        }
    }

    /**
     * Post-update step: runs after the reset succeeds and before the reload, and
     * is the only place the dependency check can live.
     *
     * It has to be here, in a process driven by the still-running outgoing
     * shell, rather than inside the shell after the reload. The whole reason to
     * re-check is that an update can introduce a requirement the user does not
     * have — and one of those can be an unresolvable QML import that stops the
     * shell loading at all. Shell code that failed to load cannot report its own
     * missing dependencies, and by the time a reloaded shell existed the one
     * moment where a broken shell could still say something would have passed.
     * So the check runs with the new code already on disk, against the old shell
     * that is still alive, immediately before the reload.
     *
     * It must therefore finish before the reload, hence its own Process rather
     * than being fired and forgotten: a reload mid-check would kill the very
     * process doing the reporting. `timeout` bounds it — the same guard the
     * brightness paths use — because a hung notification server must not be able
     * to strand the user on an "Updating..." surface that never reloads. The
     * check's own contract is to never fail the update, so every error path in
     * it is swallowed here.
    */
    Process {
        id: postUpdateProc
        command: ["timeout", "10", Config.hyprPath("scripts", "check-deps.sh"), "--report"]
        onExited: reloadTimer.start()
    }

    /**
     * The dependency check itself. Note where the output is read from: the
     * verdict arrives through a StdioCollector, not through onExited. That
     * signal is (int exitCode, QProcess::ExitStatus) and carries no stdout.
     * Treating its second parameter as the output is not a crash either — on a
     * normal exit it is the string "0", and JSON.parse("0") returns the number
     * 0 — so every field reads as absent, both lists come out empty, and the
     * surface cheerfully reports "All dependencies satisfied" on a system that
     * is missing things. Hence the collector, like every other process here.
    */
    Process {
        id: depProc
        running: false
        command: [Config.hyprPath("scripts", "check-deps.sh"), "--json"]
        stdout: StdioCollector {
            onStreamFinished: root.applyDepVerdict(this.text)
        }
        onExited: function (exitCode) {
            // Busy is cleared here rather than in onStreamFinished, because a run
            // that produced no output at all still has to stop looking busy.
            root.depBusy = false;
            root.depChecked = true;
            if (!root.depVerdictSeen) {
                // No output means the script never got as far as a verdict: it
                // writes every failure to stderr and exits non-zero, so this is
                // jq or the manifest being gone, not a clean system. Clear the
                // list here because no collector callback will do it.
                root.depList = [];
                root.depRequiredCount = 0;
                root.depStatus = "Could not run the check — jq and the manifest are required";
            }
            root.depVerdictSeen = false;
        }
    }

    /** Opens the generated HTML report — the full list, which a line cannot hold. */
    Process {
        id: depPageProc
        command: [Config.hyprPath("scripts", "check-deps.sh"), "--page"]
    }

    Timer {
        id: reloadTimer
        interval: 1000
        onTriggered: Quickshell.reload(true)
    }
}
