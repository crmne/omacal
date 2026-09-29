import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  id: root
  property bool submitted: false
  Plugin.BarWidget {
    id: widget
    settings: ({ backend: "google", googleAccount: "calendar@example.test", notifications: false })
    onWriteFinished: function(ok, message) {
      if (!ok) throw new Error("Fixture write failed: " + message)
      quickAdd.submit({title: "Fixture write", date: "2026-09-28", allDay: true,
                       calendarId: "calendar@example.test"})
    }
  }
  Plugin.QuickAdd {
    id: quickAdd
    shell: QtObject {
      property var barConfig: ({ layout: { center: [{ id: "crmne.omacal", backend: "google", googleAccount: "calendar@example.test" }] } })
      function hide(id) {
        if (quickAdd.error !== "" || quickAdd.busy) throw new Error("Quick-add write did not finish")
        console.log("OMACAL_QML_SMOKE_OK")
        Qt.quit()
      }
    }
  }
  Plugin.QuickAdd { id: heyQuickAdd }
  Plugin.EventForm {
    id: form
    calendars: widget.writableCalendars
    defaultCalendarId: "calendar@example.test"
  }
  Timer {
    interval: 100
    running: true
    repeat: true
    onTriggered: {
      if (!widget.loaded || widget.calendars.length === 0 || root.submitted) return
      if (widget.lastError !== "") throw new Error(widget.lastError)
      if (widget.events.length === 0) throw new Error("No fixture events")
      if (widget.events[0].calendarId !== "calendar@example.test") throw new Error("Lost calendar ID")
      if (form.calendarId !== "calendar@example.test") throw new Error("Form lost calendar ID")
      if (quickAdd.backend.info.id !== "google") throw new Error("Quick add uses wrong backend")
      if (heyQuickAdd.backend.info.id !== "hey") throw new Error("Default HEY backend changed")
      if (widget.capabilities.watch || widget.capabilities.timeTracking) throw new Error("Wrong capabilities")
      root.submitted = true
      if (!widget.addEvent({title: "Fixture write", date: "2026-09-28", allDay: true,
                           calendarId: form.calendarId})) throw new Error("Write did not start")
    }
  }
}
