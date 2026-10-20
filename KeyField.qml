import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "KeyEdit.js" as Edit

// A one-line text field built from key events, not Qt's text input. Every
// editable Qt text input asks the clipboard for what it holds each time
// another application changes it, hidden or not, focused or not, with no
// limit on size or time: an application could stall the shell that way
// without anyone pasting. This one never looks at the clipboard except on
// Ctrl+V or Shift+Insert, and then out of process, for two seconds and 4 KB
// at most.
//
// It draws its own text and caret, and keeps the kit TextField's look and
// the parts of its API Calendar for Omarchy uses: text, placeholderText, password,
// selectAll(), accepted and editingFinished. Keys: typing, Left/Right
// (Ctrl: a word), Home/End, Backspace/Delete (Ctrl+Backspace or Ctrl+W: a
// word), Ctrl+A all, Ctrl+U clear, Enter accepts. Input methods are not
// supported.
//
// `keyHandler` (event, field) sees every key first, as the forms' shared
// handlers do; a key it accepts goes no further. `preKey` (event) comes
// before even that, for a field built on this one (ZoneField).
Item {
  id: root

  property string text: ""
  property string placeholderText: ""
  property bool password: false
  // A character typed or pasted has to match this, when it is set.
  property var allowed: null
  property int maximumLength: Edit.maximumLength
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool hasCursor: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property alias font: shown.font
  property var keyHandler: null
  property var preKey: null

  property int cursorPosition: 0
  property bool allSelected: false

  signal accepted()
  signal editingFinished()

  readonly property bool hovered: mouse.containsMouse
  readonly property string display: root.password ? "•".repeat(root.text.length) : root.text
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : (hovered || hasCursor ? "hover-cursor" : "normal"), root.foreground, root.accent)

  // Set while this changes `text` itself, so an outside assignment can be
  // told apart: that one puts the caret at the end.
  property bool _editing: false

  function current() {
    return Edit.state(root.text, root.cursorPosition, root.allSelected)
  }

  function apply(next) {
    root._editing = true
    root.text = next.text
    root.cursorPosition = next.cursor
    root.allSelected = next.all
    root._editing = false
    blink.restart()
    caret.visible = true
  }

  function selectAll() {
    apply(Edit.selectAll(current()))
  }

  function insert(value) {
    apply(Edit.insert(current(), value, root.allowed, root.maximumLength))
  }

  function paste() {
    if (!pasteProcess.running) pasteProcess.running = true
  }

  function widthOf(value) {
    metrics.text = value
    return metrics.advanceWidth
  }

  // The caret position nearest a point in the text.
  function positionAt(x) {
    var best = 0
    var bestDistance = Math.abs(x)
    for (var i = 1; i <= root.display.length; i++) {
      var distance = Math.abs(widthOf(root.display.substr(0, i)) - x)
      if (distance < bestDistance) {
        best = i
        bestDistance = distance
      }
    }
    return best
  }

  // Typed text from a key event, or "" for anything that is not.
  function typed(event) {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return ""
    return Edit.clean(event.text)
  }

  function edit(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var key = event.key
    var s = current()
    if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      root.accepted()
      root.editingFinished()
    }
    else if (key === Qt.Key_Backspace) apply(ctrl ? Edit.deleteWord(s) : Edit.backspace(s))
    else if (key === Qt.Key_Delete) apply(Edit.del(s))
    else if (key === Qt.Key_Left) apply(Edit.left(s, ctrl))
    else if (key === Qt.Key_Right) apply(Edit.right(s, ctrl))
    else if (key === Qt.Key_Home) apply(Edit.home(s))
    else if (key === Qt.Key_End) apply(Edit.end(s))
    else if (ctrl && key === Qt.Key_A) apply(Edit.selectAll(s))
    else if (ctrl && key === Qt.Key_U) apply(Edit.clear())
    else if (ctrl && key === Qt.Key_W) apply(Edit.deleteWord(s))
    else if ((ctrl && key === Qt.Key_V) || (shift && key === Qt.Key_Insert)) paste()
    else {
      var value = typed(event)
      if (value === "") return
      insert(value)
    }
    event.accepted = true
  }

  activeFocusOnTab: true
  implicitWidth: Style.space(160)
  implicitHeight: shown.implicitHeight + 2 * root.verticalPadding + Border.top(_borderSpec) + Border.bottom(_borderSpec)

  onTextChanged: {
    if (root._editing) return
    root.cursorPosition = root.text.length
    root.allSelected = false
  }
  onActiveFocusChanged: {
    if (activeFocus) {
      blink.restart()
      caret.visible = true
    } else {
      root.allSelected = false
      root.editingFinished()
    }
  }

  // Every key, in order: preKey, keyHandler, then the editing.
  function press(event) {
    if (root.preKey) {
      root.preKey(event)
      if (event.accepted) return
    }
    if (root.keyHandler) {
      root.keyHandler(event, root)
      if (event.accepted) return
    }
    root.edit(event)
  }

  Keys.onPressed: function(event) { root.press(event) }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.activeFocus, root.hovered || root.hasCursor, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  // One for clicks, measured on demand, and one the caret follows: a
  // binding that set the shared one's text would depend on itself.
  TextMetrics {
    id: metrics
    font: shown.font
  }

  TextMetrics {
    id: caretMetrics
    font: shown.font
    text: root.display.substr(0, root.cursorPosition)
  }

  Item {
    id: viewport
    anchors.fill: parent
    anchors.leftMargin: root.horizontalPadding + Border.left(root._borderSpec)
    anchors.rightMargin: root.horizontalPadding + Border.right(root._borderSpec)
    clip: true

    readonly property real caretX: caretMetrics.advanceWidth
    // Scrolls just enough to keep the caret in view.
    property real offset: 0
    onCaretXChanged: {
      if (caretX - offset > width - 2) offset = caretX - width + 2
      else if (caretX < offset) offset = caretX
    }
    onWidthChanged: if (caretX - offset < width) offset = Math.max(0, caretX - width + 2)

    Rectangle {
      visible: root.allSelected && root.activeFocus
      x: -viewport.offset
      anchors.verticalCenter: parent.verticalCenter
      width: shown.implicitWidth
      height: shown.implicitHeight
      color: Style.selectionFillFor(root.foreground, root.accent)
    }

    Text {
      id: shown
      x: -viewport.offset
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.display
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }

    Text {
      visible: root.text === ""
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      textFormat: Text.PlainText
      text: root.placeholderText
      color: Qt.darker(root.foreground, 1.6)
      font: shown.font
      elide: Text.ElideRight
    }

    Rectangle {
      id: caret
      visible: root.activeFocus
      x: viewport.caretX - viewport.offset
      anchors.verticalCenter: parent.verticalCenter
      width: 1
      height: shown.implicitHeight
      color: root.foreground
    }
  }

  Timer {
    id: blink
    interval: 530
    repeat: true
    running: root.activeFocus
    onTriggered: caret.visible = !caret.visible
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.IBeamCursor
    onPressed: function(event) {
      root.forceActiveFocus()
      var x = event.x - viewport.x + viewport.offset
      root.apply(Edit.state(root.text, root.positionAt(x), false))
    }
    onDoubleClicked: root.selectAll()
  }

  // The clipboard, read only when asked to paste: two seconds and 4 KB at
  // most, and nothing of the field's in the command.
  Process {
    id: pasteProcess
    command: ["sh", "-c", "timeout -k 1 2 wl-paste --no-newline --type text/plain 2>/dev/null | head -c 4096"]
    stdout: StdioCollector {
      onStreamFinished: if (root.activeFocus) root.insert(text)
    }
  }
}
