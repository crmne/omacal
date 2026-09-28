import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "ShortcutModel.js" as Model

// Keeps the quick-add shortcut bound in Hyprland while the plugin is
// loaded, from the widget's `quickAddShortcut` setting. Adapted from
// OmaTasks. A shortcut already taken by something else is refused and
// reported, never stolen; an empty setting unbinds it. It is bound again
// when Hyprland reloads its config, and released when the plugin unloads.
Item {
  id: root

  property string value: Model.DEFAULT
  readonly property string ownerId: Model.uuid()
  property string registered: ""
  property string candidate: ""
  property string message: ""
  property bool busy: false

  function apply(next) {
    if (busy || !enabled) return
    var parsed = Model.parse(next)
    if (!parsed) {
      message = "Quick add: use modifiers and a key, for example ALT + SHIFT + SPACE."
      console.warn("crmne.hey-calendar:", message)
      return
    }
    candidate = parsed.text
    message = ""
    busy = true
    readBindings.running = true
  }

  function checkBindings(text, code) {
    if (code !== 0 || !text.trim()) {
      busy = false
      message = "Quick add: could not read Hyprland's shortcuts."
      return
    }
    var list = Model.bindings(text)
    var taken = Model.conflict(list, Model.parse(candidate))
    if (taken) {
      busy = false
      message = "Quick add: " + candidate + " is already assigned to " + (taken.description || "another action") + "."
      console.warn("crmne.hey-calendar:", message)
      return
    }
    registerBinding.command = ["hyprctl", "eval", Model.registerCode(list, registered, candidate, ownerId)]
    registerBinding.running = true
  }

  onValueChanged: if (enabled) applyLater.restart()
  onEnabledChanged: if (enabled) applyLater.restart()
  Component.onCompleted: if (enabled) applyLater.restart()
  Component.onDestruction: {
    if (registered) Quickshell.execDetached(["hyprctl", "eval", Model.releaseCode(registered, ownerId)])
  }

  Timer {
    id: applyLater
    interval: 250
    onTriggered: if (root.busy) restart(); else root.apply(root.value)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { if (root.enabled && event.name === "configreloaded") applyLater.restart() }
  }

  Process {
    id: readBindings
    command: ["hyprctl", "binds"]
    stdout: StdioCollector { id: bindsOutput }
    onExited: function(code) { root.checkBindings(bindsOutput.text, code) }
  }

  Process {
    id: registerBinding
    stdout: StdioCollector { id: registerOutput }
    onExited: function(code) {
      root.busy = false
      if (code !== 0 || registerOutput.text.trim() !== "ok") {
        root.message = "Quick add: could not bind the shortcut. Check your Hyprland configuration."
        console.warn("crmne.hey-calendar:", root.message)
        return
      }
      root.registered = root.candidate
    }
  }
}
