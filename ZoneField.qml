import QtQuick
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal

// On whose clock one time is, as HEY's event form asks it for the start and
// for the end: a field that filters IANA zone names as you type ("new y",
// "tokyo"), with the matches under it while it has the keyboard. Up and
// Down pick among them. Left empty it means `fallback`: this machine's zone
// for the start, the start's zone for the end.
Column {
  id: root

  property string label: "ZONE"
  property var zones: []
  // The zone an empty field stands for, and how to say so.
  property string fallback: ""
  property string fallbackStatus: "Local time"
  property string fallbackPlaceholder: ""
  property string localZone: ""
  property real labelWidth: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  // Called with (event, field) for every key the zone field does not use
  // itself, so Tab, Enter and the form's Alt shortcuts still work.
  property var keyHandler: null

  property alias text: field.text
  readonly property alias field: field
  property int cursor: 0
  readonly property string query: field.text.replace(/^\s+|\s+$/g, "")
  readonly property var matches: Cal.matchZones(root.zones, root.query, 5)
  // The empty field's fallback, else the highlighted match, else whatever
  // was typed (refused on submit when it names no zone).
  readonly property string chosen: {
    if (root.query === "") return root.fallback
    if (root.matches.length > 0) return root.matches[Math.min(root.cursor, root.matches.length - 1)]
    return root.query
  }
  readonly property bool unknown: root.query === "" ? root.fallback === "" : root.matches.length === 0
  readonly property string status: {
    if (root.query === "") return root.fallback !== "" ? root.fallbackStatus : "Type a zone: I could not tell this machine's"
    if (root.matches.length === 0) return "Not a zone I know"
    if (root.chosen === root.localZone) return "Local time"
    return Cal.zoneLabel(root.chosen)
  }

  function reset() {
    field.text = ""
    root.cursor = 0
  }

  spacing: Style.space(8)
  onQueryChanged: root.cursor = 0

  Row {
    width: parent.width
    spacing: Style.space(10)

    Text {
      width: Math.max(implicitWidth, root.labelWidth)
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }

    TextField {
      id: field
      width: Style.space(170)
      anchors.verticalCenter: parent.verticalCenter
      placeholderText: root.fallbackPlaceholder
      foreground: root.foreground
      font.family: root.fontFamily
      Keys.onPressed: function(event) {
        var mods = event.modifiers & (Qt.AltModifier | Qt.ShiftModifier | Qt.ControlModifier)
        if (mods === 0 && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
          if (root.matches.length > 0)
            root.cursor = (root.cursor + (event.key === Qt.Key_Up ? -1 : 1) + root.matches.length) % root.matches.length
          event.accepted = true
        } else if (root.keyHandler) {
          root.keyHandler(event, field)
        }
      }
      // Leaving the field spells out the zone it settled on, so what is
      // shown is what is sent.
      onActiveFocusChanged: {
        if (!activeFocus && root.query !== "" && root.matches.length > 0)
          text = root.chosen === root.fallback ? "" : root.chosen
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.status
      color: root.unknown ? Color.urgent : Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // The zones the typing could mean, the highlighted one chosen.
  Flow {
    visible: field.activeFocus && root.matches.length > 1
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: root.matches

      Rectangle {
        required property var modelData
        required property int index
        readonly property bool picked: index === Math.min(root.cursor, root.matches.length - 1)
        width: zoneName.implicitWidth + Style.space(16)
        height: zoneName.implicitHeight + Style.space(6)
        radius: height / 2
        color: picked ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.25) : "transparent"
        border.width: 1
        border.color: picked ? root.accent : Qt.darker(root.foreground, 2.2)

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
          onClicked: root.cursor = index
        }
      }
    }
  }
}
