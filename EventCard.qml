import QtQuick
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal

// One event in the day view, drawn the way HEY draws it: a block in the
// calendar's pastel with dark ink, the time small above a bold title.
// All-day events, and the middle days of something longer, are HEY's thin
// pill instead, since there is no time to put above them.
//
// Clicking opens the meeting link when there is one and the event in HEY
// otherwise. A one-off event carries a delete button on hover, which asks
// once before doing anything; a repeating one does not, because deleting by
// id would take the whole series with it.
Item {
  id: root

  property var event: null
  property string dayKey: ""
  property bool hour24: true
  property real nowMs: Date.now()
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool busy: false

  signal activated()
  signal deleteRequested()

  readonly property string position: event ? Cal.spanPosition(event, dayKey) : "single"
  readonly property bool pill: !!event && (event.allDay || position === "middle")
  readonly property color fill: event ? Cal.calendarColor(event.color, accent) : accent
  readonly property color ink: Cal.calendarInk
  readonly property bool past: Cal.hasEnded(event, nowMs)
  readonly property bool current: Cal.isNow(event, nowMs)
  readonly property bool declined: Cal.isDeclined(event)
  readonly property bool deletable: !!event && event.writable !== false && !event.recurring && String(event.seriesId) !== ""
  readonly property string timeText: event ? Cal.eventTimeOnDay(event, dayKey, hour24) : ""
  readonly property string metaText: {
    if (!event) return ""
    var parts = []
    if (event.calendar !== "") parts.push(Cal.calendarLabel(event.calendar))
    if (event.location !== "") parts.push(event.location)
    return parts.join(" · ")
  }

  property bool confirming: false

  implicitWidth: parent ? parent.width : Style.space(400)
  implicitHeight: Math.max(confirming ? confirmDelete.implicitHeight + Style.space(10) : 0, pill
    ? Math.max(Style.space(24), pillTitle.implicitHeight + Style.space(8))
    : blockColumn.implicitHeight + Style.space(14))

  opacity: (past || declined) && !confirming ? 0.5 : 1

  Rectangle {
    id: card
    anchors.fill: parent
    radius: root.pill ? height / 2 : Math.max(3, Style.cornerRadius)
    color: root.fill
    // The event under way gets a ring in the theme's attention color, the
    // one mark here that is not HEY's own.
    border.width: root.current ? 2 : 0
    border.color: Color.urgent

    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: Qt.rgba(0, 0, 0, cardMouse.containsMouse && !root.confirming ? 0.08 : 0)
    }
  }

  // ---- Pill: all-day, or a day in the middle of something longer.
  Row {
    visible: root.pill && !root.confirming
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(8)

    Text {
      id: pillTitle
      textFormat: Text.PlainText
      width: parent.width - pillMeta.width - parent.spacing
      text: root.event ? root.event.title : ""
      color: root.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.strikeout: root.declined
      elide: Text.ElideRight
    }

    Text {
      id: pillMeta
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: root.position === "middle" ? "continues" : Cal.calendarLabel(root.event ? root.event.calendar : "")
      color: Qt.rgba(0.106, 0.149, 0.196, 0.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---- Block: a timed event.
  Column {
    id: blockColumn
    visible: !root.pill && !root.confirming
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10) + (root.deletable ? deleteButton.width : 0)
    anchors.topMargin: Style.space(7)
    spacing: Style.space(1)

    Row {
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.timeText
        color: Qt.rgba(0.106, 0.149, 0.196, 0.72)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: root.current
        textFormat: Text.PlainText
        text: "NOW"
        color: root.ink
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: root.event ? root.event.title : ""
      color: root.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      font.strikeout: root.declined
      elide: Text.ElideRight
    }

    Text {
      visible: text !== ""
      textFormat: Text.PlainText
      width: parent.width
      text: root.metaText
      color: Qt.rgba(0.106, 0.149, 0.196, 0.66)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  MouseArea {
    id: cardMouse
    anchors.fill: parent
    hoverEnabled: true
    enabled: !root.confirming
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()

    PanelToolTip {
      visible: cardMouse.containsMouse && !!root.event && !deleteMouse.containsMouse
      fontFamily: root.fontFamily
      text: {
        if (!root.event) return ""
        var lines = [Cal.eventRangeLabel(root.event, root.hour24) + " · " + root.event.title]
        if (root.event.calendar !== "") lines.push(root.event.calendar)
        if (root.event.location !== "") lines.push(root.event.location)
        if (root.event.recurring) lines.push("Repeats")
        lines.push(root.event.joinUrl !== "" ? (root.event.joinTitle || "Click to join") : "Click to open")
        return lines.join("\n")
      }
    }
  }

  // ---- Delete, for one-off events.
  Text {
    id: deleteButton
    visible: root.deletable && !root.confirming && (cardMouse.containsMouse || deleteMouse.containsMouse)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    text: "󰆴"
    color: deleteMouse.containsMouse ? Color.urgent : Qt.rgba(0.106, 0.149, 0.196, 0.6)
    font.family: root.fontFamily
    font.pixelSize: Style.font.icon

    MouseArea {
      id: deleteMouse
      anchors.fill: parent
      anchors.margins: -Style.space(6)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.confirming = true

      PanelToolTip {
        visible: deleteMouse.containsMouse
        text: "Delete event"
        fontFamily: root.fontFamily
      }
    }
  }

  Row {
    visible: root.confirming
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(8)
    spacing: Style.space(6)

    Text {
      textFormat: Text.PlainText
      width: parent.width - cancelDelete.width - confirmDelete.width - parent.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      text: root.busy ? "Deleting…" : "Delete “" + (root.event ? root.event.title : "") + "”?"
      color: root.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Button {
      id: cancelDelete
      anchors.verticalCenter: parent.verticalCenter
      text: "Keep"
      enabled: !root.busy
      foreground: root.ink
      fontFamily: root.fontFamily
      onClicked: root.confirming = false
    }

    Button {
      id: confirmDelete
      anchors.verticalCenter: parent.verticalCenter
      text: "Delete"
      enabled: !root.busy
      bordered: true
      foreground: root.ink
      accent: Color.urgent
      fontFamily: root.fontFamily
      onClicked: root.deleteRequested()
    }
  }
}
