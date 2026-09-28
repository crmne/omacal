import QtQuick
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal

// One finished time track in the day view: when, what, how long.
//
// Tracks are drawn quieter than events, a neutral block rather than a
// calendar's pastel, because they record the day rather than plan it.
// Clicking one names it (HEY files a track under a category, and that is
// its name); a fresh Stop opens the name field on its own. Enter saves,
// Escape leaves it. A delete button on hover asks once.
Item {
  id: root

  property var track: null
  property string dayKey: ""
  property bool hour24: true
  property bool renaming: false
  property bool busy: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal renameRequested(string name)
  signal renameCanceled()
  signal renameStarted()
  signal deleteRequested()

  property bool confirming: false

  readonly property string rangeText: {
    if (!track) return ""
    var span = Cal.eventTimeOnDay({ allDay: false, startMs: track.startMs, endMs: track.endMs,
      startsAt: "", endsAt: "" }, dayKey, hour24)
    return span
  }

  implicitWidth: parent ? parent.width : Style.space(400)
  implicitHeight: Math.max(Style.space(30), (renaming ? nameField.implicitHeight : nameText.implicitHeight) + Style.space(10))

  onRenamingChanged: {
    if (!renaming) return
    nameField.text = root.track && root.track.named ? root.track.name : ""
    Qt.callLater(function() {
      nameField.selectAll()
      nameField.forceActiveFocus()
    })
  }

  Rectangle {
    anchors.fill: parent
    radius: Math.max(3, Style.cornerRadius)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, rowMouse.containsMouse && !root.renaming ? 0.12 : 0.07)
  }

  Row {
    visible: !root.confirming
    anchors.fill: parent
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "󱎫"
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.rangeText
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      width: parent.width - x - durationText.width - parent.spacing - (deleteButton.visible ? deleteButton.width + parent.spacing : 0)
      height: parent.height

      Text {
        id: nameText
        visible: !root.renaming
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.track ? (root.track.named ? root.track.name : root.track.name + " · click to name") : ""
        color: root.track && root.track.named ? root.foreground : Qt.darker(root.foreground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.italic: root.track && !root.track.named
        elide: Text.ElideRight
      }

      TextField {
        id: nameField
        visible: root.renaming
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: "What was this? Enter saves"
        foreground: root.foreground
        font.family: root.fontFamily
        verticalPadding: Style.space(3)
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.renameCanceled()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            var name = nameField.text.replace(/^\s+|\s+$/g, "")
            if (name !== "") root.renameRequested(name)
            else root.renameCanceled()
            event.accepted = true
          }
        }
      }
    }

    Text {
      id: durationText
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.track ? Cal.durationLabel(root.track.endMs - root.track.startMs) : ""
      color: Qt.darker(root.foreground, 1.3)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: deleteButton
      visible: !root.renaming && (rowMouse.containsMouse || deleteMouse.containsMouse)
      anchors.verticalCenter: parent.verticalCenter
      text: "󰆴"
      color: deleteMouse.containsMouse ? Color.urgent : Qt.darker(root.foreground, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall

      MouseArea {
        id: deleteMouse
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.confirming = true
      }
    }
  }

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    z: -1
    hoverEnabled: true
    enabled: !root.renaming && !root.confirming
    cursorShape: Qt.PointingHandCursor
    onClicked: root.renameStarted()

    PanelToolTip {
      visible: rowMouse.containsMouse && !deleteMouse.containsMouse && !!root.track
      text: root.track ? (root.track.named ? "Click to rename" : "Click to name this track")
        + (root.track.notes !== "" ? "\n" + root.track.notes : "") : ""
      fontFamily: root.fontFamily
    }
  }

  Row {
    visible: root.confirming
    anchors.fill: parent
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(6)

    Text {
      width: parent.width - keepButton.width - removeButton.width - parent.spacing * 2
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.busy ? "Deleting…" : "Delete this time track?"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Button {
      id: keepButton
      anchors.verticalCenter: parent.verticalCenter
      text: "Keep"
      enabled: !root.busy
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.space(2)
      onClicked: root.confirming = false
    }

    Button {
      id: removeButton
      anchors.verticalCenter: parent.verticalCenter
      text: "Delete"
      enabled: !root.busy
      bordered: true
      foreground: root.foreground
      accent: Color.urgent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      verticalPadding: Style.space(2)
      onClicked: root.deleteRequested()
    }
  }
}
