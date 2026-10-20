import QtQuick
import Quickshell.Io
import "Calendar.js" as Cal

// One calendar service Calendar for Omarchy reads: HEY, Google, or the calendar feeds.
// It asks its backend (backends/*.js) whether it can run, reads the weeks
// it is asked for, keeps them by their Monday, lists the calendars, and
// follows the service's changes when it can stream them. BarWidget.qml
// holds one per service and lays them over each other; nothing here knows
// about any other source.
//
// A backend's commands are arrays, or functions given `context` (where the
// plugin is, for the backends that run a helper next to their file).
Item {
  id: root
  visible: false

  property var backend: null
  property bool enabled: false
  property var context: ({})
  property int refreshIntervalSec: 300
  property bool liveSync: true
  // Whether the calendars are listed even when weeks are not read: the
  // quick-add card needs only the calendars.
  property bool readsWeeks: true

  readonly property string sourceId: backend ? backend.info.id : ""
  readonly property string name: backend ? backend.info.name : ""
  readonly property var capabilities: backend ? backend.info.capabilities : ({})

  // How the probe said to read the service ("" until it has answered, or
  // when it never will), and what it said about itself.
  property string mode: ""
  property string version: ""
  property string account: ""
  property bool checked: false
  // The service's tool is not installed at all, which for a service the
  // user never set up is not worth a word.
  property bool missing: false
  // Nothing is set up for it (no feeds), which is not an error at all.
  property bool quiet: false
  readonly property bool ready: enabled && mode !== ""

  property var weekCache: ({})
  property var calendars: []
  property bool loading: false
  property bool loaded: false
  property string error: ""
  property var queuedWeeks: []
  property var fetchingWeeks: []
  // The weeks the caller wants kept: the ones on screen and the ones whose
  // reminders can come due.
  property var keepWeeks: []

  // New weeks landed, or the service went away: the caller merges again.
  signal updated()
  // The service changed something on its side (its live watch said so).
  signal changedRemotely()

  function command(value) {
    return typeof value === "function" ? value(root.context) : (value || [])
  }

  function probe() {
    if (!root.enabled || !root.backend || versionProcess.running) return
    versionProcess.command = command(root.backend.probeCommand)
    versionProcess.running = true
  }

  // `keys` are the weeks wanted now; `force` re-reads ones still fresh.
  function refresh(keys, force) {
    if (!root.enabled || !root.backend) return
    // Not answering yet, or not set up when last asked (gws signed out, no
    // feeds): a refresh asks again, so setting it up needs no restart.
    if (!root.checked || (root.mode === "" && force === true)) {
      probe()
      return
    }
    if (root.mode === "") return
    if (root.readsWeeks) requestWeeks(keys, force === true)
    if (!calendarsProcess.running) {
      calendarsProcess.command = command(root.backend.calendarsCommand)
      calendarsProcess.running = true
    }
  }

  function weekIsFresh(key) {
    var entry = root.weekCache[key]
    return !!entry && entry.events !== null && (Date.now() - entry.at) < root.refreshIntervalSec * 1000
  }

  function requestWeeks(keys, force) {
    if (root.mode === "") return
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
    weekProcess.command = root.backend.fetchCommand(root.mode, wanted, root.context)
    weekProcess.running = true
  }

  function applyWeeks(exitCode, stdout) {
    root.loading = false
    var parsed = Cal.parseRangeOutput(stdout, root.sourceId)
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
    var keys = Object.keys(cache)
    if (keys.length > 16) {
      for (var k = 0; k < keys.length; k++)
        if (root.keepWeeks.indexOf(keys[k]) === -1) delete cache[keys[k]]
    }

    // An empty answer is the shape every failure takes here (the tool is
    // missing, signed out, or offline), so the panel says so rather than
    // showing a week that looks clear.
    var said = failed ? Cal.rangeOutputError(stdout) : ""
    root.error = !failed ? ""
      : (said !== "" ? said
        : (exitCode === 0 ? root.name + " did not answer. Is it signed in?" : root.name + " exited with status " + exitCode + "."))
    root.weekCache = cache
    root.loaded = true
    root.fetchingWeeks = []
    root.updated()

    if (root.queuedWeeks.length > 0) {
      var next = root.queuedWeeks
      root.queuedWeeks = []
      requestWeeks(next, true)
    }
  }

  // The weeks a change touched, read again.
  function invalidate(keys) {
    requestWeeks(keys, true)
  }

  function mergedEvents() {
    return root.enabled ? Cal.mergeWeeks(root.weekCache) : []
  }

  function modeNote() {
    return root.backend && root.backend.modeNote ? root.backend.modeNote(root.mode, root.version) : ""
  }

  function dayUrl(dayKey) {
    return root.capabilities.dayLink && root.backend.dayUrl ? root.backend.dayUrl(dayKey, root.account) : ""
  }

  // Switched off: forget what it read, so a service turned off leaves the
  // calendar with it. Switched on: ask again.
  onEnabledChanged: {
    if (root.enabled) {
      probe()
      return
    }
    root.mode = ""
    root.checked = false
    root.missing = false
    root.quiet = false
    root.error = ""
    root.weekCache = ({})
    root.calendars = []
    root.loaded = false
    root.updated()
  }

  Component.onCompleted: if (root.enabled) probe()

  // Applied once both the output and the exit status are in. A process
  // that dies before its stream finishes never reaches the collector, so
  // the spinner would stay up forever without the grace timer.
  Process {
    id: weekProcess
    running: false
    command: []
    property var output: null
    property var code: null
    onStarted: {
      output = null
      code = null
    }
    stdout: StdioCollector {
      onStreamFinished: {
        weekProcess.output = text
        if (weekProcess.code !== null && root.loading) root.applyWeeks(weekProcess.code, text)
      }
    }
    onExited: function(exitCode) {
      weekProcess.code = exitCode
      if (weekProcess.output !== null) {
        if (root.loading) root.applyWeeks(exitCode, weekProcess.output)
      } else {
        weekGrace.restart()
      }
    }
  }

  Timer {
    id: weekGrace
    interval: 250
    onTriggered: if (root.loading) root.applyWeeks(weekProcess.code, weekProcess.output === null ? "" : weekProcess.output)
  }

  // Asked once. The answer decides how weeks are read, and a missing or
  // signed-out service is said plainly rather than shown as empty days.
  Process {
    id: versionProcess
    running: false
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.enabled) return
        var probed = root.backend.probe(text)
        root.version = probed.version || ""
        root.account = probed.account || ""
        root.mode = probed.mode || ""
        root.missing = probed.missing === true
        root.quiet = probed.quiet === true
        root.checked = true
        root.error = root.mode === "" ? (probed.error || root.name + " could not start.") : ""
        if (root.mode === "") root.loaded = true
        else if (!calendarsProcess.running) {
          calendarsProcess.command = root.command(root.backend.calendarsCommand)
          calendarsProcess.running = true
        }
        root.updated()
      }
    }
  }

  Process {
    id: calendarsProcess
    running: false
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Cal.parseCalendars(text, root.sourceId)
        if (parsed !== null && root.enabled) {
          root.calendars = parsed
          root.updated()
        }
      }
    }
  }

  // ---- Live sync, for backends that can stream their changes (HEY: `hey
  //      watch`). The caller debounces, so a burst of edits costs one read.
  //      Polling stays as the fallback for when the watch is down.
  Process {
    id: watchProcess
    running: root.readsWeeks && root.liveSync && root.ready && root.capabilities.watch === true
    command: root.backend && root.capabilities.watch ? root.command(root.backend.watchCommand) : []
    stdout: SplitParser {
      onRead: function(line) {
        if (root.backend.isWatchChange(line)) root.changedRemotely()
      }
    }
    // A watch that dies (signed out, network gone, CLI upgraded under it)
    // is restarted after a pause rather than in a tight loop.
    onExited: if (root.liveSync && root.ready) watchRestart.restart()
  }

  Timer {
    id: watchRestart
    interval: 60000
    onTriggered: if (root.liveSync && root.ready && root.capabilities.watch && !watchProcess.running) watchProcess.running = true
  }
}
