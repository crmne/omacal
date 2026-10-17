import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Calendar.js" as Cal
// The calendar services OmaCal reads, each a Source: HEY, Google, and the
// calendar feeds. Time tracking is HEY's own, so it is read from HEY.
import "backends/Hey.js" as Hey
import "backends/Google.js" as Google
import "backends/Feeds.js" as Feeds
import "backends/HeyApi.js" as Api

// Date/time label for the bar, and the host for the calendar popup.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
//
// This is Omarchy's stock clock, and it also owns the calendar the popup
// draws: the weeks on screen, the calendars, the time track under way, and
// the reminders. It owns them rather than the panel because reminders have
// to fire with the panel closed. What it knows about each calendar service
// comes through that service's Source; everything it computes, through Cal.
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
  // Every event inside its alert window (from its earliest reminder until
  // it ends), most pressing first; the bar names the first and counts the
  // rest.
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

  // ---- The services. HEY is on unless switched off; Google once switched
  //      on; the feeds whenever there are any (backends/Feeds.js).
  readonly property bool heyEnabled: setting("heyEnabled", true) !== false
  readonly property bool googleEnabled: setting("googleEnabled", false) === true
  readonly property bool feedsEnabled: setting("feedsEnabled", true) !== false
  // Where the plugin is, for the backends that run a helper next to their
  // file.
  readonly property var sourceContext: ({ dir: Cal.localPath(Qt.resolvedUrl(".")) })

  Source {
    id: heySource
    backend: Hey
    enabled: root.heyEnabled
    context: root.sourceContext
    refreshIntervalSec: root.refreshIntervalSec
    liveSync: root.liveSync
    keepWeeks: root.baseWeeks().concat(root.visibleWeeks)
    onUpdated: root.sourceUpdated()
    onChangedRemotely: changeDebounce.restart()
  }

  Source {
    id: googleSource
    backend: Google
    enabled: root.googleEnabled
    context: root.sourceContext
    refreshIntervalSec: root.refreshIntervalSec
    liveSync: root.liveSync
    keepWeeks: root.baseWeeks().concat(root.visibleWeeks)
    onUpdated: root.sourceUpdated()
  }

  Source {
    id: feedSource
    backend: Feeds
    enabled: root.feedsEnabled
    context: root.sourceContext
    refreshIntervalSec: root.refreshIntervalSec
    liveSync: root.liveSync
    keepWeeks: root.baseWeeks().concat(root.visibleWeeks)
    onUpdated: root.sourceUpdated()
  }

  readonly property var sources: [heySource, googleSource, feedSource]
  // Bumped whenever a source changes, so the bindings below that walk the
  // sources are read again.
  property int sourcesRevision: 0
  readonly property var activeSources: {
    root.sourcesRevision
    var out = []
    for (var i = 0; i < root.sources.length; i++) if (root.sources[i].ready) out.push(root.sources[i])
    return out
  }

  // ---- What the panel reads, across every source.
  readonly property bool anySourceReady: activeSources.length > 0
  // Kept for the panel's "is there anything to write to?" checks: "" until
  // some service has answered.
  readonly property string backendMode: anySourceReady ? "ready" : ""
  readonly property string backendName: {
    root.sourcesRevision
    var names = []
    for (var i = 0; i < root.sources.length; i++)
      if (root.sources[i].enabled && !root.sources[i].missing) names.push(root.sources[i].name)
    return names.length > 0 ? names.join(", ") : heySource.name
  }
  readonly property var capabilities: {
    root.sourcesRevision
    var caps = { create: false, edit: false, delete: false, watch: false, timeTracking: heySource.ready, dayLink: daySource !== null }
    for (var i = 0; i < root.activeSources.length; i++) {
      var c = root.activeSources[i].capabilities
      if (c.create) caps.create = true
      if (c.edit) caps.edit = true
      if (c.delete) caps.delete = true
      if (c.watch) caps.watch = true
    }
    return caps
  }
  // The service whose web app the "open this day" button goes to: the first
  // with a page per day.
  readonly property var daySource: {
    root.sourcesRevision
    for (var i = 0; i < root.activeSources.length; i++)
      if (root.activeSources[i].capabilities.dayLink) return root.activeSources[i]
    return null
  }
  readonly property string dayLinkName: daySource ? daySource.name : ""

  property var events: []
  property var byDay: ({})
  property var calendars: []
  property var writableCalendars: []
  property var timeTrack: null
  // Finished time tracks by day, and the one waiting to be named: set when
  // a Stop lands, so the panel can ask for a name right away.
  property var timeTracks: []
  property var tracksByDay: ({})
  property string renameTrackId: ""
  property real stoppedAt: 0
  readonly property bool loading: {
    root.sourcesRevision
    for (var i = 0; i < root.sources.length; i++) if (root.sources[i].loading) return true
    return false
  }
  // "Nothing on today" and "we have not looked yet" are the same empty list
  // and very different things to put on screen.
  property bool loaded: false
  property string lastError: ""
  // The weeks the panel is showing, so a refresh re-reads what is on screen.
  property var visibleWeeks: []

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
    var keys = baseWeeks().concat(root.visibleWeeks)
    for (var i = 0; i < root.sources.length; i++) root.sources[i].refresh(keys, force === true)
    refreshTimeTrack()
  }

  function refreshTimeTrack() {
    if (!heySource.ready) return
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
    for (var i = 0; i < root.sources.length; i++)
      if (root.sources[i].ready) root.sources[i].requestWeeks(root.visibleWeeks, false)
  }

  // A source answered: its probe, its calendars or its weeks. A source that
  // has just become ready reads what is wanted.
  function sourceUpdated() {
    var wasReady = {}
    for (var i = 0; i < root.activeSources.length; i++) wasReady[root.activeSources[i].sourceId] = true
    root.sourcesRevision++
    for (var j = 0; j < root.activeSources.length; j++)
      if (!wasReady[root.activeSources[j].sourceId]) root.activeSources[j].refresh(baseWeeks().concat(root.visibleWeeks), true)
    if (heySource.ready && !wasReady.hey) refreshTimeTrack()
    if (!heySource.ready) {
      root.timeTrack = null
      root.timeTracks = []
      root.tracksByDay = ({})
    }
    rebuildIndex()
  }

  function rebuildIndex() {
    var all = []
    var lists = []
    var errors = []
    var anyReady = false
    var allLoaded = true
    for (var i = 0; i < root.sources.length; i++) {
      var source = root.sources[i]
      if (!source.enabled) continue
      if (source.ready) anyReady = true
      if (!source.loaded) allLoaded = false
      all = all.concat(source.mergedEvents())
      if (source.ready) lists.push({ name: source.name, calendars: source.calendars })
    }
    // A source with nothing set up (no feeds) has nothing to say, and HEY,
    // on by default, says its CLI is missing only when nothing else answers.
    var speaking = []
    for (var k = 0; k < root.sources.length; k++) {
      var s = root.sources[k]
      if (!s.enabled || s.error === "" || s.quiet || (s.missing && s === heySource && anyReady)) continue
      speaking.push(s)
    }
    for (var e = 0; e < speaking.length; e++)
      errors.push(speaking.length > 1 || root.activeSources.length > 0 ? speaking[e].name + ": " + speaking[e].error : speaking[e].error)
    root.events = Cal.withoutHidden(all, root.hiddenCalendars)
    root.byDay = Cal.indexByDay(root.events)
    root.calendars = Cal.mergeCalendars(lists)
    // The calendars a new event can go on, labelled as in the full list.
    root.writableCalendars = Cal.writableCalendars(root.calendars.filter(function(c) {
      var from = sourceById(c.source)
      return !!from && from.capabilities.create === true
    }))
    root.lastError = errors.join("\n")
    root.loaded = allLoaded || anyReady
    checkReminders()
  }

  function sourceById(id) {
    for (var i = 0; i < root.sources.length; i++) if (root.sources[i].sourceId === id) return root.sources[i]
    return null
  }

  function sourceOf(event) {
    return event ? sourceById(event.source) : null
  }

  // Forgets the cached copy of the weeks a change touched, and re-reads them.
  function invalidateDay(dayKey, source) {
    var keys = [Cal.weekStartKey(dayKey)].concat(root.visibleWeeks)
    if (source) source.invalidate(keys)
    else for (var i = 0; i < root.activeSources.length; i++) root.activeSources[i].invalidate(keys)
  }

  // Probes a service again: after its setup changed (a feed added, a
  // sign-in), so it is read without restarting the shell.
  function reloadSource(id) {
    var source = sourceById(id)
    if (!source || !source.enabled) return
    source.checked = false
    source.mode = ""
    source.weekCache = ({})
    source.calendars = []
    source.probe()
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
      var source = sourceOf(due[i].event)
      var reminder = Cal.notifyCommand(due[i].event, now, root.hour24,
        source ? source.dayUrl(Cal.eventDayKeys(due[i].event)[0] || "") : "", due[i].remindMs)
      notifyProcess.command = reminder.command
      notifyProcess.environment = reminder.environment
      notifyProcess.startDetached()
    }
    // Forgets what is long past, so the set does not grow for as long as the
    // shell runs.
    for (var old in shown) if (now - shown[old] > 2 * 86400000) delete shown[old]
    root.shownReminders = shown
  }

  // ---- Writes. Each one goes to the service it belongs to (Writer.qml),
  //      and re-reads what it changed once that service has answered.

  property string writeError: ""
  property bool writing: false
  property string writingDayKey: ""
  property var writingSource: null
  signal writeFinished(bool ok, string message)

  function beginWrite(dayKey, source, send) {
    if (root.writing || writer.running) return false
    root.writeError = ""
    root.writing = true
    root.writingDayKey = dayKey || ""
    root.writingSource = source || null
    if (!send()) {
      root.writing = false
      return false
    }
    return true
  }

  function refuseWrite(message) {
    root.writeError = message
    root.writeFinished(false, message)
    return false
  }

  function finishWrite(ok, message) {
    root.writing = false
    root.writeError = ok ? "" : message
    if (!ok) root.stoppedAt = 0
    if (root.writingDayKey !== "") invalidateDay(root.writingDayKey, root.writingSource)
    refreshTimeTrack()
    root.writeFinished(ok, message)
  }

  function addEvent(form) {
    var checked = Cal.validateEvent(form)
    if (checked.error) return refuseWrite(checked.error)
    var source = sourceById(checked.request.source)
    if (!source || !source.ready || !source.capabilities.create)
      return refuseWrite("Pick a calendar to put the event on.")
    if (source === heySource)
      return beginWrite(form.date, source, function() { return writer.heyCreate(checked.request) })
    var write = source.backend.writeCommand("create", checked.request, root.sourceContext)
    return beginWrite(form.date, source, function() { return writer.run(source.backend, write.command, write.input) })
  }

  function canEdit(event) {
    var source = sourceOf(event)
    return !!source && source.ready && source.capabilities.edit === true && event.editable !== false
  }

  function canDelete(event) {
    var source = sourceOf(event)
    if (!source || !source.ready || !source.capabilities.delete || !event || event.recurring || event.editable === false) return false
    return source.backend.canDelete(event)
  }

  // One day of a series can be edited alone: HEY's API and Google's take
  // occurrences.
  function editsOneDay(event) {
    return Cal.editsOneDay(event, true)
  }

  // The service an event belongs to, by name, for the form's "Open in".
  function serviceName(event) {
    var source = sourceOf(event)
    return source ? source.name : root.backendName
  }

  // The calendars an event can be moved to: its own service's.
  function calendarsFor(event) {
    if (!event) return root.writableCalendars
    return root.writableCalendars.filter(function(c) { return c.source === event.source })
  }

  // `before` is what the form opened with (Cal.eventFormValues), `form`
  // what it holds now; only the difference is sent.
  function editEvent(event, before, form) {
    var source = sourceOf(event)
    if (!source || !source.ready) return refuseWrite("OmaCal is not reading that event's calendar right now.")
    var checked = Cal.editRequest(event, before, form, form.scope, true,
      { service: source.name, clearsReminders: source.capabilities.clearsReminders === true })
    if (checked.error) return refuseWrite(checked.error)
    if (checked.unchanged) {
      root.writeError = ""
      root.writeFinished(true, "")
      return true
    }
    // The day it was on and the day it moves to both need reading again.
    var from = Cal.eventDayKeys(event)
    if (from.length > 0 && from[0] !== form.date) invalidateDay(from[0], source)
    if (source === heySource) {
      if (Api.editTarget(checked.request) === null)
        return refuseWrite("OmaCal cannot name that event to " + source.name + ". Edit it there.")
      return beginWrite(form.date, source, function() { return writer.heyEdit(checked.request) })
    }
    var write = source.backend.writeCommand("edit", checked.request, root.sourceContext)
    return beginWrite(form.date, source, function() { return writer.run(source.backend, write.command, write.input) })
  }

  function deleteEvent(event, dayKey) {
    if (!canDelete(event)) return false
    var source = sourceOf(event)
    var write = source.backend.writeCommand("delete", { event: event }, root.sourceContext)
    return beginWrite(dayKey, source, function() { return writer.run(source.backend, write.command, write.input) })
  }

  function startTimeTrack() {
    return beginWrite("", heySource, function() { return writer.run(Hey, Hey.trackStartCommand(), "") })
  }

  function stopTimeTrack() {
    root.stoppedAt = Date.now()
    return beginWrite("", heySource, function() { return writer.run(Hey, Hey.trackStopCommand(), "") })
  }

  function renameTimeTrack(id, name) {
    root.renameTrackId = ""
    return beginWrite("", heySource, function() { return writer.heyRenameTrack(id, name) })
  }

  function deleteTimeTrack(id) {
    return beginWrite("", heySource, function() { return writer.run(Hey, Hey.trackDeleteCommand(id), "") })
  }

  // The page for a day in the service that has one, or "".
  function dayUrl(dayKey) {
    return root.daySource ? root.daySource.dayUrl(dayKey) : ""
  }

  // What each service says about which of its calendars are left out.
  function modeNote() {
    var notes = []
    for (var i = 0; i < root.activeSources.length; i++) {
      var note = root.activeSources[i].modeNote()
      if (note !== "") notes.push(note)
    }
    return notes.join(" ")
  }

  // The settings' view of one service: whether it is on, answering, and as
  // whom, or what is wrong.
  function sourceStatus(id) {
    root.sourcesRevision
    var source = sourceById(id)
    if (!source) return { enabled: false, ready: false, account: "", error: "", name: "" }
    return { enabled: source.enabled, ready: source.ready, account: source.account, error: source.error,
      name: source.name, missing: source.missing, checked: source.checked, calendars: source.calendars.length }
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

  // Reminders are checked off the cached events, not off the services, so this is
  // cheap enough to run often and lands within seconds of the minute.
  Timer {
    interval: 15000
    running: root.notificationsEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkReminders()
  }

  // Never run itself: each reminder starts a detached copy, which outlives
  // this widget and carries the event's text in its environment, not its
  // arguments (see notifyCommand). execDetached takes only arguments.
  Process {
    id: notifyProcess
    running: false
    command: []
  }

  Process {
    id: timeTrackProcess
    running: false
    command: Hey.currentTrackCommand
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
    command: Hey.tracksCommand
    stdout: StdioCollector {
      onStreamFinished: root.applyTimeTracks(text)
    }
  }

  Writer {
    id: writer
    onFinished: function(ok, message) { root.finishWrite(ok, message) }
  }

  // Any change a service streams re-reads what is on screen, debounced so a
  // burst of edits costs one fetch.
  Timer {
    id: changeDebounce
    interval: 1500
    onTriggered: root.refreshCalendar(true)
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
      if (root.lastError !== "") return root.lastError
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
