import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal
import "Places.js" as Places
import "backends/Feeds.js" as Feeds

// OmaCal's settings, inside the panel. Omarchy keeps a widget's
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
      help: "Shows the event's name and when it starts, like “Team standup · in 12m”, from its earliest alert until it ends." },
    { value: "name", label: "Name",
      help: "Shows only the event's name, like “Team standup”, from its earliest alert until it ends." },
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

  // ---- Services
  readonly property var feedContext: ({ dir: Cal.localPath(Qt.resolvedUrl(".")) })
  property var feeds: []
  property string feedError: ""
  property string feedNote: ""

  // What a service's switch says under it: as whom it is read, or what is
  // wrong, or how to set it up.
  function sourceNote(id, setup) {
    if (!root.host || typeof root.host.sourceStatus !== "function") return setup
    var status = root.host.sourceStatus(id)
    if (!status.enabled) return setup
    if (status.ready) return status.account !== "" ? "Reading " + status.account + "." : "Reading."
    if (status.error !== "") return status.error
    return "Checking…"
  }

  // Off in the screenshot harness, which shows sample feeds.
  property bool loadsFeeds: true

  function loadFeeds() {
    if (!root.loadsFeeds || feedLister.running) return
    feedLister.command = Feeds.listCommand(root.feedContext)
    feedLister.running = true
  }

  function addFeed() {
    if (feedWriter.running) return
    var url = feedUrlField.text.replace(/^\s+|\s+$/g, "")
    if (!Feeds.isFeedAddress(url)) {
      root.feedError = "Paste a calendar address that starts with https:// or webcal://."
      return
    }
    root.feedError = ""
    root.feedNote = "Reading the feed…"
    var write = Feeds.addCommand(feedNameField.text, url, root.feedContext)
    feedWriter.run(write.command, write.input)
  }

  function removeFeed(id) {
    if (feedWriter.running) return
    var write = Feeds.removeCommand(id, root.feedContext)
    if (write.command.length === 0) return
    root.feedError = ""
    root.feedNote = ""
    feedWriter.run(write.command, write.input)
  }

  function feedChangeFinished(ok, message) {
    if (ok) {
      feedUrlField.text = ""
      feedNameField.text = ""
      root.feedNote = message
    } else {
      root.feedNote = ""
    }
    root.feedError = ok ? "" : message
    loadFeeds()
    if (root.host && typeof root.host.reloadSource === "function") root.host.reloadSource("feeds")
  }

  onVisibleChanged: if (visible) loadFeeds()

  Process {
    id: feedLister
    running: false
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        var parsed = Feeds.parseList(text)
        if (parsed !== null) root.feeds = parsed
      }
    }
  }

  // The address goes to the helper on stdin, never as an argument.
  Process {
    id: feedWriter
    running: false
    command: []
    property string input: ""
    property bool answered: false
    property var output: null
    stdinEnabled: true
    function run(argv, text) {
      answered = false
      output = null
      input = text
      command = argv
      stdinEnabled = true
      running = true
    }
    onStarted: {
      if (input !== "") write(input)
      input = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: feedWriter.output = text
    }
    onExited: function(code) {
      feedAnswer.code = code
      feedAnswer.restart()
    }
  }

  // The output is in by a moment after the helper exits.
  Timer {
    id: feedAnswer
    property int code: 0
    interval: 150
    onTriggered: {
      if (feedWriter.answered) return
      feedWriter.answered = true
      var result = Feeds.writeResult(code, feedWriter.output === null ? "" : feedWriter.output)
      root.feedChangeFinished(result.ok, result.message)
    }
  }

  // The Google key goes to its own file, mode 600, through stdin, so it is
  // never in shell.json or on a command line. An empty key removes it.
  property string keyError: ""

  function saveKey(text) {
    var key = String(text || "").replace(/\s+/g, "")
    if (key !== "" && !Places.isGoogleKey(key)) {
      root.keyError = "That is not a Google Maps API key."
      return
    }
    root.keyError = ""
    keyWriter.pendingKey = key
    keyWriter.running = true
  }

  // Reads the key file the same way the form does, to say which service
  // is in use.
  PlaceSearch {
    id: placeKey
    visible: false
  }

  Process {
    id: keyWriter
    property string pendingKey: ""
    command: ["sh", "-c",
      "umask 077; if [ -z \"$2\" ]; then rm -f \"$1\"; exit; fi; "
      + "mkdir -p \"${1%/*}\" && cat > \"$1.new\" && chmod 600 \"$1.new\" && mv -f \"$1.new\" \"$1\"",
      "omacal-places-key", placeKey.keyPath, keyWriter.pendingKey === "" ? "" : "write"]
    stdinEnabled: true
    onStarted: {
      write(pendingKey)
      stdinEnabled = false
    }
    onExited: function(code) {
      stdinEnabled = true
      if (code !== 0) root.keyError = "Could not save the key to " + placeKey.keyPath + "."
      else placeKeyField.text = ""
      pendingKey = ""
    }
  }

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

    // ---- Services
    Label { text: "CALENDARS FROM" }

    Toggle {
      width: parent.width
      label: "HEY"
      description: root.sourceNote("hey", "Reads HEY through hey-cli. Run `hey setup` to sign in.")
      checked: root.value("heyEnabled", true) !== false
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.save("heyEnabled", !checked)
    }

    Toggle {
      width: parent.width
      label: "Google Calendar"
      description: root.sourceNote("google", "Reads and writes Google Calendar, signed in through gws, the Google Workspace CLI: "
        + "install googleworkspace-cli and run `gws auth login -s calendar`.")
      checked: root.value("googleEnabled", false) === true
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.save("googleEnabled", !checked)
    }

    Label { text: "CALENDAR FEEDS" }

    Repeater {
      model: root.feeds

      Item {
        required property var modelData
        width: settingsColumn.width
        height: Math.max(feedPill.height, feedRemove.implicitHeight)

        Rectangle {
          id: feedPill
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: feedName.implicitWidth + Style.space(20)
          height: feedName.implicitHeight + Style.space(8)
          radius: height / 2
          color: Cal.calendarColor(modelData.color, Color.accent)

          Text {
            id: feedName
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: modelData.name
            color: Cal.calendarInk
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          anchors.left: feedPill.right
          anchors.leftMargin: Style.space(8)
          anchors.right: feedRemove.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: modelData.host
          color: Qt.darker(root.foreground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          id: feedRemove
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Remove"
          focusable: true
          enabled: !feedWriter.running
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.removeFeed(modelData.id)
        }
      }
    }

    Row {
      spacing: Style.space(8)

      KeyField {
        id: feedNameField
        width: Style.space(110)
        placeholderText: "Name"
        foreground: root.foreground
        font.family: root.fontFamily
        keyHandler: function(event) { if (event.key === Qt.Key_Escape) { root.closed(); event.accepted = true } }
      }

      KeyField {
        id: feedUrlField
        width: Style.space(200)
        password: true
        placeholderText: "webcal:// or https:// address"
        foreground: root.foreground
        font.family: root.fontFamily
        onAccepted: if (text !== "") root.addFeed()
        keyHandler: function(event) { if (event.key === Qt.Key_Escape) { root.closed(); event.accepted = true } }
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "Add"
        bordered: true
        focusable: true
        enabled: feedUrlField.text !== "" && !feedWriter.running
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.addFeed()
      }
    }

    Note {
      text: root.feedError !== "" ? root.feedError
        : (root.feedNote !== "" ? root.feedNote
          : "Any calendar published as an .ics address, read only: a Google calendar's secret address in iCal format, "
            + "an iCloud or Outlook published calendar, holidays. The address works like a password, so it is kept in "
            + "~/.config/omacal/feeds.json, readable only by you.")
      color: root.feedError !== "" ? Color.urgent : Qt.darker(root.foreground, 1.8)
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
      visible: !!root.host && root.host.capabilities.watch
      label: "Live sync"
      description: "Follow changes made elsewhere within seconds."
      checked: root.value("liveSync", true) !== false
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.save("liveSync", !checked)
    }

    // ---- Places
    Toggle {
      width: parent.width
      label: "Suggest places"
      description: "Look up what you type in Where? and offer the places it could mean, as HEY does."
      checked: root.value("placeSuggestions", true) !== false
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.save("placeSuggestions", !checked)
    }

    Label { text: "GOOGLE MAPS API KEY" }

    Row {
      spacing: Style.space(8)

      KeyField {
        id: placeKeyField
        width: Style.space(220)
        password: true
        placeholderText: placeKey.provider === "google" ? "Saved" : "None: OpenStreetMap"
        foreground: root.foreground
        font.family: root.fontFamily
        onAccepted: if (text !== "") root.saveKey(text)
        keyHandler: function(event) { if (event.key === Qt.Key_Escape) { root.closed(); event.accepted = true } }
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: "Save"
        bordered: true
        focusable: true
        enabled: placeKeyField.text !== "" && !keyWriter.running
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.saveKey(placeKeyField.text)
      }

      Button {
        anchors.verticalCenter: parent.verticalCenter
        visible: placeKey.provider === "google"
        text: "Remove"
        focusable: true
        enabled: !keyWriter.running
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.saveKey("")
      }
    }

    Note {
      text: root.keyError !== "" ? root.keyError
        : (placeKey.provider === "google"
          ? "Places come from Google, which sees what you type in Where?."
          : "Places come from OpenStreetMap, through Komoot's free Photon server, which sees what you type in Where?. "
            + "A Google Maps key with the Places API (New) turned on gives Google's, as in HEY.")
      color: root.keyError !== "" ? Color.urgent : Qt.darker(root.foreground, 1.8)
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
                text: modelData.label || modelData.name
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

      KeyField {
        id: shortcutField
        width: Style.space(220)
        text: String(root.value("quickAddShortcut", "ALT + SHIFT + SPACE"))
        placeholderText: "Off"
        foreground: root.foreground
        font.family: root.fontFamily
        onAccepted: root.save("quickAddShortcut", text.replace(/^\s+|\s+$/g, "").toUpperCase())
        keyHandler: function(event) { if (event.key === Qt.Key_Escape) { root.closed(); event.accepted = true } }
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
