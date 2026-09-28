import QtQuick
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal

// HEY Calendar's settings, inside the panel. Omarchy keeps a widget's
// schema but draws no settings screen for it yet, so this is where they are
// set. Every change is written to the widget's entry in shell.json the
// moment it is made, the same place the stock settings live.
//
// Keyboard: Tab and Shift+Tab walk the controls; arrows pick inside a row;
// Enter or Space applies; Escape goes back to the calendar.
FocusScope {
  id: root

  property var panel: null
  property var host: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal closed()

  function value(key, fallback) {
    return root.panel ? root.panel.setting(key, fallback) : fallback
  }

  function save(key, v) {
    var values = {}
    values[key] = v
    if (root.panel) root.panel.persistSettings(values)
  }

  readonly property var hidden: Cal.parseHiddenCalendars(value("hiddenCalendars", ""))
  property int calendarCursor: 0

  function toggleCalendar(name) {
    var key = String(name).toLowerCase()
    var next = []
    var found = false
    for (var i = 0; i < root.hidden.length; i++) {
      if (root.hidden[i] === key) found = true
      else next.push(root.hidden[i])
    }
    if (!found) next.push(key)
    // Written back with the calendars' own capitalisation, so shell.json
    // reads the way the pills do.
    var names = []
    var calendars = root.host ? root.host.calendars : []
    for (var c = 0; c < calendars.length; c++)
      if (next.indexOf(String(calendars[c].name).toLowerCase()) !== -1) names.push(calendars[c].name)
    for (var n = 0; n < next.length; n++) {
      var known = false
      for (var k = 0; k < names.length; k++) if (names[k].toLowerCase() === next[n]) known = true
      if (!known) names.push(next[n])
    }
    save("hiddenCalendars", names.join(", "))
  }

  // The view takes the keyboard, but no row does until Tab moves into
  // one: a row with keyboard focus marks its cursor chip the way hover
  // does, and a chip lit before anyone asked reads as a stuck selection.
  function focusFirst() {
    Qt.callLater(function() { root.forceActiveFocus() })
  }

  // What each choice does, said plainly under its row. The row describes
  // the chip under the pointer, or the chosen one.
  readonly property var barEventOptions: [
    { value: "soon", label: "Name + time",
      help: "Shows the event's name and when it starts, like “Omarchy Podcast · in 12m”, from its earliest alert until it ends." },
    { value: "name", label: "Name",
      help: "Shows only the event's name, like “Omarchy Podcast”, from its earliest alert until it ends." },
    { value: "time", label: "Time",
      help: "Shows only when the event starts, like “in 12m”, without its name, from its earliest alert until it ends." },
    { value: "next", label: "Next",
      help: "Always shows today's next event with its time, all day long, like “Dinner · at 18:30”. Events inside their alert come first." },
    { value: "off", label: "Off",
      help: "Shows only the clock. A calendar icon appears in front of it while an event is coming up, and hovering the clock names it." }
  ]

  readonly property var leadOptions: [
    { value: "0", label: "Never", help: "Events with no alert never appear in the bar. Only events with an alert do, from that alert." },
    { value: "5", label: "5 min", help: "Events with no alert appear in the bar 5 minutes before they start." },
    { value: "15", label: "15 min", help: "Events with no alert appear in the bar 15 minutes before they start." },
    { value: "30", label: "30 min", help: "Events with no alert appear in the bar 30 minutes before they start." },
    { value: "60", label: "1 h", help: "Events with no alert appear in the bar an hour before they start." }
  ]

  property int barEventHover: -1
  property int leadHover: -1

  function helpFor(options, hovered, current) {
    if (hovered >= 0 && hovered < options.length) return options[hovered].help
    for (var i = 0; i < options.length; i++) if (options[i].value === current) return options[i].help
    return ""
  }

  implicitHeight: settingsColumn.implicitHeight

  Keys.onEscapePressed: root.closed()

  component Label: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.letterSpacing: 1
  }

  component Note: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: Qt.darker(root.foreground, 1.8)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Column {
    id: settingsColumn
    width: parent.width
    spacing: Style.space(8)

    Item {
      width: parent.width
      height: backButton.implicitHeight

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "SETTINGS"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        font.letterSpacing: 1
      }

      Button {
        id: backButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Done"
        tooltipText: "Back to the calendar (Esc)"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.closed()
      }
    }

    // ---- Bar
    Label { text: "EVENT IN THE BAR" }

    ButtonGroup {
      id: barEventGroup
      // Transparent at rest, not the theme background: the hover fill is a
      // translucent tint, and fading to it from an opaque color flashes bright
      // halfway through before settling.
      background: "transparent"
      options: root.barEventOptions
      value: String(root.value("barEvent", "soon"))
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.save("barEvent", v) }
      onHovered: function(index, isHovered) { root.barEventHover = isHovered ? index : -1 }
    }

    Note {
      text: root.helpFor(root.barEventOptions, root.barEventHover, String(root.value("barEvent", "soon")))
    }

    Label { text: "EVENTS WITH NO ALERT APPEAR BEFORE THEY START" }

    ButtonGroup {
      // Transparent at rest, not the theme background: the hover fill is a
      // translucent tint, and fading to it from an opaque color flashes bright
      // halfway through before settling.
      background: "transparent"
      options: root.leadOptions
      value: String(Cal.normalizedAlertLead(root.value("alertLeadMinutes", 15)))
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.save("alertLeadMinutes", parseInt(v, 10)) }
      onHovered: function(index, isHovered) { root.leadHover = isHovered ? index : -1 }
    }

    Note {
      text: root.helpFor(root.leadOptions, root.leadHover, String(Cal.normalizedAlertLead(root.value("alertLeadMinutes", 15))))
    }

    Label { text: "TIMES" }

    ButtonGroup {
      // Transparent at rest, not the theme background: the hover fill is a
      // translucent tint, and fading to it from an opaque color flashes bright
      // halfway through before settling.
      background: "transparent"
      options: [
        { value: "auto", label: "Like the system" },
        { value: "24", label: "24 h" },
        { value: "12", label: "12 h" }
      ]
      value: String(root.value("timeFormat", "auto"))
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.save("timeFormat", v) }
    }

    // ---- Switches
    Toggle {
      width: parent.width
      label: "Notifications"
      description: "Your events' reminders as desktop notifications."
      checked: root.value("notifications", true) !== false
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.save("notifications", !checked)
    }

    Toggle {
      width: parent.width
      label: "Live sync"
      description: "Follow changes made elsewhere within seconds, through hey watch."
      checked: root.value("liveSync", true) !== false
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.save("liveSync", !checked)
    }

    // ---- Calendars
    Label { text: "CALENDARS" }

    Item {
      id: calendarRow
      width: parent.width
      height: calendarFlow.implicitHeight + Style.space(8)
      activeFocusOnTab: true

      Keys.onPressed: function(event) {
        var count = root.host ? root.host.calendars.length : 0
        if (count === 0) return
        if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
          root.calendarCursor = (root.calendarCursor - 1 + count) % count
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L) {
          root.calendarCursor = (root.calendarCursor + 1) % count
        } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.toggleCalendar(root.host.calendars[root.calendarCursor].name)
        } else {
          return
        }
        event.accepted = true
      }

      FocusRing { visible: calendarRow.activeFocus }

      Flow {
        id: calendarFlow
        anchors.fill: parent
        anchors.margins: Style.space(4)
        spacing: Style.space(6)

        Repeater {
          model: root.host ? root.host.calendars : []

          Rectangle {
            required property var modelData
            required property int index
            readonly property bool shown: root.hidden.indexOf(String(modelData.name).toLowerCase()) === -1
            readonly property bool cursor: calendarRow.activeFocus && root.calendarCursor === index
            width: pillRow.implicitWidth + Style.space(20)
            height: pillRow.implicitHeight + Style.space(8)
            radius: height / 2
            color: shown ? Cal.calendarColor(modelData.color, Color.accent) : "transparent"
            border.width: shown ? (cursor ? 2 : 0) : (cursor ? 2 : 1)
            border.color: cursor ? root.foreground : Qt.darker(root.foreground, 1.8)

            Row {
              id: pillRow
              anchors.centerIn: parent
              spacing: Style.space(5)

              Text {
                text: parent.parent.shown ? "󰄬" : "󰅖"
                color: parent.parent.shown ? Cal.calendarInk : Qt.darker(root.foreground, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.name
                color: parent.parent.shown ? Cal.calendarInk : Qt.darker(root.foreground, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.strikeout: !parent.parent.shown
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.calendarCursor = index
                root.toggleCalendar(modelData.name)
              }
            }
          }
        }
      }
    }

    Note {
      text: "Hidden calendars are left out of the grid, the day and the bar. "
        + (root.host ? root.host.modeNote() : "")
    }

    // ---- Quick add
    Label { text: "QUICK ADD SHORTCUT" }

    Row {
      spacing: Style.space(8)

      TextField {
        id: shortcutField
        width: Style.space(220)
        text: String(root.value("quickAddShortcut", "ALT + SHIFT + SPACE"))
        placeholderText: "Off"
        foreground: root.foreground
        font.family: root.fontFamily
        onAccepted: root.save("quickAddShortcut", text.replace(/^\s+|\s+$/g, "").toUpperCase())
        Keys.onEscapePressed: root.closed()
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "Apply"
        bordered: true
        focusable: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.save("quickAddShortcut", shortcutField.text.replace(/^\s+|\s+$/g, "").toUpperCase())
      }
    }

    Note {
      text: "Modifiers and a key, like ALT + SHIFT + SPACE. Empty turns it off. A shortcut something else already uses is left alone."
    }
  }
}
