import QtQuick
import Quickshell
import Quickshell.Io
import "ShortcutModel.js" as ShortcutModel
import "backends/Hey.js" as Backend

// One per shell, unlike the bar widget, which has an instance on every
// monitor's bar. That is why the quick-add shortcut lives here: two widgets
// binding it would bind it twice, and one key press would open the card and
// close it again.
//
// The watch lives here for the same reason. One `hey watch` per shell, and
// each bar widget refreshes when `watchSerial` moves. A custom bar that
// cannot see this service keeps the widget's polling fallback.
//
// The shortcut and live sync are settings on the widget's entry in
// shell.json, so they are set where every other HEY Calendar setting is.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string moduleName: "crmne.omacal"

  readonly property var widgetEntry: {
    var config = root.shell ? root.shell.barConfig : null
    var layout = config && config.layout ? config.layout : {}
    for (var section in layout) {
      var entries = Array.isArray(layout[section]) ? layout[section] : []
      for (var i = 0; i < entries.length; i++)
        if (entries[i] && entries[i].id === root.moduleName) return entries[i]
    }
    return null
  }

  readonly property string quickAddShortcut: widgetEntry && widgetEntry.quickAddShortcut !== undefined && widgetEntry.quickAddShortcut !== null
    ? String(widgetEntry.quickAddShortcut)
    : ShortcutModel.DEFAULT

  readonly property bool liveSync: widgetEntry ? widgetEntry.liveSync !== false : true

  property string backendMode: ""
  property bool backendChecked: false
  property int watchSerial: 0

  function startWatch() {
    if (!root.liveSync || root.backendMode === "" || !Backend.info.capabilities.watch) {
      watchProcess.running = false
      return
    }
    if (watchProcess.running) return
    watchProcess.command = Backend.watchCommand()
    watchProcess.running = true
  }

  function onProbed(text) {
    var probed = Backend.probe(text)
    if (probed.path) Backend.rememberHey(probed.path)
    root.backendMode = probed.mode
    root.backendChecked = true
    root.startWatch()
  }

  onLiveSyncChanged: {
    if (root.liveSync) root.startWatch()
    else watchProcess.running = false
  }

  ShortcutManager {
    enabled: root.shell !== null
    value: root.quickAddShortcut
  }

  Process {
    id: versionProcess
    running: false
    command: Backend.probeCommand
    stdout: StdioCollector {
      onStreamFinished: root.onProbed(text)
    }
  }

  // A burst of edits costs one refresh. The widgets read watchSerial.
  Timer {
    id: changeDebounce
    interval: 1500
    onTriggered: root.watchSerial += 1
  }

  Process {
    id: watchProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) {
        if (Backend.isWatchChange(line)) changeDebounce.restart()
      }
    }
    // A watch that dies (signed out, network gone, CLI upgraded under it)
    // is restarted after a pause rather than in a tight loop.
    onExited: if (root.liveSync && root.backendMode !== "") watchRestart.restart()
  }

  Timer {
    id: watchRestart
    interval: 60000
    onTriggered: if (root.liveSync && root.backendMode !== "" && !watchProcess.running) root.startWatch()
  }

  Component.onCompleted: if (!versionProcess.running) versionProcess.running = true
}
