import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Calendar.js" as Cal
import "backends/Hey.js" as Hey
import "backends/Google.js" as Google

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
//
// This is Omarchy's stock clock, and it also owns the calendar the popup
// draws: the weeks on screen, the calendars, the time track under way, and
// the reminders. It owns them rather than the panel because reminders have
// to fire with the panel closed. Everything it knows about the calendar
// service comes through Backend; everything it computes, through Cal.
BarWidget {
  id: root
  moduleName: "crmne.omacal"

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat
  readonly property string dateText: formatted(displayDate)
  readonly property string calendarGlyph: "󰃭"
  // The event the bar names in front of the clock, as the macOS menu-bar
  // calendars do. Horizontal bars only: a vertical one has no room.
  readonly property string barEventMode: String(setting("barEvent", "soon"))
  // Every event inside its alert window (from its earliest HEY reminder
  // until it ends), most pressing first; the bar names the first and counts
  // the rest.
  readonly property var shownEvents: Cal.barSelection(barEventMode, events, todayEvents, displayDate.getTime(), alertLeadMinutes)
  readonly property string eventText: Cal.barLabel(shownEvents, displayDate.getTime(), hour24, barEventMode)
  readonly property string displayText: eventText !== ""
    ? calendarGlyph + " " + eventText + "   " + dateText
    : (alerting ? calendarGlyph + "  " + dateText : dateText)
  // Vertical bars stack one line per icon slot, so the glyph takes a line of
  // its own rather than being crammed onto the hour.
  readonly property var verticalLines: alerting
    ? [calendarGlyph].concat(dateText.split("\n"))
    : dateText.split("\n")

  // ---- Calendar settings
  readonly property int alertLeadMinutes: Cal.normalizedAlertLead(setting("alertLeadMinutes", 15))
  readonly property int refreshIntervalSec: Cal.normalizedRefreshInterval(setting("refreshIntervalSec", 300))
  readonly property bool notificationsEnabled: setting("notifications", true) !== false
  readonly property bool liveSync: setting("liveSync", true) !== false
  readonly property string timeFormat: String(setting("timeFormat", "auto"))
  readonly property var hiddenCalendars: Cal.parseHiddenCalendars(setting("hiddenCalendars", []))
  onHiddenCalendarsChanged: rebuildIndex()
  // Whether a place writes half past four as 16:30 or 4:30pm is a regional
  // convention, so "auto" reads it off the locale.
  readonly property bool hour24: timeFormat === "24"
    ? true
    : (timeFormat === "12" ? false : String(Qt.locale().timeFormat(Locale.ShortFormat)).indexOf("AP") === -1)

  // ---- Calendar state, read by the panel.
  //
  // Weeks are cached by their Monday. `events` is every cached week merged,
  // and `byDay` the same events indexed by the days they touch, which is
  // what both the month grid and the day view read.
  property var weekCache: ({})
  // The backend, and how its probe said to read it (for HEY: "week" on
  // hey-cli 1.4.0+, "list" on 1.3.x, Omarchy's own package), or "" until
  // the probe has answered, or when it never will. Nothing is fetched until
  // this is known.
  readonly property var backend: String(setting("backend", "hey")) === "google"
    ? Google.configured(decodeURIComponent(String(Qt.resolvedUrl("backends/google.py")).replace(/^file:\/\//, "")), String(setting("googleAccount", "")))
    : Hey
  readonly property string backendName: backend.info.name
  readonly property var capabilities: backend.info.capabilities
  property string backendMode: ""
  property string backendVersion: ""
  property bool backendChecked: false
  property var events: []
  property var byDay: ({})
  property var calendars: []
  readonly property var writableCalendars: Cal.writableCalendars(calendars)
  property var timeTrack: null
  // Finished time tracks by day, and the one waiting to be named: set when
  // a Stop lands, so the panel can ask for a name right away.
  property var timeTracks: []
  property var tracksByDay: ({})
  property string renameTrackId: ""
  property real stoppedAt: 0
  property bool loading: false
  // "Nothing on today" and "we have not looked yet" are the same empty list
  // and very different things to put on screen.
  property bool loaded: false
  property string lastError: ""
  // The weeks the panel is showing, so a refresh re-reads what is on screen.
  property var visibleWeeks: []
  property var queuedWeeks: []
  property var fetchingWeeks: []

  readonly property string todayKey: Cal.keyForDate(displayDate)
  readonly property var todayEvents: byDay[todayKey] || []
  readonly property var nextEvent: Cal.currentOrNextEvent(todayEvents, displayDate.getTime())
  readonly property var alertEvent: Cal.imminentEvent(todayEvents, displayDate.getTime(), alertLeadMinutes)
  readonly property bool alerting: alertEvent !== null || shownEvents.length > 0

  // Reminders that came due before the shell started are not replayed.
  readonly property real startedAt: Date.now()
  property var shownReminders: ({})

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
    refreshCalendar(true)
  }

  // ---- Fetching

  // This week and next are always kept: they are the reminders that can
  // come due. Whatever the panel is showing rides along.
  function baseWeeks() {
    var monday = Cal.weekStartKey(root.todayKey)
    return [monday, Cal.addDays(monday, 7)]
  }

  function refreshCalendar(force) {
    if (!root.backendChecked) {
      if (!versionProcess.running) versionProcess.running = true
      return
    }
    if (root.backendMode === "") {
      if (!versionProcess.running) versionProcess.running = true
      return
    }
    requestWeeks(baseWeeks().concat(root.visibleWeeks), force === true)
    if (!calendarsProcess.running) calendarsProcess.running = true
    refreshTimeTrack()
  }

  function refreshTimeTrack() {
    if (!root.capabilities.timeTracking) return
    if (!timeTrackProcess.running) timeTrackProcess.running = true
    if (!timeTracksProcess.running) timeTracksProcess.running = true
  }

  function applyTimeTracks(text) {
    var parsed = Cal.parseTimeTracks(text)
    if (parsed === null) return
    root.timeTracks = parsed
    root.tracksByDay = Cal.tracksByDay(parsed)
    if (root.stoppedAt > 0) {
      var stopped = Cal.newestTrackSince(parsed, root.stoppedAt - 120000)
      if (stopped) root.renameTrackId = stopped.id
      root.stoppedAt = 0
    }
  }

  function showWeeks(keys) {
    root.visibleWeeks = keys || []
    requestWeeks(root.visibleWeeks, false)
  }

  function weekIsFresh(key) {
    var entry = root.weekCache[key]
    return !!entry && entry.events !== null && (Date.now() - entry.at) < root.refreshIntervalSec * 1000
  }

  function requestWeeks(keys, force) {
    if (root.backendMode === "") return
    var wanted = []
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (!Cal.isDayKey(key) || wanted.indexOf(key) !== -1) continue
      if (!force && weekIsFresh(key)) continue
      wanted.push(key)
    }
    if (wanted.length === 0) return

    if (weekProcess.running) {
      var queue = root.queuedWeeks.slice()
      for (var q = 0; q < wanted.length; q++)
        if (queue.indexOf(wanted[q]) === -1 && root.fetchingWeeks.indexOf(wanted[q]) === -1) queue.push(wanted[q])
      root.queuedWeeks = queue
      return
    }

    root.loading = true
    root.fetchingWeeks = wanted
    weekProcess.command = root.backend.fetchCommand(root.backendMode, wanted)
    weekProcess.running = true
  }

  function applyWeeks(exitCode, stdout) {
    root.loading = false
    var parsed = Cal.parseRangeOutput(stdout)
    var cache = {}
    for (var key in root.weekCache) cache[key] = root.weekCache[key]
    var failed = false

    if (parsed === null) {
      failed = true
    } else {
      for (var week in parsed) {
        if (parsed[week] === null) {
          failed = true
          // A week that could not be read keeps what it had, rather than
          // turning a busy week blank because the network blinked.
          if (!cache[week]) cache[week] = { events: null, at: 0 }
        } else {
          cache[week] = { events: parsed[week], at: Date.now() }
        }
      }
    }

    // Keeps the cache to the weeks anyone is looking at.
    var keep = baseWeeks().concat(root.visibleWeeks)
    var keys = Object.keys(cache)
    if (keys.length > 16) {
      for (var k = 0; k < keys.length; k++)
        if (keep.indexOf(keys[k]) === -1) delete cache[keys[k]]
    }

    // An empty answer is the shape every failure takes here (the CLI is
    // missing, signed out, or offline), so the panel says so rather than
    // showing a week that looks clear.
    root.lastError = failed
      ? (exitCode === 0 ? root.backendName + " did not answer. Is its CLI signed in?" : root.backendName + " exited with status " + exitCode + ".")
      : ""
    root.weekCache = cache
    rebuildIndex()
    root.loaded = true
    root.fetchingWeeks = []
    checkReminders()

    if (root.queuedWeeks.length > 0) {
      var next = root.queuedWeeks
      root.queuedWeeks = []
      requestWeeks(next, true)
    }
  }

  function rebuildIndex() {
    root.events = Cal.withoutHidden(Cal.mergeWeeks(root.weekCache), root.hiddenCalendars)
    root.byDay = Cal.indexByDay(root.events)
  }

  // Forgets the cached copy of the weeks a change touched, and re-reads them.
  function invalidateDay(dayKey) {
    var week = Cal.weekStartKey(dayKey)
    requestWeeks([week].concat(root.visibleWeeks), true)
  }

  // ---- Reminders

  function checkReminders() {
    if (!root.notificationsEnabled || !root.loaded) return
    var now = Date.now()
    var due = Cal.dueReminders(root.events, now, root.startedAt - 60000, root.shownReminders)
    if (due.length === 0) return
    var shown = {}
    for (var key in root.shownReminders) shown[key] = root.shownReminders[key]
    for (var i = 0; i < due.length; i++) {
      shown[due[i].key] = now
      Quickshell.execDetached(Cal.notifyCommand(due[i].event, now, root.hour24,
        root.dayUrl(Cal.eventDayKeys(due[i].event)[0] || "")))
    }
    // Forgets what is long past, so the set does not grow for as long as the
    // shell runs.
    for (var old in shown) if (now - shown[old] > 2 * 86400000) delete shown[old]
    root.shownReminders = shown
  }

  // ---- Writes. Each one re-reads what it changed once HEY has answered.

  property string writeError: ""
  property bool writing: false
  property string writingDayKey: ""
  signal writeFinished(bool ok, string message)

  function runWrite(command, dayKey) {
    if (writeProcess.running || !command || command.length === 0) return false
    root.writeError = ""
    root.writing = true
    root.writingDayKey = dayKey || ""
    writeProcess.command = command
    writeProcess.running = true
    return true
  }

  function finishWrite(exitCode, stdout) {
    root.writing = false
    var result = root.backend.writeResult(exitCode, stdout)
    var ok = result.ok
    var message = result.message
    root.writeError = ok ? "" : message
    if (!ok) root.stoppedAt = 0
    if (root.writingDayKey !== "") invalidateDay(root.writingDayKey)
    refreshTimeTrack()
    root.writeFinished(ok, message)
  }

  function addEvent(form) {
    var checked = Cal.validateEvent(form)
    if (checked.error) {
      root.writeError = checked.error
      root.writeFinished(false, checked.error)
      return false
    }
    return runWrite(root.backend.createCommand(checked.request), form.date)
  }

  function deleteEvent(event, dayKey) {
    return runWrite(root.backend.deleteCommand(event), dayKey)
  }

  function startTimeTrack() {
    return root.capabilities.timeTracking && runWrite(root.backend.trackStartCommand(), "")
  }

  function stopTimeTrack() {
    root.stoppedAt = Date.now()
    return root.capabilities.timeTracking && runWrite(root.backend.trackStopCommand(), "")
  }

  function renameTimeTrack(id, name) {
    root.renameTrackId = ""
    return root.capabilities.timeTracking && runWrite(root.backend.trackRenameCommand(id, name), "")
  }

  function deleteTimeTrack(id) {
    return root.capabilities.timeTracking && runWrite(root.backend.trackDeleteCommand(id), "")
  }

  // The backend's page for a day, or "" when it has none.
  function dayUrl(dayKey) {
    return root.capabilities.dayLink ? root.backend.dayUrl(dayKey) : ""
  }

  function modeNote() {
    return root.backend.modeNote(root.backendMode, root.backendVersion)
  }

  function openUrl(url) {
    var safe = Cal.safeUrl(url)
    if (safe !== "") Quickshell.execDetached(["xdg-open", safe])
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function formatted(date) {
    return Qt.formatDateTime(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function toggleWeekStart() {
    if (panelLoader.item) panelLoader.item.toggleWeekStart()
  }

  function newEvent() {
    if (panelLoader.item) panelLoader.item.newEvent()
  }

  function openSettings() {
    if (!panelLoader.item) return
    var panel = panelLoader.item
    if (panel.opened) {
      panel.openSettings()
      return
    }
    // Opening hands the popout over, which closes whatever was open and
    // resets this panel's view on the way; the switch has to come after.
    panel.open()
    Qt.callLater(function() { if (panel.opened) panel.openSettings() })
  }

  // The clock fills more slot than it paints a mark for, at both
  // orientations: horizontally it is a text label in a padded slot, so the
  // dot takes the label width; vertically it is a stack of icon-sized lines,
  // so the dot takes one line — the same mark every icon widget gets, rather
  // than a rule running the height of the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Component.onCompleted: refreshCalendar(true)

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      var wasKey = root.todayKey
      root.displayDate = date
      // Midnight moved the day, and on Mondays the week with it.
      if (Cal.keyForDate(date) !== wasKey) root.refreshCalendar(false)
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refreshCalendar(true)
  }

  // Reminders are checked off the cached events, not off HEY, so this is
  // cheap enough to run often and lands within seconds of the minute.
  Timer {
    interval: 15000
    running: root.notificationsEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkReminders()
  }

  Process {
    id: weekProcess
    running: false
    command: []
    stdout: StdioCollector { id: weekOutput; waitForEnd: true }
    onExited: function(exitCode) { root.applyWeeks(exitCode, weekOutput.text) }
  }

  // Asked once. The answer decides how weeks are read, and a missing or too
  // old CLI is said plainly in the panel rather than shown as empty days.
  Process {
    id: versionProcess
    running: false
    command: root.backend.probeCommand
    stdout: StdioCollector {
      onStreamFinished: {
        var probed = root.backend.probe(text)
        root.backendVersion = probed.version
        root.backendMode = probed.mode
        root.backendChecked = true
        if (root.backendMode === "") {
          root.lastError = probed.error
          root.loaded = true
          return
        }
        root.refreshCalendar(true)
      }
    }
  }

  Process {
    id: calendarsProcess
    running: false
    command: root.backend.calendarsCommand
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Cal.parseCalendars(text)
        if (parsed !== null) root.calendars = parsed
      }
    }
  }

  Process {
    id: timeTrackProcess
    running: false
    command: root.backend.currentTrackCommand
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Cal.parseCurrentTrack(text)
        if (parsed !== undefined) root.timeTrack = parsed
      }
    }
  }

  Process {
    id: timeTracksProcess
    running: false
    command: root.backend.tracksCommand
    stdout: StdioCollector {
      onStreamFinished: root.applyTimeTracks(text)
    }
  }

  Process {
    id: writeProcess
    running: false
    command: []
    stdout: StdioCollector { id: writeOutput; waitForEnd: true }
    onExited: function(exitCode) { root.finishWrite(exitCode, writeOutput.text) }
  }

  // ---- Live sync, for backends that can stream their changes (HEY: `hey
  //      watch`). Any change re-reads what is on screen, debounced so a burst of edits costs one fetch. The polling
  //      timer above stays as the fallback for when the watch is down.
  Timer {
    id: changeDebounce
    interval: 1500
    onTriggered: root.refreshCalendar(true)
  }

  Process {
    id: watchProcess
    running: root.liveSync && root.capabilities.watch && root.backendMode !== ""
    command: root.backend.watchCommand
    stdout: SplitParser {
      onRead: function(line) {
        if (root.backend.isWatchChange(line)) changeDebounce.restart()
      }
    }
    // A watch that dies (signed out, network gone, CLI upgraded under it)
    // is restarted after a pause rather than in a tight loop.
    onExited: if (root.liveSync && root.capabilities.watch && root.backendMode !== "") watchRestart.restart()
  }

  Timer {
    id: watchRestart
    interval: 60000
    onTriggered: if (root.liveSync && root.capabilities.watch && root.backendMode !== "" && !watchProcess.running) watchProcess.running = true
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "crmne.omacal"

    function refresh(): void { root.refresh() }
    function cycleFormat(): void { root.cycleFormat() }
    function toggleWeekStart(): void { root.toggleWeekStart() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function newEvent(): void { root.newEvent() }
    function settings(): void { root.openSettings() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.displayText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75
    // The glyph says "something is close"; hovering says what, and when.
    tooltipText: {
      if (root.lastError !== "") return "HEY: " + root.lastError
      if (!root.loaded) return ""
      if (root.shownEvents.length > 0) {
        var lines = []
        for (var i = 0; i < root.shownEvents.length && i < 8; i++)
          lines.push(Cal.barEventLabel(root.shownEvents[i], root.displayDate.getTime(), root.hour24))
        return lines.join("\n")
      }
      if (root.alerting) {
        var minutes = Cal.minutesUntil(root.alertEvent, root.displayDate.getTime())
        return (minutes <= 0 ? "Now" : "In " + minutes + " min") + " · " + root.alertEvent.title
      }
      if (root.nextEvent) return "Next: " + Cal.eventRangeLabel(root.nextEvent, root.hour24)
        + " · " + root.nextEvent.title
      return ""
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3
            ? button.fontSize * 0.9
            : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
