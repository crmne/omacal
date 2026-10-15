import QtQuick
import Quickshell.Io
import "TimeZones.js" as Zones
import "backends/HeyApi.js" as Api

// Sends the writes that carry what you typed (an event's title and place,
// a track's name) to HEY's API, so none of it is ever on a command line.
//
// hey-cli hands over its access token on stdout when a write starts; it is
// kept in memory until the write is done, sent only in the Authorization
// header over HTTPS, and never written, logged or passed as an argument.
// HeyApi.js plans each write and this does the sending: what to read first
// (HEY's update replaces, so an edit reads the event and sends back what it
// does not change), which zone files to load, then the write itself.
Item {
  id: root
  visible: false

  property bool running: false
  signal finished(bool ok, string message)

  property var job: null
  property var progress: ({})
  property string baseUrl: ""
  property string token: ""
  // HEY refused the token once and hey-cli renewed it: a second refusal is
  // the answer.
  property bool renewed: false
  property var retry: null
  property var xhr: null
  property int generation: 0
  property int requests: 0

  // A write reads at most this many pages before it gives up.
  readonly property int maximumRequests: 120

  function create(request) {
    return start({ kind: "create", request: request })
  }

  function edit(request) {
    return start({ kind: "edit", request: request })
  }

  function renameTrack(id, name) {
    return start({ kind: "renameTrack", id: id, name: name })
  }

  function start(job) {
    if (root.running) return false
    root.job = job
    root.progress = { answers: {}, zones: {}, today: Qt.formatDate(new Date(), "yyyy-MM-dd") }
    root.renewed = false
    root.retry = null
    root.requests = 0
    root.running = true
    signIn(false)
    return true
  }

  function signIn(renew) {
    sessionProcess.epoch = root.generation
    sessionProcess.command = Api.sessionCommand(renew)
    sessionProcess.running = true
    deadline.restart()
  }

  function signedIn(output, epoch) {
    if (!root.running || epoch !== root.generation) return
    deadline.stop()
    var session = Api.parseSession(output)
    if (session.error) {
      done(false, session.error)
      return
    }
    root.baseUrl = session.baseUrl
    root.token = session.token
    var again = root.retry
    root.retry = null
    if (again) again()
    else advance()
  }

  function done(ok, message) {
    deadline.stop()
    root.generation++
    sessionProcess.running = false
    if (root.xhr) root.xhr.abort()
    root.xhr = null
    root.token = ""
    root.job = null
    root.progress = ({})
    root.retry = null
    root.running = false
    root.finished(ok, message)
  }

  function advance() {
    if (!root.running) return
    var next
    try {
      next = Api.step(root.job, root.progress)
    } catch (e) {
      done(false, "OmaCal could not work out that change. Make it in HEY.")
      return
    }
    if (next.error) {
      done(false, next.error)
    } else if (next.zones) {
      loadZones(next.zones)
      Qt.callLater(advance)
    } else if (next.read) {
      if (++root.requests > root.maximumRequests) {
        done(false, "HEY has too much to read through for that change. Make it in HEY.")
        return
      }
      var key = next.read.key
      send("GET", next.read.path, null, null, function(status, body, link) {
        root.progress.answers[key] = Api.answer(status, body, link)
        advance()
      })
    } else if (next.write) {
      var write = next.write
      send(write.method, write.path, write.headers, write.body, function(status, body) {
        var result = Api.writeResult(write, status, body)
        done(result.ok, result.message)
      })
    } else {
      done(false, "OmaCal could not work out that change. Make it in HEY.")
    }
  }

  // Each zone from its own file; one that is missing or unreadable is null,
  // and the plan says so.
  function loadZones(names) {
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      var zone = null
      var path = Zones.zonePath(name)
      if (path !== "") {
        var file = zoneFile.createObject(root, { path: path })
        try {
          file.waitForJob()
          zone = Zones.parse(file.data())
        } catch (e) {
          zone = null
        }
        file.destroy()
      }
      root.progress.zones[name] = zone
    }
  }

  function send(method, path, headers, body, callback) {
    var epoch = ++root.generation
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      if (epoch !== root.generation) return
      if (request.readyState === XMLHttpRequest.LOADING
          && String(request.responseText).length > Api.responseByteLimit) {
        done(false, "HEY answered with more than OmaCal will read.")
        return
      }
      if (request.readyState !== XMLHttpRequest.DONE) return
      deadline.stop()
      root.xhr = null
      if (request.status === 401 && !root.renewed) {
        // hey-cli renews a token that has run out; then the same request
        // goes again, once.
        root.renewed = true
        root.retry = function() { send(method, path, headers, body, callback) }
        signIn(true)
        return
      }
      callback(request.status, request.responseText, request.getResponseHeader("Link"))
    }
    request.open(method, root.baseUrl + path)
    var all = Api.headers(root.token, headers)
    for (var name in all) request.setRequestHeader(name, all[name])
    root.xhr = request
    deadline.restart()
    if (body === null) request.send()
    else request.send(body)
  }

  Component.onCompleted: Api.useZones(Zones)
  Component.onDestruction: {
    root.generation++
    if (root.xhr) root.xhr.abort()
    root.token = ""
  }

  Timer {
    id: deadline
    interval: Api.requestTimeoutMs
    onTriggered: if (root.running) root.done(false, "HEY took too long to answer.")
  }

  Component {
    id: zoneFile
    FileView {
      blockLoading: true
      printErrors: false
    }
  }

  Process {
    id: sessionProcess
    running: false
    command: []
    property int epoch: 0
    stdout: StdioCollector {
      onStreamFinished: root.signedIn(text, sessionProcess.epoch)
    }
  }
}
