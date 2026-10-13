import QtQuick
import "../Singletons"

/**
 * The bar's single-line search/filter field.
 *
 * Deliberately NOT a TextInput.
 *
 * QQuickTextInput keeps its `canPaste` state live by reading
 * QClipboard::mimeData() on every clipboard-change signal. On Wayland that read
 * is an unbounded, deadline-free transfer of whatever another client offered,
 * so a slow or huge selection can stall the single process every surface of the
 * bar shares. `maximumLength` bounds what is *stored*, not that transfer, so it
 * does not close the hole. (This is the finding that used to live here.)
 *
 * So this component is an ordinary Item that captures keystrokes and appends
 * them to its own JS buffer. A plain QQuickItem never touches QClipboard: no
 * canPaste, no selection listener, no read — there is nothing to bound. It also
 * drops the QControls import, which is a measurable chunk of type metadata for
 * an element that only ever needs to render one string.
 *
 * What that costs, stated plainly: no native IME, no middle-click paste, no
 * text selection, and editing is single-caret append/delete. For a field whose
 * entire job is filtering a list by one short query, that is the right trade —
 * and it keeps the whole bar's input path free of clipboard reads.
 */
Item {
    id: root

    property real s: 1
    property string kanji: ""
    property string placeholder: ""
    property string counterText: ""
    /** False while the owning surface is closed, so the field holds no focus. */
    property bool active: true

    /**
     * Map Left/Right to the moved() signal instead of caret motion. For a
     * horizontal result strip the arrows should page the strip; without this the
     * field swallows them until the caret sits at a text boundary, so navigation
     * stalls mid-query.
     */
    property bool horizontalNav: false
    readonly property alias input: inputProxy
    property alias text: inputProxy.buffer
    default property alias rightContent: rightSlot.data

    signal moved(int delta)
    signal accepted()
    signal dismissed()
    signal keyPressed(var event)

    /** Hard cap on stored characters, enforced locally as it always was. */
    readonly property int maxChars: 256

    // The root hugs the line's content height so the glyph, text, placeholder
    // and caret all share one baseline, instead of each anchoring to a taller
    // box that drags them low. Heighting from the font metric keeps every
    // verticalCenter consistent with the typed text.
    readonly property real fieldLine: lineMetrics.implicitHeight
    height: fieldLine + 2

    /**
     * The interactive surface: a plain Item. QQuickItem already gives the API
     * every consumer needs — forceActiveFocus(), focus, activeFocus,
     * mapToItem(), width — and touches nothing outside this item.
     */
    Item {
        id: inputProxy
        anchors.fill: parent
        focus: true
        // Every gate a caller can use, so a closed or hidden surface can never
        // hold focus or eat keys: the explicit `active` flag, the inherited
        // `enabled`, and the item's own visibility.
        enabled: root.active && root.enabled && root.visible

        /** The typed query. Mirrored through `SearchField.text`. */
        property string buffer: ""
        /** Insertion point, 0..buffer.length. */
        property int caret: 0
        /** A manual buffer has no selection; exposed so callers' guards hold. */
        property string selectedText: ""

        readonly property real caretX: Math.max(0,
            Math.min(queryText.width, preCaretMetrics.advanceWidth))

        /** Caret box in this item's coordinates, the shape consumers map. */
        readonly property rect cursorRectangle: Qt.rect(
            caretX,
            (inputProxy.height - caretMark.height) / 2,
            caretMark.width,
            caretMark.height)

        Text {
            id: queryText
            anchors.left: parent.left
            anchors.right: counter.left
            anchors.rightMargin: 10 * root.s
            anchors.verticalCenter: parent.verticalCenter
            text: inputProxy.buffer
            color: Theme.cream
            font.family: Theme.font
            font.pixelSize: 12.5 * root.s
            elide: Text.ElideRight
        }

        // Measurement of the text before the caret: how far right the caret
        // belongs. Same font as the query, so it tracks pixelSize changes. A
        // TextMetrics rather than a hidden Text, so the advance is always computed
        // and never subject to a polish ordering with the query above it.
        TextMetrics {
            id: preCaretMetrics
            font.family: Theme.font
            font.pixelSize: 12.5 * root.s
            text: inputProxy.buffer.substring(0, inputProxy.caret)
        }

        Rectangle {
            id: caretMark
            x: inputProxy.caretX
            width: 1.6 * root.s
            height: lineMetrics.implicitHeight
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.vermLit
            visible: inputProxy.activeFocus && root.active
            opacity: caretMark.visible ? (blinkTimer.on ? 1 : 0) : 0
        }

        Timer {
            id: blinkTimer
            property bool on: true
            // Two wakes a second, and only while this field actually owns focus.
            interval: 530
            repeat: true
            running: inputProxy.activeFocus && root.active
            onTriggered: parent.on = !parent.on
        }

        // The caret is captured before the buffer is touched and written after it,
        // and both values are derived from the pre-mutation caret.
        //
        // Deriving it from the caret as it was BEFORE the edit is what makes
        // onBufferChanged's clamp harmless. The clamp runs synchronously when the
        // buffer is assigned, and it trims the caret to the new length -- which,
        // for a backspace at the end of the text, is already the correct answer.
        // Assigning `caret -= 1` after that decremented it a SECOND time: typing
        // "hello" and deleting left "hell", then "hel", then "hl", "l", and then a
        // caret of 0 that made every further backspace return early. One character
        // was left behind, and the buffer was corrupted on the way because each
        // step skipped a character.
        //
        // Every target below is <= the buffer's new length, so the clamp is a
        // no-op and the two no longer disagree.
        function insertString(str) {
            if (!str.length || inputProxy.buffer.length + str.length > root.maxChars)
                return;
            var at = inputProxy.caret;
            inputProxy.buffer = inputProxy.buffer.substring(0, at)
                + str + inputProxy.buffer.substring(at);
            inputProxy.caret = at + str.length;
        }

        function deleteBackward() {
            if (inputProxy.caret <= 0)
                return;
            var p = inputProxy.caret;
            inputProxy.buffer = inputProxy.buffer.substring(0, p - 1)
                + inputProxy.buffer.substring(p);
            inputProxy.caret = p - 1;
        }

        function deleteForward() {
            var p = inputProxy.caret;
            if (p >= inputProxy.buffer.length)
                return;
            inputProxy.buffer = inputProxy.buffer.substring(0, p)
                + inputProxy.buffer.substring(p + 1);
            inputProxy.caret = p;
        }

        /** A caret move out of sync with the text is always clamped down. */
        onBufferChanged: inputProxy.caret = Math.max(0,
            Math.min(inputProxy.caret, inputProxy.buffer.length))

        Keys.onPressed: (e) => {
            root.keyPressed(e);
            if (e.accepted)
                return;

            if (e.key === Qt.Key_Up) {
                root.moved(-1);
                e.accepted = true;
            } else if (e.key === Qt.Key_Down) {
                root.moved(1);
                e.accepted = true;
            } else if (root.horizontalNav && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) {
                root.moved(e.key === Qt.Key_Right ? 1 : -1);
                e.accepted = true;
            } else if (e.key === Qt.Key_Left) {
                inputProxy.caret = Math.max(0, inputProxy.caret - 1);
                e.accepted = true;
            } else if (e.key === Qt.Key_Right) {
                inputProxy.caret = Math.min(inputProxy.buffer.length, inputProxy.caret + 1);
                e.accepted = true;
            } else if (e.key === Qt.Key_Home) {
                inputProxy.caret = 0;
                e.accepted = true;
            } else if (e.key === Qt.Key_End) {
                inputProxy.caret = inputProxy.buffer.length;
                e.accepted = true;
            } else if (e.key === Qt.Key_Backspace) {
                inputProxy.deleteBackward();
                e.accepted = true;
            } else if (e.key === Qt.Key_Delete) {
                inputProxy.deleteForward();
                e.accepted = true;
            } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                root.accepted();
                e.accepted = true;
            } else if (e.key === Qt.Key_Escape) {
                root.dismissed();
                e.accepted = true;
            } else if (e.text && e.text.length > 0) {
                // Printable input only: key names carry an empty text, and
                // control characters never belong in a filter string.
                var code = e.text.charCodeAt(0);
                if (code >= 32 && code !== 127)
                    inputProxy.insertString(e.text);
                e.accepted = true;
            }
        }
    }

    // The placeholder sits exactly under the query text, so an empty field
    // prompts in the glyph's own slot rather than a shifted box.
    Text {
        id: placeholderText
        anchors.left: parent.left
        anchors.right: counter.left
        anchors.rightMargin: 10 * root.s
        anchors.verticalCenter: parent.verticalCenter
        visible: inputProxy.buffer.length === 0 && root.placeholder.length > 0
        text: root.placeholder
        color: Theme.faint
        font.family: Theme.font
        font.pixelSize: 12.5 * root.s
        elide: Text.ElideRight
    }

    // One invisible line, measured once, for the vertical metric every element
    // shares — the caret, the query and the placeholder all derive from it.
    TextMetrics {
        id: lineMetrics
        font.family: Theme.font
        font.pixelSize: 12.5 * root.s
        text: "Ag"
    }

    Text {
        id: counter
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: rightSlot.left
        anchors.rightMargin: rightSlot.width > 0 ? 10 * root.s : 0
        text: root.counterText
        color: Theme.faint
        font.family: Theme.font
        font.pixelSize: 10.5 * root.s
        font.features: { "tnum": 1 }
    }

    Item {
        id: rightSlot
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        width: childrenRect.width
        height: parent.height
    }
}
