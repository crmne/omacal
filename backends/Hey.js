// The HEY backend: what OmaCal runs to read and write a HEY calendar, all
// of it through the HEY CLI (https://github.com/basecamp/hey-cli).
//
// A backend is a file of command lines and a few facts about itself. It
// never parses anything: every command prints the standard shapes
// Calendar.js reads (see "Backends" at the top of Calendar.js), so adding a
// calendar service means writing the commands that print them, not new
// parsing. It is Qt-free and self-contained, so it runs under plain node.

var info = {
  id: "hey",
  name: "HEY",
  capabilities: {
    create: true,
    // Title, day, times, zones, place, calendar and reminder, in the panel.
    edit: true,
    // One-off events only: deleting by id would take a whole series.
    delete: true,
    // `hey watch` streams every calendar change as it happens.
    watch: true,
    // HEY's own stopwatch, filed on the calendar.
    timeTracking: true,
    // Every day has a page in HEY's web app.
    dayLink: true
  }
}

var cliTimeoutSeconds = 20
var cliKillGraceSeconds = 3
var cliOutputByteLimit = 4 * 1024 * 1024
var maximumWeeksPerFetch = 8

function isDayKey(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))
}

function shiftDay(key, delta) {
  var parts = String(key).split("-")
  var date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) + delta)
  var month = date.getMonth() + 1
  var day = date.getDate()
  return date.getFullYear() + "-" + (month < 10 ? "0" : "") + month + "-" + (day < 10 ? "0" : "") + day
}

// ---------------------------------------------------------------------------
// Probe: which HEY CLI is installed, and so how to read it
// ---------------------------------------------------------------------------

// Omarchy packages hey-cli 1.3.0, and that is the floor. 1.4.0 added `hey
// event week`, HEY's own expansion of a week with every repeating series
// unrolled, which is exact and preferred. On 1.3.0 the same span is read
// with `hey event list`, which returns each series once, and Calendar.js
// unrolls the repeats itself.
var minimumCliVersion = [1, 3, 0]
var weekViewCliVersion = [1, 4, 0]

var probeCommand = ["bash", "-c", "timeout 5 hey --version 2>/dev/null | head -c 200", "omacal"]

// "hey version 1.7.0" → [1, 7, 0], or null.
function parseCliVersion(raw) {
  var match = /(\d+)\.(\d+)\.(\d+)/.exec(String(raw || ""))
  if (!match) return null
  return [parseInt(match[1], 10), parseInt(match[2], 10), parseInt(match[3], 10)]
}

function compareVersions(a, b) {
  for (var i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1
  return 0
}

function formatVersion(version) {
  return version ? version.join(".") : ""
}

// Reads the probe's answer: { mode, version, error }. The mode is "week"
// (1.4.0 and newer), "list" (1.3.x), or "" when the CLI cannot be used, with
// `error` saying why. A version that cannot be read (a development build,
// say) is taken to be new: guessing old would hide what `hey event week`
// knows.
function probe(output) {
  var text = String(output || "").replace(/^\s+|\s+$/g, "")
  if (text === "")
    return { mode: "", version: "", error: "The HEY CLI is not installed. Install hey-cli and run `hey setup`." }
  var version = parseCliVersion(text)
  if (version === null) return { mode: "week", version: "", error: "" }
  if (compareVersions(version, minimumCliVersion) < 0)
    return { mode: "", version: formatVersion(version),
      error: "hey-cli " + formatVersion(version) + " is too old. OmaCal needs " + formatVersion(minimumCliVersion) + " or newer." }
  return { mode: compareVersions(version, weekViewCliVersion) < 0 ? "list" : "week", version: formatVersion(version), error: "" }
}

// A note for the settings, about what this CLI can and cannot see.
function modeNote(mode, version) {
  return mode === "list"
    ? "hey-cli " + version + " cannot see which calendars are switched off in HEY, so hide them here."
    : "Calendars switched off in HEY are already left out."
}

// ---------------------------------------------------------------------------
// Reading events
// ---------------------------------------------------------------------------

// Projects HEY's events down to the standard event shape. Everything is
// defaulted here so a missing field is an empty string rather than a `null`
// that every binding has to guard against.
var eventProjection = "map({"
  + "id: .id,"
  + " occurrence_id: (.occurrence_id // \"\"),"
  + " parent_id: (.parent_id // \"\"),"
  + " recurring: (((.recurrence_schedule // {}) | length) > 0 or .parent_id != null),"
  + " title: (.title // .summary // \"(untitled)\"),"
  + " all_day: (.all_day // false),"
  + " starts_at: (.starts_at // \"\"),"
  + " ends_at: (.ends_at // \"\"),"
  + " location: (.location // \"\"),"
  + " calendar_id: (.calendar.id // 0),"
  + " calendar: (.calendar.name // \"Personal\"),"
  + " color: (.calendar.color // \"\"),"
  + " join_url: (.join_link.url // \"\"),"
  + " join_title: (.join_link.title // \"\"),"
  + " url: (.edit_url // \"\"),"
  + " status: (.attendance_status // \"\"),"
  + " reminders: [(.reminders // [])[] | .remind_at // empty],"
  + " reminder_leads: [(.reminders // [])[] | .duration // empty],"
  + " repeat_kind: ((.recurrence_schedule // {}).kind // \"\"),"
  + " repeat_description: ((.recurrence_schedule // {}).description // \"\")"
  + "})"

// 1.4.0 and newer. Every week of the range is fetched at once and in
// parallel: six `hey event week` calls side by side take about as long as
// one. Each writes its own file, so a large week can never interleave with
// another on the pipe, and the results come back one JSON line per week.
//
// A week that failed is reported as failed rather than as empty. An empty
// answer is the shape every failure takes with the CLI (missing, signed
// out, offline), and drawing it as a clear week would be a lie.
//
// `timeout` bounds a CLI that never answers and `head -c` one that answers
// forever. The filter and the dates are arguments, never interpolated.
var weekScript = [
  "dir=$(mktemp -d) || exit 1",
  "trap 'rm -rf \"$dir\"' EXIT",
  "filter=$1; shift",
  "for d in \"$@\"; do",
  "  (timeout -k " + cliKillGraceSeconds + " " + cliTimeoutSeconds
    + " hey event week \"$d\" --json --all > \"$dir/$d\" 2>/dev/null) &",
  "done",
  "wait",
  "for d in \"$@\"; do",
  "  if jq -e '.ok == true' \"$dir/$d\" >/dev/null 2>&1; then",
  "    jq -c --arg w \"$d\" \"{week: \\$w, events: (.data | $filter)}\" \"$dir/$d\" 2>/dev/null"
    + " || printf '{\"week\":\"%s\",\"error\":true}\\n' \"$d\"",
  "  else",
  "    printf '{\"week\":\"%s\",\"error\":true}\\n' \"$d\"",
  "  fi",
  "done | head -c " + (cliOutputByteLimit + 1)
].join("\n")

function weekCommand(weekKeys) {
  var keys = []
  var list = Array.isArray(weekKeys) ? weekKeys : []
  for (var i = 0; i < list.length && keys.length < maximumWeeksPerFetch; i++)
    if (isDayKey(list[i]) && keys.indexOf(list[i]) === -1) keys.push(list[i])
  return ["bash", "-c", weekScript, "omacal", eventProjection].concat(keys)
}

// 1.3.x: one `hey event list` over the whole span, as a single span line.
var listScript = "timeout -k " + cliKillGraceSeconds + " " + cliTimeoutSeconds
  + " hey event list --starts-on \"$4\" --ends-on \"$5\" --json --all 2>/dev/null"
  + " | jq -c --arg a \"$2\" --arg b \"$3\" \"if .ok == true then {list: true, first: \\$a, last: \\$b, events: (.data | $1)}"
  + " else {list: true, first: \\$a, last: \\$b, error: true} end\" 2>/dev/null"
  + " | head -c " + (cliOutputByteLimit + 1)

function listCommand(weekKeys) {
  var keys = []
  var list = Array.isArray(weekKeys) ? weekKeys : []
  for (var i = 0; i < list.length; i++) if (isDayKey(list[i])) keys.push(list[i])
  if (keys.length === 0) return []
  keys.sort()
  var first = keys[0]
  var last = shiftDay(keys[keys.length - 1], 6)
  // `hey event list` draws its window in UTC, so an evening event on the
  // last day east of Greenwich would fall off the end. A day either side is
  // asked for, and Calendar.js trims back to the span.
  return ["bash", "-c", listScript, "omacal", eventProjection, first, last,
    shiftDay(first, -1), shiftDay(last, 1)]
}

// The weeks named by their Mondays, read the way the probe said to.
function fetchCommand(mode, weekKeys) {
  return mode === "list" ? listCommand(weekKeys) : weekCommand(weekKeys)
}

// Named calendars only. The unnamed personal calendar holds todos, habits
// and the journal rather than events, and HEY's own form never offers it.
var calendarsCommand = ["bash", "-c",
  "timeout -k 3 20 hey calendar list --json 2>/dev/null"
  + " | jq -c '[.data[] | select(.name != null and .name != \"\")"
  + " | {id, name, color: (.color // \"\"), kind: (.kind // \"\"), owned: (.owned // false)}]'"
  + " | head -c 262144",
  "omacal"]

// Calendar changes as HEY makes them, one JSON line each; any line but the
// watch's own "ready" and "disconnected" means something changed. Mail is
// left out: naming only calendar changes switches the mail side off.
var watchCommand = ["hey", "watch", "--events",
  "recording_added,recording_updated,recording_deleted,calendar_added,calendar_updated,calendar_deleted,calendar_resync"]

function isWatchChange(line) {
  var text = String(line || "")
  return text.indexOf("\"ready\"") === -1 && text.indexOf("\"disconnected\"") === -1
}

// ---------------------------------------------------------------------------
// Writing events
// ---------------------------------------------------------------------------

// `request` is Calendar.validateEvent's output: already checked, times as
// HH:MM, the end date worked out. The command is an argv, never a shell
// line, so a title can hold any character it likes.
function createCommand(request) {
  var r = request || {}
  var args = ["timeout", "-k", "3", "30", "hey", "event", "add", "--title", r.title, "--starts-on", r.date]
  var across = false
  if (r.allDay) {
    args.push("--all-day")
    if (r.endDate && r.endDate !== r.date) args.push("--ends-on", r.endDate)
  } else {
    // Every hey-cli from 1.3.0 takes --time-zone; without it the clock
    // times land in UTC or the HEY account's zone (see Calendar.js).
    args.push("--start-time", r.startTime, "--time-zone", r.timeZone)
    across = !!r.endTime && !!r.endTimeZone && r.endTimeZone !== r.timeZone
    if (!across) {
      if (r.endDate && r.endDate !== r.date) args.push("--ends-on", r.endDate)
      if (r.endTime) args.push("--end-time", r.endTime)
    }
  }
  if (Number(r.calendarId) > 0) args.push("--calendar", String(Math.round(Number(r.calendarId))))
  if (r.location) args.push("--location", r.location)
  if (r.remind) args.push("--remind", r.remind)
  args.push("--json")
  if (!across) return args
  return ["sh", "-c", acrossZonesScript, "sh", r.timeZone, r.date, r.startTime, r.endTimeZone, r.endTime].concat(args)
}

// HEY keeps a zone for each end of an event, but `hey event add` takes one
// --time-zone for both. An end on another clock (a flight from Berlin at
// 10:00 to New York at 13:00) is moved onto the start's with GNU date: the
// same instant, as the start's zone reads it, on the first day it falls
// after the start. HEY then shows that end on the start's clock.
// Arguments: start zone, start day, start time, end zone, end time, then
// the hey command. Answers in HEY's JSON envelope when it cannot.
var acrossZonesScript =
  "tz=$1 day=$2 start=$3 ez=$4 et=$5; shift 5; " +
  "fail() { printf '{\"ok\":false,\"error\":\"%s\"}\\n' \"$1\"; exit 1; }; " +
  "s=$(TZ=$tz date -d \"$day $start\" +%s) || fail 'Could not read the start time.'; " +
  "e=$(TZ=$ez date -d \"$day $et\" +%s) || fail 'Could not read the end time.'; " +
  "if [ \"$e\" -le \"$s\" ]; then " +
  "next=$(date -d \"$day +1 day\" +%F) && e=$(TZ=$ez date -d \"$next $et\" +%s) || fail 'Could not read the end time.'; fi; " +
  "[ \"$e\" -gt \"$s\" ] || fail 'It has to end after it starts.'; " +
  "end=$(TZ=$tz date -d \"@$e\" '+%F %H:%M') || fail 'Could not read the end time.'; " +
  "exec \"$@\" --ends-on \"${end% *}\" --end-time \"${end#* }\""

// hey-cli edits one day of a series with --occurrence from 1.6.0 on;
// before that, `hey event edit` takes a series whole.
var occurrenceCliVersion = [1, 6, 0]

function editsOccurrences(version) {
  var parsed = parseCliVersion(version)
  return parsed === null ? String(version || "") === "" : compareVersions(parsed, occurrenceCliVersion) >= 0
}

// `request` is Calendar.editRequest's: { event, scope, changes }. Only the
// changed fields become flags; `hey event edit` reads the event and sends
// the rest back as it was. Empty when the event cannot be named safely.
function editCommand(request) {
  var r = request || {}
  var event = r.event || {}
  var changes = r.changes || {}
  var id = /^\d+$/.test(String(event.seriesId || "")) ? String(event.seriesId) : ""
  var parent = /^\d+$/.test(String(event.parentId || "")) ? String(event.parentId) : ""
  var occurrence = /^[0-9A-Za-z_-]+$/.test(String(event.occurrenceId || "")) ? String(event.occurrenceId) : ""
  var target = []
  if (!event.recurring) target = id ? [id] : []
  else if (r.scope === "one") {
    // A day HEY wrote out edits alone by its own id; any other day is the
    // series' occurrence.
    if (parent !== "" && parent !== id && id !== "") target = [id]
    else if (occurrence !== "") target = [parent || id, "--occurrence", occurrence, "--apply-to", "current"]
  } else {
    target = (parent || id) ? [parent || id] : []
  }
  if (target.length === 0 || target[0] === "") return []

  var args = ["timeout", "-k", "3", "40", "hey", "event", "edit"].concat(target)
  if (changes.title !== undefined) args.push("--title", changes.title)
  if (changes.location !== undefined) args.push("--location", changes.location)
  if (changes.calendarId) args.push("--calendar", String(Math.round(Number(changes.calendarId))))
  if (changes.remind) args.push("--remind", changes.remind)

  var s = changes.schedule
  var across = false
  if (s) {
    if (s.allDay) {
      args.push("--all-day")
      if (s.dates) args.push("--starts-on", s.date, "--ends-on", s.endDate)
    } else {
      if (s.dates) args.push("--starts-on", s.date)
      args.push("--start-time", s.startTime, "--time-zone", s.timeZone)
      across = !!s.endTimeZone && s.endTimeZone !== s.timeZone && !!s.endTime
      if (!across) {
        if (s.dates) args.push("--ends-on", s.endDate)
        if (s.endTime) args.push("--end-time", s.endTime)
      }
    }
  }
  args.push("--json")
  if (!across) return args
  return ["sh", "-c", acrossZonesScript, "sh", s.timeZone, s.date, s.startTime, s.endTimeZone, s.endTime].concat(args)
}

function deleteCommand(event) {
  if (!event || event.recurring) return []
  var id = String(event.seriesId || "")
  if (!/^\d+$/.test(id)) return []
  return ["timeout", "-k", "3", "20", "hey", "event", "delete", id, "--json"]
}

// Every write answers with HEY's JSON envelope: { ok, summary | error }.
function writeResult(exitCode, stdout) {
  var parsed = null
  try {
    parsed = JSON.parse(String(stdout || ""))
  } catch (e) {
    parsed = null
  }
  if (parsed && parsed.ok === true) return { ok: true, message: String(parsed.summary || "") }
  var message = parsed ? String(parsed.error || parsed.summary || "") : ""
  if (message === "")
    message = exitCode === 124 ? "HEY took too long to answer." : "HEY did not accept that (exit " + exitCode + ")."
  return { ok: false, message: message }
}

// ---------------------------------------------------------------------------
// Time tracking
// ---------------------------------------------------------------------------

// The track under way, in the standard shape:
// { ok: true, track: { id, name, starts_at } | null }, or { ok: false }.
// HEY names a track by its category, and calls one without "Time Track".
var currentTrackCommand = ["bash", "-c",
  "timeout -k 3 20 hey timetrack current --json 2>/dev/null"
  + " | jq -c 'if .ok == true then {ok: true, track: (if .data then {id: .data.id,"
  + " name: ((.data.category // \"\") | if . == \"\" then null else . end) // .data.title // \"\","
  + " starts_at: .data.starts_at} else null end)} else {ok: false} end'"
  + " | head -c 65536",
  "omacal"]

// Finished tracks, newest first, in the standard shape. `hey timetrack
// list` has no date window, so the newest few hundred are read; that covers
// the weeks anyone browses.
var tracksCommand = ["bash", "-c",
  "timeout -k 3 20 hey timetrack list --json --limit 300 2>/dev/null"
  + " | jq -c '[.data[] | {id, name: ((.category // \"\") | if . == \"\" then null else . end) // .title // \"\","
  + " named: ((.category // \"\") != \"\"), notes: (.notes // \"\"),"
  + " starts_at: (.starts_at // \"\"), ends_at: (.ends_at // \"\")}]'"
  + " | head -c 1048576",
  "omacal"]

function trackStartCommand() {
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "start", "--json"]
}

function trackStopCommand() {
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "stop", "--json"]
}

// HEY names a track by its category: editing one "files the track under a
// category title, which HEY creates if it has none by that title".
function trackRenameCommand(id, name) {
  var trackId = String(id || "")
  var title = String(name || "").replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(trackId) || title === "") return []
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "edit", trackId, "--category", title.substr(0, 128), "--json"]
}

function trackDeleteCommand(id) {
  var trackId = String(id || "")
  if (!/^\d+$/.test(trackId)) return []
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "delete", trackId, "--json"]
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

function dayUrl(dayKey) {
  return isDayKey(dayKey) ? "https://app.hey.com/calendar/days/" + dayKey : "https://app.hey.com/calendar"
}

if (typeof module !== "undefined") {
  module.exports = {
    info: info,
    minimumCliVersion: minimumCliVersion,
    probeCommand: probeCommand,
    parseCliVersion: parseCliVersion,
    probe: probe,
    modeNote: modeNote,
    eventProjection: eventProjection,
    fetchCommand: fetchCommand,
    weekCommand: weekCommand,
    listCommand: listCommand,
    calendarsCommand: calendarsCommand,
    watchCommand: watchCommand,
    isWatchChange: isWatchChange,
    createCommand: createCommand,
    editCommand: editCommand,
    editsOccurrences: editsOccurrences,
    deleteCommand: deleteCommand,
    writeResult: writeResult,
    currentTrackCommand: currentTrackCommand,
    tracksCommand: tracksCommand,
    trackStartCommand: trackStartCommand,
    trackStopCommand: trackStopCommand,
    trackRenameCommand: trackRenameCommand,
    trackDeleteCommand: trackDeleteCommand,
    dayUrl: dayUrl
  }
}
