import QtQuick
import Quickshell
import "plugin" as OmaCal
import "plugin/Calendar.js" as Cal

// The real bar widget with HEY, Google and a feed switched on, against the
// fakes tests/sources/run.js serves: every source read and merged, then a
// Google event created, edited and deleted through the widget.
ShellRoot {
  id: root
  property int phase: 0
  property var googleEvent: null
  readonly property string today: Cal.keyForDate(new Date())

  function fail(message) {
    console.error("SOURCES FAILED: " + message)
    Qt.exit(1)
  }

  function bySource(source) {
    return widget.events.filter(function(e) { return e.source === source })
  }

  function check() {
    if (root.phase !== 0) return
    var hey = bySource("hey"), google = bySource("google"), feeds = bySource("feeds")
    if (hey.length === 0 || google.length === 0 || feeds.length === 0) return
    var keys = widget.calendars.map(function(c) { return c.key })
    var writable = widget.writableCalendars.map(function(c) { return c.key })
    if (keys.indexOf("hey:7") === -1 || keys.indexOf("google:cal@example.test") === -1) return
    if (!keys.some(function(k) { return /^feeds:f[0-9a-f]{16}$/.test(k) })) return
    if (writable.some(function(k) { return k.indexOf("feeds:") === 0 })) fail("a feed took new events")
    if (keys.indexOf("google:hidden@example.test") !== -1) fail("a calendar switched off in Google was listed")
    var shared = widget.calendars.filter(function(c) { return c.name === "Work" })
    if (shared.length !== 2 || shared[0].label === shared[1].label) fail("two services' Work calendars were not told apart")
    if (google.some(function(e) { return e.editable && e.title === "Guest meeting" && widget.canDelete(e) }))
      fail("an invitation was deletable")
    if (feeds.some(function(e) { return widget.canEdit(e) || widget.canDelete(e) })) fail("a feed event was editable")
    if (widget.lastError !== "") fail("an error was shown: " + widget.lastError)
    console.log("read " + hey.length + " HEY, " + google.length + " Google and " + feeds.length + " feed events")
    root.phase = 1
    if (!widget.addEvent({ title: "Synthetic Google event", date: root.today, startTime: "10:00", endTime: "11:30",
        timeZone: "Europe/Berlin", calendarKey: "google:cal@example.test", location: "Synthetic place", remind: "10m" }))
      fail("the create did not start")
  }

  function findCreated() {
    var found = bySource("google").filter(function(e) { return e.title === "Synthetic Google event" })
    return found.length > 0 ? found[0] : null
  }

  OmaCal.BarWidget {
    id: widget
    moduleName: "crmne.omacal"
    settings: ({ id: "crmne.omacal", googleEnabled: true, notifications: false, liveSync: false, refreshIntervalSec: 30 })
    onWriteFinished: function(ok, message) {
      if (!ok) { root.fail("write " + root.phase + ": " + message); return }
      root.phase++
    }
  }

  Timer {
    interval: 250
    repeat: true
    running: true
    onTriggered: {
      root.check()
      if (root.phase === 2 && !widget.writing) {
        var created = root.findCreated()
        if (!created) return
        root.phase = 3
        var before = Cal.eventFormValues(created, "Europe/Berlin")
        var after = Object.assign({}, before, { title: "Edited Google event", remind: "", scope: "all" })
        if (!widget.editEvent(created, before, after)) root.fail("the edit did not start: " + widget.writeError)
      } else if (root.phase === 4 && !widget.writing) {
        var edited = bySource("google").filter(function(e) { return e.title === "Edited Google event" })
        if (edited.length === 0) return
        root.phase = 5
        if (!widget.canDelete(edited[0])) root.fail("the event OmaCal made was not deletable")
        if (!widget.deleteEvent(edited[0], root.today)) root.fail("the delete did not start")
      } else if (root.phase === 6) {
        console.log("SOURCES PASSED")
        Qt.quit()
      }
    }
  }

  // The panel's parts, built here too: the panel itself needs a window
  // offscreen Qt cannot give it, and these would otherwise go unchecked.
  OmaCal.SettingsView { visible: false; host: widget; loadsFeeds: false }
  OmaCal.EventForm { visible: false; loadZones: false; calendars: widget.writableCalendars }
  OmaCal.EventCard { visible: false }

  Timer { interval: 40000; running: true; onTriggered: root.fail("timed out in phase " + root.phase) }
}
