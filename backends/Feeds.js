// The calendar-feed backend: any calendar published as an iCalendar (.ics)
// address, read through backends/feeds.py. Google's "secret address in
// iCal format", iCloud's and Outlook's published calendars, holidays,
// sports fixtures. Read only: a feed is a copy, so its events open in the
// service that publishes it, or nowhere.
//
// A feed's address works like a password, so it is kept in its own file,
// ~/.config/omacal/feeds.json (mode 600), and never put in shell.json or
// on a command line: the helper reads it from that file, and a new one
// reaches it on stdin. Everything here names a feed by its id.
//
// Qt-free and self-contained, so it runs under plain node.

var info = {
  id: "feeds",
  name: "Feeds",
  capabilities: {
    create: false,
    edit: false,
    delete: false,
    watch: false,
    timeTracking: false,
    dayLink: false
  }
}

var helperTimeoutSeconds = 90
var maximumWeeksPerFetch = 8

function isDayKey(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))
}

function helper(context, action, args) {
  var dir = String(context && context.dir ? context.dir : "").replace(/\/+$/, "")
  return ["timeout", "-k", "3", String(helperTimeoutSeconds), "/usr/bin/python3", "-I",
    dir + "/backends/feeds.py", action].concat(args || [])
}

function parseAnswer(output) {
  var line = String(output || "").replace(/^\s+|\s+$/g, "").split("\n")[0]
  try {
    var value = JSON.parse(line)
    return value && typeof value === "object" ? value : null
  } catch (e) {
    return null
  }
}

function probeCommand(context) {
  return helper(context, "probe")
}

// No feeds is not an error: there is nothing to read, and nothing to say.
function probe(output) {
  var answer = parseAnswer(output)
  if (answer && answer.ok === true) return { mode: "ics", version: "", error: "" }
  if (answer && answer.quiet === true) return { mode: "", version: "", quiet: true, error: "" }
  if (answer && answer.error) return { mode: "", version: "", error: String(answer.error).substr(0, 300) }
  return { mode: "", version: "", error: "The calendar feeds could not be read. Is /usr/bin/python3 there?" }
}

function modeNote() {
  return ""
}

function fetchCommand(mode, weekKeys, context) {
  var keys = []
  var list = Array.isArray(weekKeys) ? weekKeys : []
  for (var i = 0; i < list.length && keys.length < maximumWeeksPerFetch; i++)
    if (isDayKey(list[i]) && keys.indexOf(list[i]) === -1) keys.push(list[i])
  return helper(context, "weeks", keys)
}

function calendarsCommand(context) {
  return helper(context, "calendars")
}

// The settings' list: [{ id, name, color, host }], no addresses.
function listCommand(context) {
  return helper(context, "list")
}

function parseList(output) {
  var answer = parseAnswer(output)
  if (!Array.isArray(answer)) return null
  var out = []
  for (var i = 0; i < answer.length && out.length < 20; i++) {
    var f = answer[i]
    if (!f || !/^f[0-9a-f]{16}$/.test(String(f.id))) continue
    out.push({ id: String(f.id), name: String(f.name || "").substr(0, 128),
      color: String(f.color || "").substr(0, 32), host: String(f.host || "").substr(0, 256) })
  }
  return out
}

// Adding sends the address on stdin; removing names the feed by its id.
function addCommand(name, url, context) {
  return { command: helper(context, "add"), input: JSON.stringify({ name: String(name || ""), url: String(url || "") }) }
}

function removeCommand(id, context) {
  return { command: /^f[0-9a-f]{16}$/.test(String(id)) ? helper(context, "remove", [String(id)]) : [], input: "" }
}

// "webcal://" and "https://" addresses are feeds.
function isFeedAddress(text) {
  return /^(https|webcal):\/\/[^\s"'<>\\]+$/i.test(String(text || "").replace(/^\s+|\s+$/g, ""))
}

function canDelete() {
  return false
}

function writeCommand() {
  return { command: [], input: "" }
}

function writeResult(exitCode, output) {
  var answer = parseAnswer(output)
  if (exitCode === 0 && answer && answer.ok === true) return { ok: true, message: String(answer.message || "") }
  if (answer && answer.error) return { ok: false, message: String(answer.error).substr(0, 300) }
  if (exitCode === 124) return { ok: false, message: "The feed took too long to answer." }
  return { ok: false, message: "Calendar for Omarchy could not change the feeds (exit " + exitCode + ")." }
}

function dayUrl() {
  return ""
}

if (typeof module !== "undefined") {
  module.exports = {
    info: info,
    helper: helper,
    probeCommand: probeCommand,
    probe: probe,
    modeNote: modeNote,
    fetchCommand: fetchCommand,
    calendarsCommand: calendarsCommand,
    listCommand: listCommand,
    parseList: parseList,
    addCommand: addCommand,
    removeCommand: removeCommand,
    isFeedAddress: isFeedAddress,
    canDelete: canDelete,
    writeCommand: writeCommand,
    writeResult: writeResult,
    dayUrl: dayUrl
  }
}
