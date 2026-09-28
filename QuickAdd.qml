import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Calendar.js" as Cal
import "backends/Hey.js" as Backend

// The quick-add card: the calendar panel's new-event form on its own, in
// the middle of the screen, a shortcut away (Alt+Shift+Space by default).
// The same EventForm, so it is the same experience as the panel's + button.
//
// It talks to the HEY CLI itself rather than through the bar widget, so it
// works on a screen without a bar. The widget sees the new event through its
// live sync, and remembers the calendar used last through the same
// `lastCalendarId` setting.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string moduleName: "crmne.omacal"

  property var calendars: []
  property bool busy: false
  property string error: ""
  property string backendMode: ""

  function open(payload) {
    root.error = ""
    root.opened = true
    if (!calendarsProcess.running) calendarsProcess.running = true
    if (root.backendMode === "" && !versionProcess.running) versionProcess.running = true
    Qt.callLater(function() { form.reset() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    close()
    if (root.shell) root.shell.hide(root.moduleName)
  }

  function toggle() {
    if (root.opened) dismiss()
    else open("{}")
  }

  // The widget's entry in shell.json, where the panel keeps its settings.
  function widgetEntry() {
    var config = root.shell ? root.shell.barConfig : null
    var layout = config && config.layout ? config.layout : {}
    for (var section in layout) {
      var entries = Array.isArray(layout[section]) ? layout[section] : []
      for (var i = 0; i < entries.length; i++)
        if (entries[i] && entries[i].id === root.moduleName) return entries[i]
    }
    return null
  }

  function lastCalendarId() {
    var entry = widgetEntry()
    return entry ? (Number(entry.lastCalendarId) || 0) : 0
  }

  function rememberCalendar(id) {
    var entry = widgetEntry()
    if (!entry || !root.shell || typeof root.shell.updateEntryInline !== "function") return
    if (Number(entry.lastCalendarId) === id) return
    var next = {}
    for (var key in entry) next[key] = entry[key]
    next.lastCalendarId = id
    root.shell.updateEntryInline(root.moduleName, next)
  }

  function submit(formValues) {
    if (root.busy) return
    var checked = Cal.validateEvent(formValues)
    if (checked.error) {
      root.error = checked.error
      return
    }
    if (Number(formValues.calendarId) > 0) rememberCalendar(Number(formValues.calendarId))
    root.error = ""
    root.busy = true
    addProcess.finished = false
    addProcess.command = Backend.createCommand(checked.request)
    addProcess.running = true
  }

  function finishAdd(exitCode, stdout) {
    root.busy = false
    var result = Backend.writeResult(exitCode, stdout)
    if (result.ok) {
      dismiss()
      return
    }
    root.error = result.message
  }

  Process {
    id: versionProcess
    running: false
    command: Backend.probeCommand
    stdout: StdioCollector {
      onStreamFinished: {
        var probed = Backend.probe(text)
        root.backendMode = probed.mode
        if (root.backendMode === "") root.error = probed.error
      }
    }
  }

  Process {
    id: calendarsProcess
    running: false
    command: Backend.calendarsCommand
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Cal.parseCalendars(text)
        if (parsed !== null) root.calendars = Cal.writableCalendars(parsed)
      }
    }
  }

  Process {
    id: addProcess
    running: false
    command: []
    property bool finished: false
    stdout: StdioCollector {
      onStreamFinished: {
        addProcess.finished = true
        root.finishAdd(addProcess.exitCode, text)
      }
    }
    onExited: function(exitCode) {
      if (!addProcess.finished && root.busy) root.finishAdd(exitCode, "")
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omacal-quick-add"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // Focus asked for before the compositor has handed the window the
    // keyboard is lost, so the title is focused again once it has.
    onVisibleChanged: if (visible) focusAfterMap.restart()

    Timer {
      id: focusAfterMap
      interval: 80
      onTriggered: form.focusTitle()
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(480), window.width - Style.space(32))
      height: Math.min(form.implicitHeight + Style.space(36), window.height - Style.space(32))
      color: Color.popups.background
      border.color: Color.popups.border
      border.width: 1
      radius: Style.cornerRadius

      // Swallows clicks so the card does not close itself.
      MouseArea { anchors.fill: parent }

      EventForm {
        id: form
        anchors.fill: parent
        anchors.margins: Style.space(18)
        todayKey: Cal.keyForDate(new Date())
        calendars: root.calendars
        defaultCalendarId: root.lastCalendarId()
        busy: root.busy
        error: root.error
        foreground: Color.popups.text
        onSubmitted: function(values) { root.submit(values) }
        onCanceled: root.dismiss()
      }
    }
  }
}
