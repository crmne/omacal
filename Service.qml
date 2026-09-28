import QtQuick
import "ShortcutModel.js" as ShortcutModel

// One per shell, unlike the bar widget, which has an instance on every
// monitor's bar. That is why the quick-add shortcut lives here: two widgets
// binding it would bind it twice, and one key press would open the card and
// close it again.
//
// The shortcut is the `quickAddShortcut` setting on the widget's entry in
// shell.json, so it is set where every other HEY Calendar setting is.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string moduleName: "crmne.omacal"

  readonly property var widgetEntry: {
    var config = root.shell ? root.shell.barConfig : null
    var layout = config && config.layout ? config.layout : {}
    for (var section in layout) {
      var entries = Array.isArray(layout[section]) ? layout[section] : []
      for (var i = 0; i < entries.length; i++)
        if (entries[i] && entries[i].id === root.moduleName) return entries[i]
    }
    return null
  }

  readonly property string quickAddShortcut: widgetEntry && widgetEntry.quickAddShortcut !== undefined && widgetEntry.quickAddShortcut !== null
    ? String(widgetEntry.quickAddShortcut)
    : ShortcutModel.DEFAULT

  ShortcutManager {
    enabled: root.shell !== null
    value: root.quickAddShortcut
  }
}
