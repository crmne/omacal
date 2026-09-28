import QtQuick
import qs.Commons
import qs.Ui
import "Hey.js" as Hey

// A new event on the selected day, the fields HEY's own quick form asks
// for: a title, which calendar, when, where, and a reminder.
//
// Times are typed, not picked: "9", "930", "9:30pm" and "21.30" all work,
// and an end earlier than the start is read as the next morning. The event
// is created through `hey event add`, so HEY applies its own defaults to
// anything left blank.
//
// Enter creates, Escape cancels, Tab walks the text fields.
Item {
  id: root

  property string dayKey: ""
  property var calendars: []
  property int defaultCalendarId: 0
  property bool busy: false
  property string error: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal submitted(var form)
  signal canceled()

  property int calendarId: 0
  property bool allDay: false
  property string remind: "30m"

  readonly property string dayLabel: Hey.isDayKey(dayKey)
    ? Qt.formatDate(Hey.dateFromKey(dayKey), "ddd d MMMM").toUpperCase()
    : ""

  implicitHeight: formColumn.implicitHeight

  // Called each time the form opens, so a second event does not inherit
  // the first one's title.
  function reset() {
    titleField.text = ""
    locationField.text = ""
    var start = Hey.suggestedStart(root.dayKey, new Date())
    startField.text = start
    endField.text = ""
    root.allDay = false
    root.remind = "30m"
    root.error = ""
    root.calendarId = pickCalendar(root.defaultCalendarId)
    Qt.callLater(function() { titleField.forceActiveFocus() })
  }

  function pickCalendar(preferred) {
    for (var i = 0; i < root.calendars.length; i++)
      if (root.calendars[i].id === preferred) return preferred
    return root.calendars.length > 0 ? root.calendars[0].id : 0
  }

  function submit() {
    if (root.busy) return
    root.submitted({
      title: titleField.text,
      date: root.dayKey,
      allDay: root.allDay,
      startTime: startField.text,
      endTime: endField.text,
      calendarId: root.calendarId,
      location: locationField.text,
      remind: root.remind
    })
  }

  // The fields share one key handler: Enter creates, Escape backs out, Tab
  // hops to the next field that is showing.
  function handleKey(event, next) {
    if (event.key === Qt.Key_Escape) {
      root.canceled()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.submit()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab && next) {
      next.selectAll()
      next.forceActiveFocus()
      event.accepted = true
    }
  }

  onCalendarsChanged: if (root.calendarId === 0) root.calendarId = pickCalendar(root.defaultCalendarId)

  Column {
    id: formColumn
    width: parent.width
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      text: "NEW EVENT · " + root.dayLabel
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }

    TextField {
      id: titleField
      width: parent.width
      placeholderText: "What's happening?"
      foreground: root.foreground
      font.family: root.fontFamily
      Keys.onPressed: function(event) { root.handleKey(event, root.allDay ? locationField : startField) }
    }

    // Calendars as HEY paints them: a pastel pill each, the chosen one
    // outlined. A list this short reads faster as colors than as a menu.
    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.calendars

        Rectangle {
          required property var modelData
          readonly property bool chosen: modelData.id === root.calendarId
          width: calendarName.implicitWidth + Style.space(20)
          height: calendarName.implicitHeight + Style.space(8)
          radius: height / 2
          color: Hey.calendarColor(modelData.color, root.accent)
          opacity: chosen || calendarMouse.containsMouse ? 1 : 0.55
          border.width: chosen ? 2 : 0
          border.color: root.foreground

          Text {
            id: calendarName
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: modelData.name
            color: Hey.calendarInk
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: parent.chosen
          }

          MouseArea {
            id: calendarMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.calendarId = modelData.id
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(10)

      Button {
        id: allDayButton
        anchors.verticalCenter: parent.verticalCenter
        text: "All day"
        iconText: root.allDay ? "󰄵" : "󰄱"
        bordered: true
        selected: root.allDay
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.allDay = !root.allDay
      }

      Text {
        visible: !root.allDay
        anchors.verticalCenter: parent.verticalCenter
        leftPadding: Style.space(6)
        text: "FROM"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.letterSpacing: 1
      }

      TextField {
        id: startField
        visible: !root.allDay
        width: Style.space(76)
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: "09:00"
        foreground: root.foreground
        font.family: root.fontFamily
        Keys.onPressed: function(event) { root.handleKey(event, endField) }
      }

      Text {
        visible: !root.allDay
        anchors.verticalCenter: parent.verticalCenter
        text: "TO"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.letterSpacing: 1
      }

      TextField {
        id: endField
        visible: !root.allDay
        width: Style.space(76)
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: "+1 h"
        foreground: root.foreground
        font.family: root.fontFamily
        Keys.onPressed: function(event) { root.handleKey(event, locationField) }
      }
    }

    TextField {
      id: locationField
      width: parent.width
      placeholderText: "Where? (optional)"
      foreground: root.foreground
      font.family: root.fontFamily
      Keys.onPressed: function(event) { root.handleKey(event, titleField) }
    }

    Row {
      spacing: Style.space(10)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "REMIND"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.letterSpacing: 1
      }

      ButtonGroup {
        anchors.verticalCenter: parent.verticalCenter
        focusable: false
        options: [
          { value: "", label: "None" },
          { value: "10m", label: "10m" },
          { value: "30m", label: "30m" },
          { value: "1h", label: "1h" },
          { value: "1d", label: "1d" }
        ]
        value: root.remind
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onChanged: function(value) { root.remind = value }
      }
    }

    Item {
      width: parent.width
      height: createButton.implicitHeight

      Text {
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: cancelButton.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: root.busy ? "Adding to HEY…" : root.error
        color: root.busy ? Qt.darker(root.foreground, 1.4) : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Button {
        id: cancelButton
        anchors.right: createButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: "Cancel"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.canceled()
      }

      Button {
        id: createButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Add event"
        iconText: "󰐕"
        bordered: true
        enabled: !root.busy
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.submit()
      }
    }
  }
}
