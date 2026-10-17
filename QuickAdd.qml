import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Calendar.js" as Cal
import "backends/Hey.js" as Hey
import "backends/Google.js" as Google

// The quick-add card: the calendar panel's new-event form on its own, in
// the middle of the screen, a shortcut away (Alt+Shift+Space by default).
// The same EventForm, so it is the same experience as the panel's + button.
//
// It talks to the services itself rather than through the bar widget, so it
// works on a screen without a bar: the event goes to HEY's API or Google's
// helper (Writer.qml), so its title and place are never on a command line.
// The widget sees the new event through its live sync or its next read, and
// remembers the calendar used last through the same `lastCalendarId`
// setting.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string moduleName: "crmne.omacal"

  property var calendars: []
  property bool busy: false
  property string error: ""
  // Set the first time the card opens: the services are asked from then
  // on, and not at all on a shell where it never does.
  property bool wanted: false

  readonly property var sourceContext: ({ dir: Cal.localPath(Qt.resolvedUrl(".")) })
  readonly property var sources: [heySource, googleSource]

  function open(payload) {
    root.error = ""
    root.opened = true
    root.wanted = true
    for (var i = 0; i < root.sources.length; i++) root.sources[i].refresh([], false)
    Qt.callLater(function() { form.reset() })
  }

  function setting(key, fallback) {
    var entry = widgetEntry()
    return entry && entry[key] !== undefined && entry[key] !== null ? entry[key] : fallback
  }

  function updateCalendars() {
    var lists = []
    var errors = []
    for (var i = 0; i < root.sources.length; i++) {
      var source = root.sources[i]
      if (source.ready) lists.push({ name: source.name, calendars: source.calendars })
      else if (source.enabled && source.checked && source.error !== "" && !source.missing) errors.push(source.error)
    }
    root.calendars = Cal.writableCalendars(Cal.mergeCalendars(lists))
    if (root.calendars.length === 0 && errors.length > 0 && !root.busy) root.error = errors.join(" ")
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

  function lastCalendarKey() {
    var entry = widgetEntry()
    return entry ? Cal.normalizedCalendarKey(entry.lastCalendarId) : ""
  }

  function rememberCalendar(key) {
    var entry = widgetEntry()
    if (!entry || !root.shell || typeof root.shell.updateEntryInline !== "function") return
    if (String(entry.lastCalendarId) === key) return
    var next = {}
    for (var field in entry) next[field] = entry[field]
    next.lastCalendarId = key
    root.shell.updateEntryInline(root.moduleName, next)
  }

  function submit(formValues) {
    if (root.busy) return
    var checked = Cal.validateEvent(formValues)
    if (checked.error) {
      root.error = checked.error
      return
    }
    var source = checked.request.source === "google" ? googleSource : (checked.request.source === "hey" ? heySource : null)
    if (!source || !source.ready) {
      root.error = "Pick a calendar to put the event on."
      return
    }
    rememberCalendar(formValues.calendarKey)
    root.error = ""
    if (source === heySource) {
      root.busy = writer.heyCreate(checked.request)
    } else {
      var write = Google.writeCommand("create", checked.request, root.sourceContext)
      root.busy = writer.run(Google, write.command, write.input)
    }
  }

  function finishAdd(ok, message) {
    root.busy = false
    if (ok) {
      dismiss()
      return
    }
    root.error = message
  }

  // The services a new event can go to, for their calendars only. They
  // are asked when the card opens, not before.
  Source {
    id: heySource
    backend: Hey
    enabled: root.wanted && root.setting("heyEnabled", true) !== false
    context: root.sourceContext
    readsWeeks: false
    onUpdated: root.updateCalendars()
  }

  Source {
    id: googleSource
    backend: Google
    enabled: root.wanted && root.setting("googleEnabled", false) === true
    context: root.sourceContext
    readsWeeks: false
    onUpdated: root.updateCalendars()
  }

  Writer {
    id: writer
    onFinished: function(ok, message) { root.finishAdd(ok, message) }
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
        defaultCalendarKey: root.lastCalendarKey()
        placeSuggestions: { var entry = root.widgetEntry(); return !entry || entry.placeSuggestions !== false }
        busy: root.busy
        error: root.error
        foreground: Color.popups.text
        onSubmitted: function(values) { root.submit(values) }
        onCanceled: root.dismiss()
      }
    }
  }
}
