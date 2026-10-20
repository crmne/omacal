import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  id: root
  property int phase: 0
  Plugin.ApiWriter {
    id: writer
    onFinished: function(ok, message) {
      if (!ok) { console.error("TRANSPORT FAILED: " + message); Qt.exit(1); return }
      root.phase++
      if (root.phase === 1) {
        Qt.callLater(function() {
          writer.edit({ event: { seriesId: "41", calendarId: 7, startMs: Date.parse("2027-12-31T09:00:00Z") },
            changes: { title: "Updated synthetic event" }, scope: "all" })
        })
      } else if (root.phase === 2) {
        Qt.callLater(function() { writer.renameTrack("123", "Synthetic track") })
      } else {
        if (writer.token !== "" || writer.job !== null) { Qt.exit(2); return }
        console.log("TRANSPORT PASSED")
        Qt.quit()
      }
    }
  }
  Component.onCompleted: writer.create({ title: "Synthetic event", date: "2027-12-31", startTime: "10:00",
    endTime: "11:30", timeZone: "Europe/Berlin", location: "Synthetic place", calendarId: 7, remind: "30m" })
  Timer { interval: 15000; running: true; onTriggered: Qt.exit(3) }
}
