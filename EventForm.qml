import QtQuick
import qs.Commons
import qs.Ui
import "Hey.js" as Hey

// A new event, with the fields HEY's own quick form asks for: a title,
// which calendar, which day, when, where, and a reminder. The calendar
// panel's + button and the Alt+Shift+Space quick-add card are both this.
//
// Days and times are typed, not picked: "fri", "tomorrow", "3 oct" for the
// day; "9", "930", "9:30pm", "21.30" for times. An end earlier than the
// start is read as the next morning. The event
// is created through `hey event add`, so HEY applies its own defaults to
// anything left blank.
//
// Built to be used without a mouse. Tab and Shift+Tab walk every field,
// the calendar row and the reminder row included; on those rows the arrow
// keys pick. Up and Down nudge a time by a quarter hour and the day by one
// (Shift: a week). From any field, Alt+Left/Right switches calendar,
// Alt+Up/Down the reminder, and Alt+A toggles all day. Enter creates,
// Escape cancels. A hint line says what the keys do where the focus is.
Item {
  id: root

  // The day the form starts on. The panel passes its selected day; the
  // quick-add card leaves it to today.
  property string dayKey: ""
  property string todayKey: ""
  readonly property string resolvedDay: Hey.parseDay(dateField.text, todayKey !== "" ? todayKey : Hey.keyForDate(new Date()))
  property var calendars: []
  property int defaultCalendarId: 0
  property bool busy: false
  // `error` comes from whoever runs the command; `localError` is the form's
  // own complaint about what was typed, and wins while it stands.
  property string error: ""
  property string localError: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal submitted(var form)
  signal canceled()

  property int calendarId: 0
  property bool allDay: false
  property string remind: "30m"

  readonly property var reminderValues: ["", "10m", "30m", "1h", "1d"]
  readonly property var calendarIds: {
    var ids = []
    for (var i = 0; i < root.calendars.length; i++) ids.push(root.calendars[i].id)
    return ids
  }
  readonly property string chosenCalendarName: {
    for (var i = 0; i < root.calendars.length; i++)
      if (root.calendars[i].id === root.calendarId) return root.calendars[i].name
    return ""
  }

  // What the keys do where the focus is, one line under the form.
  readonly property string keyHint: {
    if (calendarRow.activeFocus) return "←→ calendar · Tab next · Enter add · Esc cancel"
    if (remindRow.activeFocus) return "←→ reminder · Tab next · Enter add · Esc cancel"
    if (allDayRow.activeFocus) return "Space all day · Tab next · Enter add · Esc cancel"
    if (dateField.activeFocus) return "↑↓ day, Shift a week · Tab next · Alt+←→ calendar · Enter add"
    if (startField.activeFocus || endField.activeFocus) return "↑↓ 15 min · Tab next · Alt+←→ calendar · Enter add"
    return "Tab next field · Alt+←→ calendar · Alt+↑↓ reminder · Alt+A all day · Enter add"
  }

  readonly property string dayLabel: Hey.isDayKey(resolvedDay)
    ? Qt.formatDate(Hey.dateFromKey(resolvedDay), "dddd d MMMM yyyy")
    : ""

  implicitHeight: formColumn.implicitHeight

  // Called each time the form opens, so a second event does not inherit
  // the first one's title.
  function reset() {
    titleField.text = ""
    locationField.text = ""
    var today = root.todayKey !== "" ? root.todayKey : Hey.keyForDate(new Date())
    var day = Hey.isDayKey(root.dayKey) ? root.dayKey : today
    dateField.text = dayText(day)
    var start = Hey.suggestedStart(day, new Date())
    startField.text = start
    endField.text = ""
    root.allDay = false
    root.remind = "30m"
    root.localError = ""
    root.calendarId = pickCalendar(root.defaultCalendarId)
    focusTitle()
  }

  function focusTitle() {
    Qt.callLater(function() { titleField.forceActiveFocus() })
  }

  function currentToday() {
    return root.todayKey !== "" ? root.todayKey : Hey.keyForDate(new Date())
  }

  function dayText(day) {
    var today = currentToday()
    if (day === today) return "today"
    if (day === Hey.addDays(today, 1)) return "tomorrow"
    return Qt.formatDate(Hey.dateFromKey(day), "d MMM yyyy")
  }

  function pickCalendar(preferred) {
    for (var i = 0; i < root.calendars.length; i++)
      if (root.calendars[i].id === preferred) return preferred
    return root.calendars.length > 0 ? root.calendars[0].id : 0
  }

  function submit() {
    if (root.busy) return
    root.localError = ""
    if (!Hey.isDayKey(root.resolvedDay)) {
      root.localError = "“" + dateField.text + "” is not a day I know. Try fri, tomorrow or 3 oct."
      return
    }
    root.submitted({
      title: titleField.text,
      date: root.resolvedDay,
      allDay: root.allDay,
      startTime: startField.text,
      endTime: endField.text,
      calendarId: root.calendarId,
      location: locationField.text,
      remind: root.remind
    })
  }

  // Tab order, skipping the time fields while the event is all day.
  function focusOrder() {
    var order = [titleField, dateField, calendarRow, allDayRow]
    if (!root.allDay) order.push(startField, endField)
    order.push(locationField, remindRow)
    return order
  }

  function focusStep(from, delta) {
    var order = focusOrder()
    var index = order.indexOf(from)
    var next = order[((index + delta) % order.length + order.length) % order.length]
    if (typeof next.selectAll === "function") next.selectAll()
    next.forceActiveFocus()
  }

  function stepCalendar(delta) {
    root.calendarId = Hey.cycle(root.calendarIds, root.calendarId, delta)
  }

  function stepReminder(delta) {
    root.remind = Hey.cycle(root.reminderValues, root.remind, delta)
  }

  function stepDay(delta) {
    var base = Hey.isDayKey(root.resolvedDay) ? root.resolvedDay : currentToday()
    dateField.text = dayText(Hey.addDays(base, delta))
  }

  // Every field and row shares this. Returns having accepted the key, or
  // leaves it for the field (typing, and Left/Right inside the text).
  function handleKey(event, item) {
    var key = event.key
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var left = key === Qt.Key_Left || (!item.selectAll && event.text === "h")
    var right = key === Qt.Key_Right || (!item.selectAll && event.text === "l")

    if (key === Qt.Key_Escape) root.canceled()
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) root.submit()
    else if (key === Qt.Key_Backtab || (key === Qt.Key_Tab && shift)) focusStep(item, -1)
    else if (key === Qt.Key_Tab) focusStep(item, 1)
    else if (alt && key === Qt.Key_Left) stepCalendar(-1)
    else if (alt && key === Qt.Key_Right) stepCalendar(1)
    else if (alt && key === Qt.Key_Up) stepReminder(-1)
    else if (alt && key === Qt.Key_Down) stepReminder(1)
    else if (alt && key === Qt.Key_A) root.allDay = !root.allDay
    else if (item === calendarRow && (left || key === Qt.Key_Up)) stepCalendar(-1)
    else if (item === calendarRow && (right || key === Qt.Key_Down)) stepCalendar(1)
    else if (item === remindRow && left) stepReminder(-1)
    else if (item === remindRow && right) stepReminder(1)
    else if (item === allDayRow && (key === Qt.Key_Space || left || right)) root.allDay = !root.allDay
    else if (item === dateField && key === Qt.Key_Up) stepDay(shift ? -7 : -1)
    else if (item === dateField && key === Qt.Key_Down) stepDay(shift ? 7 : 1)
    else if (item === startField && (key === Qt.Key_Up || key === Qt.Key_Down))
      startField.text = Hey.nudgeClock(startField.text, key === Qt.Key_Up ? -15 : 15, Hey.suggestedStart(root.resolvedDay, new Date()))
    else if (item === endField && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      // A blank end is "an hour after the start", so that is where it moves from.
      var from = Hey.shiftClock(startField.text, 60)
      endField.text = Hey.nudgeClock(endField.text !== "" ? endField.text : from, key === Qt.Key_Up ? -15 : 15, from)
    }
    else return
    event.accepted = true
  }

  onCalendarsChanged: if (root.calendarId === 0) root.calendarId = pickCalendar(root.defaultCalendarId)

  Column {
    id: formColumn
    width: parent.width
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      text: "NEW EVENT"
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
      Keys.onPressed: function(event) { root.handleKey(event, titleField) }
    }

    Row {
      width: parent.width
      spacing: Style.space(10)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "ON"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.letterSpacing: 1
      }

      TextField {
        id: dateField
        width: Style.space(130)
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: "today"
        foreground: root.foreground
        font.family: root.fontFamily
        Keys.onPressed: function(event) { root.handleKey(event, dateField) }
      }

      // What the typed day resolves to, so "fri" is never a guess.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.dayLabel !== "" ? root.dayLabel : "Not a day"
        color: root.dayLabel !== "" ? Qt.darker(root.foreground, 1.4) : Color.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // Calendars as HEY paints them: a pastel pill each, the chosen one
    // outlined. A list this short reads faster as colors than as a menu.
    // Tab lands on the row as a whole, and the arrow keys pick.
    Item {
      id: calendarRow
      width: parent.width
      height: calendarFlow.implicitHeight + Style.space(8)
      Keys.onPressed: function(event) { root.handleKey(event, calendarRow) }

      FocusRing {
        visible: calendarRow.activeFocus
      }

    Flow {
      id: calendarFlow
      anchors.fill: parent
      anchors.margins: Style.space(4)
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
    }

    Row {
      width: parent.width
      spacing: Style.space(10)

      Item {
        id: allDayRow
        anchors.verticalCenter: parent.verticalCenter
        width: allDayButton.implicitWidth
        height: allDayButton.implicitHeight
        Keys.onPressed: function(event) { root.handleKey(event, allDayRow) }

      Button {
        id: allDayButton
        anchors.fill: parent
        hasCursor: allDayRow.activeFocus
        text: "All day"
        iconText: root.allDay ? "󰄵" : "󰄱"
        bordered: true
        selected: root.allDay
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        onClicked: root.allDay = !root.allDay
      }
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
        Keys.onPressed: function(event) { root.handleKey(event, startField) }
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
        Keys.onPressed: function(event) { root.handleKey(event, endField) }
      }
    }

    TextField {
      id: locationField
      width: parent.width
      placeholderText: "Where? (optional)"
      foreground: root.foreground
      font.family: root.fontFamily
      Keys.onPressed: function(event) { root.handleKey(event, locationField) }
    }

    Row {
      id: remindRow
      spacing: Style.space(10)
      Keys.onPressed: function(event) { root.handleKey(event, remindRow) }

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
        // Lights the chosen reminder while the row has the keyboard.
        cursorIndex: remindRow.activeFocus ? root.reminderValues.indexOf(root.remind) : -1
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
        text: root.busy ? "Adding to HEY…" : (root.localError !== "" ? root.localError : root.error)
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

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.keyHint
      color: Qt.darker(root.foreground, 1.9)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }
  }
}
