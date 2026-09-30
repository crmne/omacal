import QtQuick
import qs.Commons
import qs.Ui
import "Calendar.js" as Cal

// The zone under one time, as HEY shows it once its globe is clicked: the
// city ("Berlin"), a field you can type in to pick another ("new y",
// "tokyo"). Up and Down step through the matches, which the form lists
// under the times while this has the keyboard. Empty means `fallback`:
// this machine's zone for the start, the start's for the end.
TextField {
  id: root

  property var zones: []
  property string fallback: ""
  // The zone settled on when the field was last left, shown as its city.
  property string picked: ""
  property int cursor: 0

  // Called with (event, field) for every key this does not use itself, so
  // Tab, Enter and the form's Alt shortcuts still work.
  property var keyHandler: null

  readonly property string query: text.replace(/^\s+|\s+$/g, "")
  readonly property bool showsPicked: root.picked !== "" && root.query === Cal.zoneCity(root.picked)
  readonly property var matches: root.query === "" || root.showsPicked ? [] : Cal.matchZones(root.zones, root.query, 5)
  // The fallback while empty, what was picked while its city still shows,
  // else the highlighted match, else whatever was typed (refused on submit).
  readonly property string chosen: {
    if (root.query === "") return root.fallback
    if (root.showsPicked) return root.picked
    if (root.matches.length > 0) return root.matches[Math.min(root.cursor, root.matches.length - 1)]
    return root.query
  }
  readonly property bool unknown: root.query === "" ? root.fallback === "" : !root.showsPicked && root.matches.length === 0

  function reset() {
    root.picked = ""
    root.text = ""
    root.cursor = 0
  }

  placeholderText: root.fallback !== "" ? Cal.zoneCity(root.fallback) : "City"
  onQueryChanged: root.cursor = 0

  Keys.onPressed: function(event) {
    var mods = event.modifiers & (Qt.AltModifier | Qt.ShiftModifier | Qt.ControlModifier)
    if (mods === 0 && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) {
      if (root.matches.length > 0)
        root.cursor = (root.cursor + (event.key === Qt.Key_Up ? -1 : 1) + root.matches.length) % root.matches.length
      event.accepted = true
    } else if (root.keyHandler) {
      root.keyHandler(event, root)
    }
  }

  // Leaving the field settles it: the match becomes the pick and shows as
  // its city, so what is shown is what is sent.
  onActiveFocusChanged: {
    if (activeFocus || root.query === "" || root.showsPicked || root.matches.length === 0) return
    var zone = root.chosen
    if (zone === root.fallback) {
      root.reset()
    } else {
      root.picked = zone
      root.text = Cal.zoneCity(zone)
    }
  }
}
