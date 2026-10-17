import QtQuick
import Quickshell.Io

// Sends a write to the service it belongs to, one at a time, and says how
// it went. The bar widget and the quick-add card both write through this.
//
// HEY's writes that carry what you typed go to HEY's API (ApiWriter.qml);
// its others run hey-cli with ids only. A backend with a helper (Google)
// takes the write on the helper's stdin, so an event's title and place are
// never on a command line: `command` names only the action.
Item {
  id: root
  visible: false

  readonly property bool running: apiWriter.running || cliProcess.running || cliProcess.pending
  signal finished(bool ok, string message)

  // HEY's API: create, edit and rename a track.
  function heyCreate(request) {
    if (root.running) return false
    return apiWriter.create(request)
  }

  function heyEdit(request) {
    if (root.running) return false
    return apiWriter.edit(request)
  }

  function heyRenameTrack(id, name) {
    if (root.running) return false
    return apiWriter.renameTrack(id, name)
  }

  // A command line, with `input` on its stdin ("" for none), answered by
  // `backend.writeResult`.
  function run(backend, command, input) {
    if (root.running || !command || command.length === 0) return false
    cliProcess.backend = backend
    cliProcess.input = String(input || "")
    cliProcess.finished = false
    cliProcess.output = null
    cliProcess.code = null
    cliProcess.pending = true
    cliProcess.command = command
    cliProcess.stdinEnabled = true
    cliProcess.running = true
    return true
  }

  // Answered once both the output and the exit status are in, whichever
  // comes first; a process that dies before its output is finished is
  // answered a moment after it exits.
  function finishCli() {
    if (cliProcess.finished || cliProcess.code === null) return
    if (cliProcess.output === null && !outputGrace.expired) {
      outputGrace.restart()
      return
    }
    cliProcess.finished = true
    cliProcess.pending = false
    outputGrace.expired = false
    var result = cliProcess.backend.writeResult(cliProcess.code, cliProcess.output === null ? "" : cliProcess.output)
    root.finished(result.ok, result.message)
  }

  ApiWriter {
    id: apiWriter
    onFinished: function(ok, message) { root.finished(ok, message) }
  }

  Process {
    id: cliProcess
    running: false
    command: []
    property var backend: null
    property string input: ""
    property bool finished: false
    property var output: null
    property var code: null
    // Set from the moment a write is asked for until it is answered, so a
    // second one cannot start while the first is still starting.
    property bool pending: false
    stdinEnabled: true
    onStarted: {
      if (input !== "") write(input)
      input = ""
      // Closing stdin is what tells the helper the request is complete.
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        cliProcess.output = text
        root.finishCli()
      }
    }
    onExited: function(exitCode) {
      cliProcess.code = exitCode
      root.finishCli()
    }
  }

  Timer {
    id: outputGrace
    property bool expired: false
    interval: 250
    onTriggered: {
      expired = true
      root.finishCli()
    }
  }
}
