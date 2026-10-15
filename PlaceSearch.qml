import QtQuick
import Quickshell
import Quickshell.Io
import "Places.js" as Places

// Looks up places for the form's "Where?" field while it is typed in: a
// moment after the typing stops, one request at a time, the older one
// dropped when a newer is sent. Google Places when the key file holds a
// key, else OpenStreetMap (see Places.js).
//
// The key lives in its own file, readable only by you, rather than in
// shell.json next to everything else: SettingsView writes it.
Item {
  id: root

  // The text to look up, and whether to (the field has the keyboard, the
  // setting is on, and the text is not a suggestion just picked).
  property string query: ""
  property bool active: false
  // This machine's zone, whose city the lookups favour.
  property string zone: ""
  property var near: null

  readonly property string keyPath: Places.keyPath(Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME"))
  property string googleKey: ""
  readonly property string provider: Places.isGoogleKey(root.googleKey) ? "google" : "photon"

  property var results: []
  property string error: ""
  property bool searching: false

  property var xhr: null
  property int generation: 0
  // One Google session per form, from first keystroke to pick: Google
  // bills the lookups of a session together.
  property string sessionToken: ""

  function newSession() {
    var chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    var token = ""
    for (var i = 0; i < 32; i++) token += chars.charAt(Math.floor(Math.random() * chars.length))
    root.sessionToken = token
  }

  function clear() {
    cancel()
    root.results = []
    root.error = ""
  }

  function cancel() {
    debounce.stop()
    deadline.stop()
    root.generation++
    if (root.xhr) root.xhr.abort()
    root.xhr = null
    root.searching = false
  }

  // Picking a place ends the session: the next lookup starts another.
  function picked() {
    clear()
    newSession()
  }

  function send() {
    cancel()
    var spec = Places.request(root.query, root.googleKey, root.sessionToken, Qt.locale().name, root.near)
    if (!spec) {
      root.results = []
      root.error = ""
      return
    }
    var epoch = root.generation
    var request = new XMLHttpRequest()
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE || epoch !== root.generation) return
      deadline.stop()
      root.xhr = null
      root.searching = false
      if (request.status >= 200 && request.status < 300) {
        root.results = Places.parse(spec.provider, request.responseText)
        root.error = ""
      } else {
        root.results = []
        root.error = Places.failure(spec.provider, request.status, request.responseText)
      }
    }
    request.open(spec.method, spec.url)
    for (var name in spec.headers) request.setRequestHeader(name, spec.headers[name])
    root.xhr = request
    root.searching = true
    deadline.restart()
    request.send(spec.body)
  }

  onQueryChanged: if (root.active) debounce.restart()
  onActiveChanged: if (!root.active) clear()
  Component.onCompleted: newSession()
  Component.onDestruction: cancel()

  Timer {
    id: debounce
    interval: 300
    onTriggered: root.send()
  }

  // A lookup that has not answered by now is not going to be useful.
  Timer {
    id: deadline
    interval: 8000
    onTriggered: {
      root.cancel()
      root.results = []
    }
  }

  FileView {
    id: zoneTable
    path: "/usr/share/zoneinfo/zone1970.tab"
    printErrors: false
    onLoaded: root.near = Places.zoneCoordinates(text(), root.zone)
  }

  onZoneChanged: root.near = Places.zoneCoordinates(zoneTable.text(), root.zone)

  FileView {
    id: keyFile
    path: root.keyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.googleKey = String(text()).replace(/\s+/g, "")
    onLoadFailed: root.googleKey = ""
  }
}
