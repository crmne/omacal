// The Google Calendar backend: what Calendar for Omarchy runs to read and write Google
// calendars. The work is done by backends/google.py, which signs in with
// gws, the Google Workspace CLI (https://github.com/googleworkspace/cli),
// and talks to Google's Calendar API over HTTPS. Its arguments are an
// action and week dates only: a write's request, with the title and place
// in it, goes on the helper's stdin.
//
// The first version of this backend was written by David Paluy (PR #2).
//
// Qt-free and self-contained, so it runs under plain node.

var info = {
  id: "google",
  name: "Google",
  capabilities: {
    create: true,
    edit: true,
    // One-off events without guests, checked against Google first.
    delete: true,
    // Google pushes changes only to a public web address, so it is polled.
    watch: false,
    timeTracking: false,
    dayLink: true,
    // An edit can leave an event with no reminders.
    clearsReminders: true
  }
}

var helperTimeoutSeconds = 90
var maximumWeeksPerFetch = 8

function isDayKey(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))
}

// The system Python, isolated (-I) from the user's environment and
// site-packages: the helper needs nothing past the standard library.
function helper(context, action, args) {
  var dir = String(context && context.dir ? context.dir : "").replace(/\/+$/, "")
  return ["timeout", "-k", "3", String(helperTimeoutSeconds), "/usr/bin/python3", "-I",
    dir + "/backends/google.py", action].concat(args || [])
}

function probeCommand(context) {
  return helper(context, "probe")
}

// { mode, version, account, error, missing }: "api" once Google answered
// as the account gws is signed in to.
function probe(output) {
  var answer = parseAnswer(output)
  if (answer && answer.ok === true)
    return { mode: "api", version: "", account: String(answer.account || "").substr(0, 256), error: "" }
  if (answer && answer.error)
    return { mode: "", version: "", account: "", missing: answer.missing === true, error: String(answer.error).substr(0, 300) }
  return { mode: "", version: "", account: "", error: "Google Calendar could not start. Is /usr/bin/python3 there?" }
}

function parseAnswer(output) {
  var line = String(output || "").replace(/^\s+|\s+$/g, "").split("\n")[0]
  try {
    var value = JSON.parse(line)
    return value && typeof value === "object" && !Array.isArray(value) ? value : null
  } catch (e) {
    return null
  }
}

function modeNote() {
  return "Google calendars switched off in Google Calendar's own list are left out."
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

function canDelete(event) {
  return !!event && !event.recurring && event.editable !== false
    && String(event.seriesId || "") !== "" && String(event.calendarId || "") !== ""
}

// What the helper needs to name an event to Google, and no more of it.
function eventReference(event) {
  var e = event || {}
  return { seriesId: String(e.seriesId || ""), parentId: String(e.parentId || ""),
    occurrenceId: String(e.occurrenceId || ""), calendarId: String(e.calendarId || ""),
    recurring: e.recurring === true, allDay: e.allDay === true }
}

// kind: "create" (Calendar.validateEvent's request), "edit"
// (Calendar.editRequest's) or "delete" ({ event }). The command is the
// same for all three; the request is its stdin.
function writeCommand(kind, payload, context) {
  var p = payload || {}
  var request
  if (kind === "create") request = p
  else if (kind === "edit") request = { event: eventReference(p.event), scope: p.scope, changes: p.changes }
  else if (kind === "delete") request = { event: eventReference(p.event) }
  else return { command: [], input: "" }
  return { command: helper(context, "write"), input: JSON.stringify({ kind: kind, request: request }) }
}

function writeResult(exitCode, output) {
  var answer = parseAnswer(output)
  if (exitCode === 0 && answer && answer.ok === true) return { ok: true, message: String(answer.message || "") }
  if (answer && answer.error) return { ok: false, message: String(answer.error).substr(0, 300) }
  if (exitCode === 124) return { ok: false, message: "Google took too long to answer. Refresh before trying again." }
  return { ok: false, message: "Google did not confirm the change. Refresh before trying again." }
}

// Google's web app on that day, as the account Calendar for Omarchy reads.
function dayUrl(dayKey, account) {
  var who = account ? "?authuser=" + encodeURIComponent(String(account)) : ""
  return isDayKey(dayKey)
    ? "https://calendar.google.com/calendar/r/day/" + dayKey.replace(/-/g, "/") + who
    : "https://calendar.google.com/calendar/r" + who
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
    canDelete: canDelete,
    writeCommand: writeCommand,
    writeResult: writeResult,
    dayUrl: dayUrl
  }
}
