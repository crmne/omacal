import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Hey.js" as Hey

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
//
// HEY is laid over the stock calendar rather than beside it. Under each day
// sits a chip per calendar color, carrying how many of that day's events
// wear it. Clicking a day selects it, and the day view under the grid shows
// what is on it the way HEY draws a day, with a button to add an event
// there. BarWidget.qml owns the HEY data, since reminders have to fire with
// this panel closed.
Panel {
  id: root
  moduleName: "crmne.hey-calendar"
  ipcTarget: "crmne.hey-calendar"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("en_US")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)

  // ---- HEY. Everything below reads the host's state; nothing here fetches.
  readonly property var byDay: hostWidget ? hostWidget.byDay : ({})
  readonly property bool hour24: hostWidget ? hostWidget.hour24 === true : true
  // The host's clock ticks every minute, which is what "now" and "past" are
  // measured against. `today` above only moves at midnight.
  readonly property real nowMs: hostWidget ? hostWidget.displayDate.getTime() : today.getTime()

  // The day the day view shows. Clicking a cell moves it; the month on
  // screen does not follow, so the grid never jumps under the pointer.
  property string selectedKey: todayKey
  readonly property var selectedEvents: byDay[selectedKey] || []
  readonly property bool selectedIsToday: selectedKey === todayKey
  property bool composing: false
  property string deletingKey: ""

  onWeeksChanged: requestVisibleWeeks()
  onHostWidgetChanged: requestVisibleWeeks()

  // Every HEY week the grid touches: six rows, and a seventh when the rows
  // start on Sunday and straddle HEY's Monday weeks.
  function requestVisibleWeeks() {
    if (!root.hostWidget || !root.weeks || root.weeks.length === 0) return
    var first = root.weeks[0].days[0].key
    var last = root.weeks[root.weeks.length - 1].days[6].key
    root.hostWidget.showWeeks(Hey.weekKeysBetween(first, last))
  }

  function selectDay(key) {
    if (!Hey.isDayKey(key)) return
    if (root.composing && key !== root.selectedKey) root.composing = false
    root.selectedKey = key
  }

  // Steps the selection by days, and the month along with it once the
  // selection walks off the edge of the one on screen.
  function moveSelection(delta) {
    var next = Hey.addDays(root.selectedKey, delta)
    root.selectDay(next)
    var date = Hey.dateFromKey(next)
    if (date.getFullYear() !== root.viewYear || date.getMonth() !== root.viewMonth) {
      root.viewYear = date.getFullYear()
      root.viewMonth = date.getMonth()
    }
  }

  function newEvent() {
    if (!root.opened) root.open()
    root.composing = true
    Qt.callLater(function() { eventForm.reset() })
  }

  function cancelComposing() {
    root.composing = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function submitEvent(form) {
    if (!root.hostWidget) return
    if (Number(form.calendarId) > 0) persistSettings({ lastCalendarId: Number(form.calendarId) })
    root.hostWidget.addEvent(form)
  }

  function openSelectedDay() {
    if (root.hostWidget) root.hostWidget.openUrl(Hey.dayUrl(root.selectedKey))
  }

  function refreshHey() {
    if (root.hostWidget) root.hostWidget.refreshHey(true)
  }

  function activateEvent(event) {
    if (!root.hostWidget || !event) return
    root.hostWidget.openUrl(event.joinUrl !== "" ? event.joinUrl : (event.url !== "" ? event.url : Hey.dayUrl(root.selectedKey)))
  }

  function deleteEvent(event) {
    if (!root.hostWidget || !event) return
    root.deletingKey = event.key
    if (!root.hostWidget.deleteEvent(event, root.selectedKey)) root.deletingKey = ""
  }

  // "MON 28": HEY's day heading, in English like the rest of the grid.
  function dayHeading(key) {
    var date = Hey.dateFromKey(key)
    return root.weekdayLabel(date.getDay()) + " " + date.getDate()
  }

  function dayTooltip(dayEvents, key) {
    var lines = []
    for (var i = 0; i < dayEvents.length && i < 8; i++) {
      var event = dayEvents[i]
      var time = event.allDay ? "All day" : Hey.eventTimeOnDay(event, key, root.hour24)
      lines.push(time + " · " + event.title)
    }
    if (dayEvents.length > 8) lines.push("and " + (dayEvents.length - 8) + " more")
    return lines.join("\n")
  }

  Connections {
    target: root.hostWidget
    ignoreUnknownSignals: true
    function onWriteFinished(ok, message) {
      root.deletingKey = ""
      if (ok && root.composing) root.cancelComposing()
    }
  }


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  // Taller than stock by the chip row under each number.
  readonly property int cellHeight: Style.space(44)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.composing = false
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
    if (root.hostWidget) root.hostWidget.refreshHey(false)
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectedKey = root.todayKey
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // English short day names, matching the rest of the interface.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      var followSelection = root.selectedIsToday
      root.today = clock.date
      if (followToday) root.goToToday()
      else if (followSelection) root.selectedKey = root.todayKey
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.composing
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
        else if (t === "n" || t === "N") root.newEvent()
        else if (t === "r" || t === "R") root.refreshHey()
        else if (t === "o" || t === "O") root.openSelectedDay()
        else if (t === ",") root.moveSelection(-1)
        else if (t === ".") root.moveSelection(1)
        else if (t === "<") root.moveSelection(-7)
        else if (t === ">") root.moveSelection(7)
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "LIFE"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      id: dayCell
                      required property var modelData
                      readonly property var dayEvents: root.byDay[modelData.key] || []
                      readonly property var chips: Hey.dayChips(dayEvents, 3)
                      readonly property bool selected: modelData.key === root.selectedKey

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet. The selected day takes a soft
                      // fill instead, so picking a day never outshouts today.
                      color: selected
                        ? Style.selectionFillFor(root.contentForeground, Color.accent)
                        : (cellMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent")
                      border.width: modelData.today ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.contentForeground, Color.accent)

                      Text {
                        textFormat: Text.PlainText
                        anchors.horizontalCenter: parent.horizontalCenter
                        // The number sits where it always does, chips or
                        // not, so a row reads as one line of dates.
                        y: Style.space(5)
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }

                      // One chip per calendar color, with the count of that
                      // day's events in it. Dimmed outside the month, the
                      // same way the numbers are.
                      Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(6)
                        spacing: Style.space(2)
                        opacity: modelData.inMonth ? 1 : 0.4

                        Repeater {
                          model: dayCell.chips

                          Rectangle {
                            required property var modelData
                            // Kept small on purpose: the date is what the grid
                            // is for, and the chips only answer "how busy?".
                            height: Style.space(10)
                            width: Math.max(height + Style.space(2), chipText.implicitWidth + Style.space(5))
                            radius: Math.max(3, Math.round(height / 3.5))
                            color: modelData.overflow
                              ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.28)
                              : Hey.calendarColor(modelData.color, Color.accent)

                            Text {
                              id: chipText
                              anchors.centerIn: parent
                              textFormat: Text.PlainText
                              text: modelData.overflow ? "+" + modelData.count : modelData.count
                              color: modelData.overflow ? root.contentForeground : Hey.calendarInk
                              font.family: root.contentFontFamily
                              font.pixelSize: Math.max(7, Style.font.caption - 3)
                              font.bold: true
                            }
                          }
                        }
                      }

                      MouseArea {
                        id: cellMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDay(modelData.key)
                        onDoubleClicked: {
                          root.selectDay(modelData.key)
                          root.newEvent()
                        }
                      }

                      PanelToolTip {
                        visible: cellMouse.containsMouse && dayCell.dayEvents.length > 0
                        text: root.dayTooltip(dayCell.dayEvents, modelData.key)
                        fontFamily: root.contentFontFamily
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- The selected day, as HEY draws one: its heading (today in
          //      HEY's orange), the all-day pills, then a block per event.
          //      The new-event form takes this place while it is open.
          Item {
            width: parent.width
            height: dayColumn.y + dayColumn.implicitHeight + Style.space(6)

            Column {
              id: dayColumn
              y: Style.space(4)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(8)

              Rectangle {
                width: parent.width
                height: Style.spacing.hairline
                color: root.contentForeground
                opacity: 0.1
              }

              Item {
                width: parent.width
                height: Math.max(dayPill.height, dayActions.height)

                Rectangle {
                  id: dayPill
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: dayPillText.implicitWidth + Style.space(18)
                  height: dayPillText.implicitHeight + Style.space(6)
                  radius: height / 2
                  color: root.selectedIsToday ? Hey.todayColor : "transparent"

                  Text {
                    id: dayPillText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.dayHeading(root.selectedKey)
                    color: root.selectedIsToday ? Hey.calendarInk : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    font.letterSpacing: 0.5
                  }
                }

                Text {
                  anchors.left: dayPill.right
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: {
                    var label = Hey.relativeDayLabel(root.selectedKey, root.todayKey)
                    var date = Hey.dateFromKey(root.selectedKey)
                    return root.selectedIsToday ? label : label + " · " + Qt.formatDate(date, "d MMMM")
                  }
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  id: dayActions
                  anchors.right: parent.right
                  anchors.rightMargin: -Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  PanelActionButton {
                    iconText: "󰐕"
                    tooltipText: "New event (N)"
                    enabled: !!root.hostWidget && root.hostWidget.cliMode !== ""
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.newEvent()
                  }

                  PanelActionButton {
                    iconText: "󰏌"
                    tooltipText: "Open this day in HEY (O)"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.openSelectedDay()
                  }

                  PanelActionButton {
                    iconText: "󰑐"
                    tooltipText: root.hostWidget && root.hostWidget.loading ? "Reading HEY…" : "Refresh from HEY (R)"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    opacity: root.hostWidget && root.hostWidget.loading ? 0.45 : 1
                    onClicked: root.refreshHey()
                  }
                }
              }

              EventForm {
                id: eventForm
                visible: root.composing
                width: parent.width
                dayKey: root.selectedKey
                calendars: root.hostWidget ? root.hostWidget.writableCalendars : []
                defaultCalendarId: Number(root.setting("lastCalendarId", 0)) || 0
                busy: !!root.hostWidget && root.hostWidget.writing
                error: root.hostWidget ? root.hostWidget.writeError : ""
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onSubmitted: function(form) { root.submitEvent(form) }
                onCanceled: root.cancelComposing()
              }

              Column {
                visible: !root.composing
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: root.selectedEvents

                  EventCard {
                    required property var modelData
                    width: parent.width
                    event: modelData
                    dayKey: root.selectedKey
                    hour24: root.hour24
                    nowMs: root.nowMs
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    busy: root.deletingKey === modelData.key
                    onActivated: root.activateEvent(modelData)
                    onDeleteRequested: root.deleteEvent(modelData)
                  }
                }

                // What an empty day means depends on whether HEY answered.
                Text {
                  visible: root.selectedEvents.length === 0 || (root.hostWidget && root.hostWidget.lastError !== "")
                  width: parent.width
                  topPadding: Style.space(4)
                  bottomPadding: Style.space(4)
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: {
                    var host = root.hostWidget
                    if (!host) return ""
                    if (host.lastError !== "") return host.lastError
                    if (!host.loaded) return "Reading HEY…"
                    return root.selectedIsToday ? "Nothing on today." : "Nothing on this day."
                  }
                  color: root.hostWidget && root.hostWidget.lastError !== ""
                    ? Color.urgent
                    : Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: root.hostWidget && root.hostWidget.writeError !== "" && !root.composing
                  width: parent.width
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  text: root.hostWidget ? root.hostWidget.writeError : ""
                  color: Color.urgent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              // ---- HEY's time tracking, on today: one tap to start, one to
              //      stop, and how long it has been running.
              Item {
                visible: root.selectedIsToday && !root.composing && !!root.hostWidget && root.hostWidget.cliMode !== ""
                width: parent.width
                height: visible ? trackButton.implicitHeight : 0

                readonly property var track: root.hostWidget ? root.hostWidget.timeTrack : null

                Text {
                  id: trackIcon
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󱎫"
                  color: parent.track ? Color.urgent : Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.icon
                }

                Text {
                  anchors.left: trackIcon.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: trackButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: {
                    var track = parent.track
                    if (!track) return "Not tracking time"
                    var since = Hey.formatTime(new Date(track.startMs), root.hour24)
                    return "Tracking " + Hey.durationLabel(root.nowMs - track.startMs)
                      + " · since " + since + (track.title !== "" ? " · " + track.title : "")
                  }
                  color: parent.track ? root.contentForeground : Qt.darker(root.contentForeground, 1.6)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  id: trackButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.track ? "Stop" : "Start"
                  iconText: parent.track ? "󰓛" : "󰐊"
                  bordered: true
                  enabled: !!root.hostWidget && !root.hostWidget.writing
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    if (parent.track) root.hostWidget.stopTimeTrack()
                    else root.hostWidget.startTimeTrack()
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
