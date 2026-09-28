import QtQuick
import qs.Commons

// The keyboard focus mark for a row that is not itself a control (the
// calendar pills), drawn in the same accent the kit's inputs use.
Rectangle {
  anchors.fill: parent
  color: "transparent"
  radius: Math.max(4, Style.cornerRadius)
  border.width: Math.max(1, Style.normalBorderWidth)
  border.color: Color.accent
}
