import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal

// A new event, with the fields HEY's own quick form asks for: a title,
// which calendar, which day, when, where, and a reminder. The calendar
// panel's + button and the Alt+Shift+Space quick-add card are both this.
//
// Days and times are typed, not picked: "fri", "tomorrow", "3 oct" for the
// day; "9", "930", "9:30pm", "21.30" for times. An end earlier than the
// start is read as the next morning. Times are this machine's local time
// unless a zone is typed ("new york", "tokyo"), as in HEY's own form. The event
// is created through `hey event add`, so HEY applies its own defaults to
// anything left blank.
//
// Built to be used without a mouse. Tab and Shift+Tab walk every field,
// the calendar row and the reminder row included; on those rows the arrow
// keys pick. Up and Down nudge a time by a quarter hour and the day by one
// (Shift: a week); in the zone field they pick among the matches. From any field, Alt+Left/Right switches calendar,
// Alt+Up/Down the reminder, and Alt+A toggles all day. Enter creates,
// Escape cancels. A hint line says what the keys do where the focus is.
Item {
  id: root

  // The day the form starts on. The panel passes its selected day; the
  // quick-add card leaves it to today.
  property string dayKey: ""
  property string todayKey: ""
  readonly property string resolvedDay: Cal.parseDay(dateField.text, todayKey !== "" ? todayKey : Cal.keyForDate(new Date()))
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

  // The fields' text, for filling the form from outside (the screenshot
  // harness). Named apart from the functions below: an alias that shares a
  // function's name shadows it.
  property alias titleInput: titleField.text
  property alias dayInput: dateField.text
  property alias startInput: startField.text
  property alias endInput: endField.text
  property alias locationInput: locationField.text
  property alias zoneInput: zoneField.text
  property int calendarId: 0
  property bool allDay: false
  property string remind: "30m"

  // This machine's IANA zone and every zone it knows, read once by
  // zonesProcess. The screenshot harness sets them and turns loading off.
  property bool loadZones: true
  property string localZone: ""
  property var zones: []
  property int zoneCursor: 0
  readonly property string zoneQuery: zoneField.text.replace(/^\s+|\s+$/g, "")
  readonly property var zoneMatches: Cal.matchZones(root.zones, root.zoneQuery, 5)
  // The zone the times are written in: this machine's while the field is
  // empty, else the highlighted match, else whatever was typed (refused on
  // submit when it names no zone).
  readonly property string chosenZone: {
    if (root.zoneQuery === "") return root.localZone
    if (root.zoneMatches.length > 0) return root.zoneMatches[Math.min(root.zoneCursor, root.zoneMatches.length - 1)]
    return root.zoneQuery
  }
  readonly property string zoneStatus: {
    if (root.zoneQuery === "") return root.localZone !== "" ? "Local time" : "Type a zone: I could not tell this machine's"
    if (root.zoneMatches.length === 0) return "Not a zone I know"
    if (root.chosenZone === root.localZone) return "Local time"
    return Cal.zoneLabel(root.chosenZone)
  }

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
    if (zoneField.activeFocus) return "Type a city · ↑↓ pick · empty is local time · Tab next · Enter add"
    if (startField.activeFocus || endField.activeFocus) return "↑↓ 15 min · Tab next · Alt+←→ calendar · Enter add"
    return "Tab next field · Alt+←→ calendar · Alt+↑↓ reminder · Alt+A all day · Enter add"
  }

  readonly property string dayLabel: Cal.isDayKey(resolvedDay)
    ? Qt.formatDate(Cal.dateFromKey(resolvedDay), "dddd d MMMM yyyy")
    : ""

  implicitHeight: formColumn.implicitHeight

  // Called each time the form opens, so a second event does not inherit
  // the first one's title.
  function reset() {
    titleField.text = ""
    locationField.text = ""
    var today = root.todayKey !== "" ? root.todayKey : Cal.keyForDate(new Date())
    var day = Cal.isDayKey(root.dayKey) ? root.dayKey : today
    dateField.text = dayText(day)
    var start = Cal.suggestedStart(day, new Date())
    startField.text = start
    endField.text = ""
    zoneField.text = ""
    root.zoneCursor = 0
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
    return root.todayKey !== "" ? root.todayKey : Cal.keyForDate(new Date())
  }

  function dayText(day) {
    var today = currentToday()
    if (day === today) return "today"
    if (day === Cal.addDays(today, 1)) return "tomorrow"
    return Qt.formatDate(Cal.dateFromKey(day), "d MMM yyyy")
  }

  function pickCalendar(preferred) {
    for (var i = 0; i < root.calendars.length; i++)
      if (root.calendars[i].id === preferred) return preferred
    return root.calendars.length > 0 ? root.calendars[0].id : 0
  }

  function submit() {
    if (root.busy) return
    root.localError = ""
    if (!Cal.isDayKey(root.resolvedDay)) {
      root.localError = "“" + dateField.text + "” is not a day I know. Try fri, tomorrow or 3 oct."
      return
    }
    root.submitted({
      title: titleField.text,
      date: root.resolvedDay,
      allDay: root.allDay,
      startTime: startField.text,
      endTime: endField.text,
      timeZone: root.allDay ? "" : root.chosenZone,
      calendarId: root.calendarId,
      location: locationField.text,
      remind: root.remind
    })
  }

  // Tab order, skipping the time fields while the event is all day.
  function focusOrder() {
    var order = [titleField, dateField, calendarRow, allDayRow]
    if (!root.allDay) order.push(startField, endField, zoneField)
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
    root.calendarId = Cal.cycle(root.calendarIds, root.calendarId, delta)
  }

  function stepReminder(delta) {
    root.remind = Cal.cycle(root.reminderValues, root.remind, delta)
  }

  function stepDay(delta) {
    var base = Cal.isDayKey(root.resolvedDay) ? root.resolvedDay : currentToday()
    dateField.text = dayText(Cal.addDays(base, delta))
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
    else if (item === zoneField && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      if (root.zoneMatches.length > 0)
        root.zoneCursor = (root.zoneCursor + (key === Qt.Key_Up ? -1 : 1) + root.zoneMatches.length) % root.zoneMatches.length
    }
    else if (item === dateField && key === Qt.Key_Up) stepDay(shift ? -7 : -1)
    else if (item === dateField && key === Qt.Key_Down) stepDay(shift ? 7 : 1)
    else if (item === startField && (key === Qt.Key_Up || key === Qt.Key_Down))
      startField.text = Cal.nudgeClock(startField.text, key === Qt.Key_Up ? -15 : 15, Cal.suggestedStart(root.resolvedDay, new Date()))
    else if (item === endField && (key === Qt.Key_Up || key === Qt.Key_Down)) {
      // A blank end is "an hour after the start", so that is where it moves from.
      var from = Cal.shiftClock(startField.text, 60)
      endField.text = Cal.nudgeClock(endField.text !== "" ? endField.text : from, key === Qt.Key_Up ? -15 : 15, from)
    }
    else return
    event.accepted = true
  }

  onCalendarsChanged: if (root.calendarId === 0) root.calendarId = pickCalendar(root.defaultCalendarId)
  onZoneQueryChanged: root.zoneCursor = 0

  Process {
    id: zonesProcess
    running: root.loadZones
    command: Cal.zonesCommand
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Cal.parseZones(text)
        root.localZone = parsed.local
        root.zones = parsed.zones
      }
    }
  }

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
          color: Cal.calendarColor(modelData.color, root.accent)
          opacity: chosen || calendarMouse.containsMouse ? 1 : 0.55
          border.width: chosen ? 2 : 0
          border.color: root.foreground

          Text {
            id: calendarName
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: modelData.name
            color: Cal.calendarInk
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

    // On whose clock the times are: this machine's unless a zone is typed.
    Row {
      visible: !root.allDay
      width: parent.width
      spacing: Style.space(10)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "ZONE"
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.letterSpacing: 1
      }

      TextField {
        id: zoneField
        width: Style.space(170)
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: root.localZone !== "" ? Cal.zoneLabel(root.localZone) : "Area/City"
        foreground: root.foreground
        font.family: root.fontFamily
        Keys.onPressed: function(event) { root.handleKey(event, zoneField) }
        // Leaving the field spells out the zone it settled on, so what is
        // shown is what is sent.
        onActiveFocusChanged: {
          if (!activeFocus && root.zoneQuery !== "" && root.zoneMatches.length > 0)
            text = root.chosenZone === root.localZone ? "" : root.chosenZone
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.zoneStatus
        color: root.zoneQuery !== "" && root.zoneMatches.length === 0 || root.localZone === "" && root.zoneQuery === ""
          ? Color.urgent : Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // The zones the typing could mean, the highlighted one chosen.
    Flow {
      visible: !root.allDay && zoneField.activeFocus && root.zoneMatches.length > 1
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.zoneMatches

        Rectangle {
          required property var modelData
          required property int index
          readonly property bool chosen: index === Math.min(root.zoneCursor, root.zoneMatches.length - 1)
          width: zoneName.implicitWidth + Style.space(16)
          height: zoneName.implicitHeight + Style.space(6)
          radius: height / 2
          color: chosen ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25) : "transparent"
          border.width: 1
          border.color: chosen ? root.accent : Qt.darker(root.foreground, 2.2)

          Text {
            id: zoneName
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Cal.zoneLabel(modelData)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.zoneCursor = index
          }
        }
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
        // Transparent at rest, not the theme background: the hover fill is a
        // translucent tint, and fading to it from an opaque color flashes bright
        // halfway through before settling.
        background: "transparent"
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
        text: root.busy ? "Adding…" : (root.localError !== "" ? root.localError : root.error)
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
