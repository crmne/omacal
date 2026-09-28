// HEY data, date math and command lines for the calendar panel.
//
// Model.js is Omarchy's own clock model and stays byte-for-byte stock, so a
// newer Omarchy can be dropped in over it. Everything HEY knows lives here
// instead. Like Model.js it is Qt-free, so it runs under plain node
// (tests/run); the QML owns every pixel and every process.

var MS_PER_DAY = 86400000

// ---------------------------------------------------------------------------
// HEY CLI
// ---------------------------------------------------------------------------

// Projects `hey event week --json` down to what the panel draws. Everything
// is defaulted here so a missing field is an empty string rather than a
// `null` that every binding has to guard against.
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
  + " repeat_kind: ((.recurrence_schedule // {}).kind // \"\"),"
  + " repeat_description: ((.recurrence_schedule // {}).description // \"\")"
  + "})"

var cliTimeoutSeconds = 20
var cliKillGraceSeconds = 3
var cliOutputByteLimit = 4 * 1024 * 1024
var maximumEventCount = 2000
var maximumWeeksPerFetch = 8

// Every week of the range is fetched at once and in parallel: six `hey event
// week` calls side by side take about as long as one. Each writes its own
// file, so a large week can never interleave with another on the pipe, and
// the results come back one JSON line per week, in the order asked for.
//
// A week that failed is reported as failed rather than as empty. An empty
// answer is the shape every failure takes with the CLI (missing, signed out,
// offline), and drawing it as a clear week would be a lie.
//
// `timeout` bounds a CLI that never answers and `head -c` one that answers
// forever. The filter and the dates are arguments, never interpolated.
var rangeScript = [
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

function isDayKey(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))
}

// ---- CLI versions
//
// Omarchy packages hey-cli 1.3.0, and that is the floor. 1.4.0 added `hey
// event week`, HEY's own expansion of a week with every repeating series
// unrolled, which is exact and preferred. On 1.3.0 the plugin reads the
// same span with `hey event list`, which returns each series once, and
// unrolls the repeats itself (see expandRecurring).
var minimumCliVersion = [1, 3, 0]
var weekViewCliVersion = [1, 4, 0]

var versionCommand = ["bash", "-c", "timeout 5 hey --version 2>/dev/null | head -c 200", "hey-calendar"]

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

// "week" (1.4.0 and newer), "list" (1.3.x), or "" when the CLI is missing
// or too old. A version that cannot be read (a development build, say) is
// taken to be new: guessing old would hide what `hey event week` knows.
function cliMode(versionOutput) {
  var text = String(versionOutput || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return ""
  var version = parseCliVersion(text)
  if (version === null) return "week"
  if (compareVersions(version, minimumCliVersion) < 0) return ""
  return compareVersions(version, weekViewCliVersion) < 0 ? "list" : "week"
}

function formatVersion(version) {
  return version ? version.join(".") : ""
}

// 1.3.x: one `hey event list` over the whole span, as a single
// { list, first, last, events } line. parseRangeOutput unrolls it into the
// same per-week shape `hey event week` produces.
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
  var last = addDays(keys[keys.length - 1], 6)
  // `hey event list` draws its window in UTC, so an evening event on the
  // last day east of Greenwich would fall off the end. A day either side is
  // asked for, and expandAll trims back to the span.
  return ["bash", "-c", listScript, "hey-calendar", eventProjection, first, last,
    addDays(first, -1), addDays(last, 1)]
}

function fetchCommand(mode, weekKeys) {
  return mode === "list" ? listCommand(weekKeys) : rangeCommand(weekKeys)
}

function rangeCommand(weekKeys) {
  var keys = []
  var list = Array.isArray(weekKeys) ? weekKeys : []
  for (var i = 0; i < list.length && keys.length < maximumWeeksPerFetch; i++)
    if (isDayKey(list[i]) && keys.indexOf(list[i]) === -1) keys.push(list[i])
  return ["bash", "-c", rangeScript, "hey-calendar", eventProjection].concat(keys)
}

// Named calendars only. The unnamed personal calendar holds todos, habits
// and the journal rather than events, and HEY's own form never offers it.
var calendarsCommand = ["bash", "-c",
  "timeout -k 3 20 hey calendar list --json 2>/dev/null"
  + " | jq -c '[.data[] | select(.name != null and .name != \"\")"
  + " | {id, name, color: (.color // \"\"), kind: (.kind // \"\"), owned: (.owned // false)}]'"
  + " | head -c 262144",
  "hey-calendar"]

var timeTrackCommand = ["bash", "-c",
  "timeout -k 3 20 hey timetrack current --json 2>/dev/null | head -c 65536",
  "hey-calendar"]

// Calendar changes as HEY makes them, one JSON line each. Mail is left out:
// naming only calendar changes switches the mail side of the watch off.
var watchCommand = ["hey", "watch", "--events",
  "recording_added,recording_updated,recording_deleted,calendar_added,calendar_updated,calendar_deleted,calendar_resync"]

// Finished time tracks, newest first. `hey timetrack list` has no date
// window, so the newest few hundred are read and filed by day here; that
// covers the weeks anyone browses.
var timeTracksCommand = ["bash", "-c",
  "timeout -k 3 20 hey timetrack list --json --limit 300 2>/dev/null"
  + " | jq -c '[.data[] | {id, title: (.title // \"\"), category: (.category // \"\"),"
  + " notes: (.notes // \"\"), starts_at: (.starts_at // \"\"), ends_at: (.ends_at // \"\")}]'"
  + " | head -c 1048576",
  "hey-calendar"]

// HEY names a track by its category: editing one "files the track under a
// category title, which HEY creates if it has none by that title".
function timeTrackRenameCommand(id, name) {
  var trackId = String(id || "")
  var title = String(name || "").replace(/^\s+|\s+$/g, "")
  if (!/^\d+$/.test(trackId) || title === "") return []
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "edit", trackId, "--category", title.substr(0, 128), "--json"]
}

function timeTrackDeleteCommand(id) {
  var trackId = String(id || "")
  if (!/^\d+$/.test(trackId)) return []
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "delete", trackId, "--json"]
}

function timeTrackStartCommand() {
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "start", "--json"]
}

function timeTrackStopCommand() {
  return ["timeout", "-k", "3", "20", "hey", "timetrack", "stop", "--json"]
}

function deleteCommand(event) {
  if (!event || event.recurring) return []
  var id = String(event.seriesId || "")
  if (!/^\d+$/.test(id)) return []
  return ["timeout", "-k", "3", "20", "hey", "event", "delete", id, "--json"]
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function boundedString(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  return text.length > limit ? text.substr(0, limit) : text
}

// Only ever handed to a browser launcher, so anything that is not plainly a
// web URL is dropped rather than passed along.
function safeUrl(value) {
  var text = boundedString(value, 2048).replace(/^\s+|\s+$/g, "")
  return /^https:\/\/[^\s"'<>\\]+$/.test(text) ? text : ""
}

function parseInstant(value) {
  var ms = Date.parse(String(value || ""))
  return isFinite(ms) ? ms : null
}

// Titles, locations and calendar names are text somebody else wrote, so every
// string that reaches a binding is length-capped here and rendered as
// PlainText there.
function normalizeEvent(raw) {
  if (!raw || typeof raw !== "object") return null

  var startsAt = boundedString(raw.starts_at, 64)
  if (startsAt === "") return null

  var allDay = raw.all_day === true
  var reminders = []
  var rawReminders = Array.isArray(raw.reminders) ? raw.reminders : []
  for (var i = 0; i < rawReminders.length && reminders.length < 8; i++) {
    var at = parseInstant(rawReminders[i])
    if (at !== null) reminders.push(at)
  }

  var seriesId = boundedString(raw.id, 32)
  var occurrenceId = boundedString(raw.occurrence_id, 96)
  return {
    // A repeating series shares one id across every day it lands on, so the
    // start is part of the identity: two Mondays of a standup are two rows.
    key: (occurrenceId || seriesId) + "@" + startsAt,
    seriesId: seriesId,
    occurrenceId: occurrenceId,
    recurring: raw.recurring === true,
    title: boundedString(raw.title, 256) || "(untitled)",
    allDay: allDay,
    startsAt: startsAt,
    endsAt: boundedString(raw.ends_at, 64) || startsAt,
    location: boundedString(raw.location, 256),
    calendarId: Number(raw.calendar_id) || 0,
    calendar: boundedString(raw.calendar, 128),
    color: boundedString(raw.color, 32).toLowerCase(),
    joinUrl: safeUrl(raw.join_url),
    joinTitle: boundedString(raw.join_title, 64),
    url: safeUrl(raw.url),
    status: boundedString(raw.status, 32),
    reminders: reminders,
    repeatKind: boundedString(raw.repeat_kind, 32),
    repeatDescription: boundedString(raw.repeat_description, 256),
    // Resolved once, here, so nothing downstream has to remember that an
    // all-day event is a floating date rather than an instant.
    startMs: allDay ? null : parseInstant(startsAt),
    endMs: allDay ? null : parseInstant(raw.ends_at || startsAt)
  }
}

function normalizeEvents(list) {
  var events = []
  var raw = Array.isArray(list) ? list : []
  for (var i = 0; i < raw.length && events.length < maximumEventCount; i++) {
    var event = normalizeEvent(raw[i])
    if (event) events.push(event)
  }
  return events
}

// One line per week: { week, events } or { week, error: true }. Returns a map
// from week key to its events, with `null` for a week that failed, or null
// when the output as a whole is unusable.
function parseRangeOutput(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.length > cliOutputByteLimit) return null

  var weeks = {}
  var found = false
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (line === "") continue
    var parsed
    try {
      parsed = JSON.parse(line)
    } catch (e) {
      continue
    }
    if (parsed && parsed.list === true && isDayKey(parsed.first) && isDayKey(parsed.last)) {
      found = true
      var listed = parsed.error === true || !Array.isArray(parsed.events)
        ? null
        : expandAll(normalizeEvents(parsed.events), parsed.first, parsed.last)
      var spanWeeks = weekKeysBetween(parsed.first, parsed.last)
      var bucketed = listed === null ? null : bucketByWeek(listed, spanWeeks)
      for (var w = 0; w < spanWeeks.length; w++)
        weeks[spanWeeks[w]] = bucketed === null ? null : bucketed[spanWeeks[w]]
      continue
    }
    if (!parsed || !isDayKey(parsed.week)) continue
    found = true
    weeks[parsed.week] = parsed.error === true || !Array.isArray(parsed.events)
      ? null
      : normalizeEvents(parsed.events)
  }
  return found ? weeks : null
}

function parseCalendars(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).replace(/^\s+|\s+$/g, "")
  if (text === "") return null
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!Array.isArray(parsed)) return null

  var calendars = []
  for (var i = 0; i < parsed.length && calendars.length < 100; i++) {
    var c = parsed[i]
    if (!c || !(Number(c.id) > 0)) continue
    calendars.push({
      id: Number(c.id),
      name: boundedString(c.name, 128),
      color: boundedString(c.color, 32).toLowerCase(),
      kind: boundedString(c.kind, 32),
      owned: c.owned === true
    })
  }
  return calendars
}

// Calendars a new event can go on: the ones you own. "Maybe" is HEY's own
// holding pen for tentative plans and is kept, last, the way HEY lists it.
function writableCalendars(calendars) {
  var list = Array.isArray(calendars) ? calendars : []
  var normal = []
  var maybe = []
  for (var i = 0; i < list.length; i++) {
    if (!list[i].owned) continue
    if (list[i].kind === "maybe") maybe.push(list[i])
    else normal.push(list[i])
  }
  return normal.concat(maybe)
}

// `hey timetrack current --json`: the track under way, or null when there is
// none. `undefined` means the answer itself was unusable.
function parseTimeTrack(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).replace(/^\s+|\s+$/g, "")
  if (text === "") return undefined
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return undefined
  }
  if (!parsed || parsed.ok !== true) return undefined
  var data = parsed.data
  if (!data || typeof data !== "object") return null
  var startMs = parseInstant(data.starts_at)
  if (startMs === null) return null
  return {
    id: boundedString(data.id, 32),
    title: boundedString(data.category, 128) || boundedString(data.title, 256),
    startMs: startMs
  }
}

// A finished track, shaped enough like a timed event that the same day
// math files it: the days it covers, where it starts and ends.
function normalizeTimeTrack(raw) {
  if (!raw || typeof raw !== "object") return null
  var startMs = parseInstant(raw.starts_at)
  var endMs = parseInstant(raw.ends_at)
  if (startMs === null) return null
  var category = boundedString(raw.category, 128)
  var title = boundedString(raw.title, 256)
  return {
    key: "track:" + boundedString(raw.id, 32),
    id: boundedString(raw.id, 32),
    category: category,
    // "Time Track" is what HEY calls one nobody named.
    name: category || title || "Time Track",
    named: category !== "",
    notes: boundedString(raw.notes, 1024),
    allDay: false,
    startMs: startMs,
    endMs: endMs === null || endMs < startMs ? startMs : endMs
  }
}

function parseTimeTracks(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).replace(/^\s+|\s+$/g, "")
  if (text === "") return null
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!Array.isArray(parsed)) return null
  var tracks = []
  for (var i = 0; i < parsed.length && tracks.length < 1000; i++) {
    var track = normalizeTimeTrack(parsed[i])
    if (track) tracks.push(track)
  }
  return tracks
}

// Day key → that day's tracks, earliest first.
function tracksByDay(tracks) {
  var index = {}
  var list = Array.isArray(tracks) ? tracks : []
  for (var i = 0; i < list.length; i++) {
    var keys = eventDayKeys(list[i])
    for (var k = 0; k < keys.length; k++) {
      if (!index[keys[k]]) index[keys[k]] = []
      index[keys[k]].push(list[i])
    }
  }
  for (var key in index) index[key].sort(function(a, b) { return a.startMs - b.startMs })
  return index
}

// Time tracked on a day: only the part of each track that falls on it.
function trackedOnDay(tracks, dayKey) {
  var dayStart = dateFromKey(dayKey).getTime()
  var dayEnd = dateFromKey(addDays(dayKey, 1)).getTime()
  var total = 0
  var list = Array.isArray(tracks) ? tracks : []
  for (var i = 0; i < list.length; i++)
    total += Math.max(0, Math.min(list[i].endMs, dayEnd) - Math.max(list[i].startMs, dayStart))
  return total
}

// The track a stop just finished: the newest one that ended after `sinceMs`.
function newestTrackSince(tracks, sinceMs) {
  var best = null
  var list = Array.isArray(tracks) ? tracks : []
  for (var i = 0; i < list.length; i++)
    if (list[i].endMs >= sinceMs && (!best || list[i].endMs > best.endMs)) best = list[i]
  return best
}

// ---------------------------------------------------------------------------
// Repeats, for hey-cli 1.3.x
// ---------------------------------------------------------------------------

// `hey event list` answers with each series once, on the day it began, and
// with only the name of its schedule. These are HEY's presets, which is
// what its own form creates. A custom schedule ("rrule") is opaque except
// for its description; the common yearly one is recognised from that, and
// anything else shows on its first day only.
var repeatSteps = {
  "every_day": { days: 1 },
  "every_weekday": { days: 1, weekdays: true },
  "every_week": { days: 7 },
  "every_other_week": { days: 14 },
  "every_day_of_month": { months: 1 },
  "every_year": { months: 12 }
}

var MONTH_NAMES = ["january", "february", "march", "april", "may", "june", "july",
  "august", "september", "october", "november", "december"]

function repeatStep(event) {
  if (repeatSteps[event.repeatKind]) return repeatSteps[event.repeatKind]
  if (event.repeatKind === "rrule" && /^yearly on the \d+\w* day of the month in \w+$/i.test(event.repeatDescription))
    return repeatSteps.every_year
  return null
}

// "every week until September  3, 2026" → "2026-09-03".
function repeatUntil(description) {
  var match = /until\s+([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})/.exec(String(description || ""))
  if (!match) return ""
  var month = MONTH_NAMES.indexOf(match[1].toLowerCase())
  if (month === -1) return ""
  return dateKey(parseInt(match[3], 10), month, parseInt(match[2], 10))
}

// "every day 5 times" → 5.
function repeatTimes(description) {
  var match = /(\d+)\s+times/.exec(String(description || ""))
  return match ? parseInt(match[1], 10) : 0
}

// The n-th occurrence's local start date, or null when that month or year
// has no such day (the 31st, or February 29th), which HEY skips.
function occurrenceDate(start, step, n) {
  var date
  if (step.months) {
    date = new Date(start.getFullYear(), start.getMonth() + step.months * n, start.getDate(),
      start.getHours(), start.getMinutes(), start.getSeconds())
    return date.getDate() === start.getDate() ? date : null
  }
  date = new Date(start.getFullYear(), start.getMonth(), start.getDate() + step.days * n,
    start.getHours(), start.getMinutes(), start.getSeconds())
  return date
}

function shiftEvent(event, startDate, firstDayKey) {
  var copy = {}
  for (var field in event) copy[field] = event[field]
  if (event.allDay) {
    // Floating dates: moved as text, never through a timezone.
    var span = daysBetween(String(event.startsAt).substr(0, 10), String(event.endsAt).substr(0, 10))
    var newKey = keyForDate(startDate)
    copy.startsAt = newKey + "T00:00:00Z"
    copy.endsAt = addDays(newKey, Math.max(0, span)) + "T00:00:00Z"
  } else {
    var length = (event.endMs || event.startMs) - event.startMs
    copy.startMs = startDate.getTime()
    copy.endMs = copy.startMs + length
    copy.startsAt = new Date(copy.startMs).toISOString()
    copy.endsAt = new Date(copy.endMs).toISOString()
  }
  copy.recurring = true
  copy.key = event.seriesId + "@" + copy.startsAt
  return copy
}

// A series' occurrences that touch firstKey..lastKey. Occurrences are
// counted from the series' first day so "5 times" stops where HEY stops;
// the count is jumped ahead where the step allows, so a daily series from
// 1987 does not walk every day since.
function expandRecurring(event, firstKey, lastKey) {
  var step = repeatStep(event)
  if (!step) return [event]

  var allDay = event.allDay
  var start = allDay ? dateFromKey(String(event.startsAt).substr(0, 10)) : new Date(event.startMs)
  var firstKeyOfSeries = keyForDate(start)
  var until = repeatUntil(event.repeatDescription)
  var times = repeatTimes(event.repeatDescription)
  // The longest an occurrence can run back into the range from before it.
  var lookBack = Math.max(0, eventDayKeys(event).length)
  var from = addDays(firstKey, -lookBack)

  var n = 0
  if (!step.weekdays && !times) {
    var gap = daysBetween(firstKeyOfSeries, from)
    if (step.days && gap > 0) n = Math.floor(gap / step.days)
    else if (step.months && gap > 0) n = Math.max(0, Math.floor(gap / (31 * step.months)))
  }

  var out = []
  var counted = n
  for (var guard = 0; guard < 5000; guard++, n++) {
    var date = occurrenceDate(start, step, n)
    if (date === null) continue
    var key = keyForDate(date)
    if (key > lastKey) break
    if (until !== "" && key > until) break
    if (step.weekdays && (date.getDay() === 0 || date.getDay() === 6)) continue
    counted++
    if (times && counted > times) break
    var occurrence = n === 0 ? event : shiftEvent(event, date, firstKey)
    var days = eventDayKeys(occurrence)
    if (days.length > 0 && days[days.length - 1] >= firstKey && days[0] <= lastKey) out.push(occurrence)
  }
  return out
}

function expandAll(events, firstKey, lastKey) {
  var out = []
  for (var i = 0; i < events.length && out.length < maximumEventCount; i++) {
    var expanded = events[i].repeatKind !== "" ? expandRecurring(events[i], firstKey, lastKey) : [events[i]]
    for (var j = 0; j < expanded.length; j++) {
      var days = eventDayKeys(expanded[j])
      // `hey event list` is generous about its window; anything that does
      // not actually touch the span is dropped here.
      if (days.length > 0 && days[days.length - 1] >= firstKey && days[0] <= lastKey) out.push(expanded[j])
    }
  }
  return out
}

// Files each event under every HEY week it touches, the way `hey event
// week` would have answered.
function bucketByWeek(events, weekKeys) {
  var buckets = {}
  for (var w = 0; w < weekKeys.length; w++) buckets[weekKeys[w]] = []
  for (var i = 0; i < events.length; i++) {
    var days = eventDayKeys(events[i])
    var filed = {}
    for (var d = 0; d < days.length; d++) {
      var week = weekStartKey(days[d])
      if (buckets[week] && !filed[week]) {
        buckets[week].push(events[i])
        filed[week] = true
      }
    }
  }
  return buckets
}

// Merges the per-week lists into one, dropping the copies a multi-day event
// leaves in every week it crosses.
function mergeWeeks(cache) {
  var seen = {}
  var out = []
  var map = cache || {}
  var keys = Object.keys(map).sort()
  for (var i = 0; i < keys.length; i++) {
    var entry = map[keys[i]]
    var events = entry && Array.isArray(entry.events) ? entry.events : []
    for (var j = 0; j < events.length; j++) {
      if (seen[events[j].key]) continue
      seen[events[j].key] = true
      out.push(events[j])
    }
  }
  return out
}

// Calendars named in the `hiddenCalendars` setting are left out. On hey-cli
// 1.4.0 and newer HEY already leaves out the calendars switched off in its
// own app; 1.3.x cannot tell, so this is how to hide one there.
function parseHiddenCalendars(value) {
  var list = Array.isArray(value) ? value : String(value || "").split(",")
  var out = []
  for (var i = 0; i < list.length; i++) {
    var name = String(list[i] || "").replace(/^\s+|\s+$/g, "").toLowerCase()
    if (name !== "" && out.indexOf(name) === -1) out.push(name)
  }
  return out
}

function withoutHidden(events, hidden) {
  var names = Array.isArray(hidden) ? hidden : []
  if (names.length === 0) return events
  var out = []
  for (var i = 0; i < events.length; i++)
    if (names.indexOf(String(events[i].calendar).toLowerCase()) === -1) out.push(events[i])
  return out
}

// ---------------------------------------------------------------------------
// Days
// ---------------------------------------------------------------------------

function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

function dateKey(year, month, day) {
  return year + "-" + pad2(Number(month) + 1) + "-" + pad2(day)
}

function keyForDate(date) {
  return dateKey(date.getFullYear(), date.getMonth(), date.getDate())
}

function dateFromKey(key) {
  var parts = String(key || "").split("-")
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]))
}

function addDays(key, delta) {
  var date = dateFromKey(key)
  date.setDate(date.getDate() + delta)
  return keyForDate(date)
}

function daysBetween(fromKey, toKey) {
  var a = dateFromKey(fromKey)
  var b = dateFromKey(toKey)
  return Math.round((Date.UTC(b.getFullYear(), b.getMonth(), b.getDate())
    - Date.UTC(a.getFullYear(), a.getMonth(), a.getDate())) / MS_PER_DAY)
}

// HEY's weeks run Monday to Sunday, and `hey event week` answers that span
// whatever day it is given, so a Monday is the canonical name for a week.
function weekStartKey(dayKey) {
  var date = dateFromKey(dayKey)
  var weekday = (date.getDay() + 6) % 7
  return addDays(dayKey, -weekday)
}

// Every HEY week touching the span, first to last inclusive.
function weekKeysBetween(firstKey, lastKey) {
  var keys = []
  if (!isDayKey(firstKey) || !isDayKey(lastKey) || lastKey < firstKey) return keys
  var cursor = weekStartKey(firstKey)
  while (cursor <= lastKey && keys.length < 12) {
    keys.push(cursor)
    cursor = addDays(cursor, 7)
  }
  return keys
}

// The days an event occupies, in local terms.
//
// A timed event is an instant, so its days are whatever days that span
// covers here: an 8pm UTC start is tomorrow in Tokyo and today in New York,
// and both are right. One that ends exactly at midnight does not spill onto
// the next day, which it only touches.
//
// An all-day event is not an instant at all: HEY stores it as a midnight-UTC
// pair, and reading that as a moment would slide it onto yesterday for
// everyone west of Greenwich. So its dates are read off the text, never
// converted. Multi-day ones end exclusively (a three-day trip is the 13th to
// the 16th) while a single-day one repeats its own date.
function eventDayKeys(event) {
  if (!event) return []
  var keys = []
  var cursor
  var endKey

  if (!event.allDay) {
    if (event.startMs === null) return []
    var startKey = keyForDate(new Date(event.startMs))
    var endMs = event.endMs === null || event.endMs < event.startMs ? event.startMs : event.endMs
    var end = new Date(endMs)
    endKey = keyForDate(end)
    if (endMs > event.startMs && end.getHours() === 0 && end.getMinutes() === 0 && endKey > startKey)
      endKey = addDays(endKey, -1)
    cursor = startKey
    // Bounded so a corrupt or absurd end cannot spin here.
    while (cursor <= endKey && keys.length < 90) {
      keys.push(cursor)
      cursor = addDays(cursor, 1)
    }
    return keys
  }

  var first = String(event.startsAt).substr(0, 10)
  endKey = String(event.endsAt).substr(0, 10)
  if (!isDayKey(first)) return []
  if (!isDayKey(endKey) || endKey <= first) return [first]
  cursor = first
  while (cursor < endKey && keys.length < 90) {
    keys.push(cursor)
    cursor = addDays(cursor, 1)
  }
  return keys.length > 0 ? keys : [first]
}

// All-day events first, then by start, then by title, so two events at the
// same minute keep their order between refreshes.
function compareEvents(a, b) {
  if (a.allDay !== b.allDay) return a.allDay ? -1 : 1
  if (!a.allDay) {
    var delta = (a.startMs || 0) - (b.startMs || 0)
    if (delta !== 0) return delta
  }
  return a.title < b.title ? -1 : (a.title > b.title ? 1 : 0)
}

// Day key → that day's events, sorted. Built once per refresh so the month
// grid and the day view read the same answer without walking the list again.
function indexByDay(events) {
  var index = {}
  var list = Array.isArray(events) ? events : []
  for (var i = 0; i < list.length; i++) {
    var keys = eventDayKeys(list[i])
    for (var k = 0; k < keys.length; k++) {
      if (!index[keys[k]]) index[keys[k]] = []
      index[keys[k]].push(list[i])
    }
  }
  for (var key in index) index[key].sort(compareEvents)
  return index
}

function eventsForDay(events, dayKey) {
  return indexByDay(events)[String(dayKey || "")] || []
}

// A multi-day event seen from one of its days: does it begin here, carry on
// from yesterday, or run into tomorrow? The day view says so instead of
// pretending a flight that left last night takes off again this morning.
function spanPosition(event, dayKey) {
  var keys = eventDayKeys(event)
  if (keys.length <= 1) return "single"
  if (keys[0] === dayKey) return "first"
  if (keys[keys.length - 1] === dayKey) return "last"
  return "middle"
}

// The grid's per-day chips: one per calendar color, carrying how many of the
// day's events wear it. Grouped by color rather than by calendar, because a
// chip is only ever read as a color, and two blue calendars as two blue
// chips would look like a rendering bug. Ordered by the day's first event in
// each color, so the chips read in the same order as the day itself.
//
// Past `limit` colors, the last chip becomes "+N" for everything left over.
function dayChips(dayEvents, limit) {
  var max = Math.max(1, Number(limit) || 3)
  var groups = []
  var byColor = {}
  var list = Array.isArray(dayEvents) ? dayEvents : []
  for (var i = 0; i < list.length; i++) {
    var color = list[i].color || ""
    if (!(color in byColor)) {
      byColor[color] = groups.length
      groups.push({ color: color, count: 0, calendars: [] })
    }
    var group = groups[byColor[color]]
    group.count++
    if (group.calendars.indexOf(list[i].calendar) === -1) group.calendars.push(list[i].calendar)
  }
  if (groups.length <= max) return groups

  var kept = groups.slice(0, max - 1)
  var rest = 0
  for (var j = max - 1; j < groups.length; j++) rest += groups[j].count
  kept.push({ color: "", count: rest, calendars: [], overflow: true })
  return kept
}

// ---------------------------------------------------------------------------
// Now
// ---------------------------------------------------------------------------

function hasEnded(event, nowMs) {
  if (!event || event.allDay) return false
  var end = event.endMs === null ? event.startMs : event.endMs
  return end !== null && end <= nowMs
}

function isNow(event, nowMs) {
  if (!event || event.allDay || event.startMs === null) return false
  var end = event.endMs === null ? event.startMs : event.endMs
  return event.startMs <= nowMs && nowMs < end
}

function isDeclined(event) {
  return !!event && String(event.status) === "declined"
}

// The thing you are in, or the thing you are about to be in. An all-day
// event only when nothing timed is left, so a birthday does not sit in the
// tooltip over a standup in ten minutes.
function currentOrNextEvent(events, nowMs) {
  var list = Array.isArray(events) ? events : []
  var upcoming = null
  var allDay = null
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (isDeclined(event)) continue
    if (event.allDay) {
      if (!allDay) allDay = event
      continue
    }
    if (isNow(event, nowMs)) return event
    if (event.startMs !== null && event.startMs > nowMs) {
      if (!upcoming || event.startMs < upcoming.startMs) upcoming = event
    }
  }
  return upcoming || allDay
}

var defaultAlertLeadMinutes = 15

function normalizedAlertLead(value) {
  var minutes = Math.round(Number(value))
  if (!isFinite(minutes) || minutes < 0) return defaultAlertLeadMinutes
  return Math.min(240, minutes)
}

// The event the bar's calendar glyph is warning about, or null. One under
// way still counts: an indicator that goes dark the moment the meeting
// starts tells you the opposite of what you need. All-day events never
// count; a birthday is not something you are late for.
function imminentEvent(events, nowMs, leadMinutes) {
  var lead = normalizedAlertLead(leadMinutes)
  if (lead <= 0) return null
  var horizon = nowMs + lead * 60000
  var list = Array.isArray(events) ? events : []
  var soonest = null
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (event.allDay || event.startMs === null || isDeclined(event)) continue
    if (isNow(event, nowMs)) return event
    if (event.startMs > nowMs && event.startMs <= horizon) {
      if (!soonest || event.startMs < soonest.startMs) soonest = event
    }
  }
  return soonest
}

// What the bar says about an event, after its title: "in 12m" while it is
// coming, "until 14:30" once it has started, "at 16:30" when it is further
// off, nothing for an all-day event.
// Further off it names the day: "tomorrow 09:00", "wed 09:00", "3 oct".
function barWhen(event, nowMs, hour24) {
  if (!event) return ""
  var todayKey = keyForDate(new Date(nowMs))
  if (event.allDay || event.startMs === null) {
    var first = String(event.startsAt).substr(0, 10)
    if (first <= todayKey) return "today"
    return dayWord(first, todayKey)
  }
  if (isNow(event, nowMs)) return event.endMs !== null ? "until " + formatTime(new Date(event.endMs), hour24) : "now"
  var minutes = Math.max(0, Math.round((event.startMs - nowMs) / 60000))
  if (minutes === 0) return "now"
  if (minutes < 60) return "in " + minutes + "m"
  var startKey = keyForDate(new Date(event.startMs))
  var time = formatTime(new Date(event.startMs), hour24)
  if (startKey === todayKey) return "at " + time
  var days = daysBetween(todayKey, startKey)
  return days < 7 ? dayWord(startKey, todayKey) + " " + time : dayWord(startKey, todayKey)
}

var SHORT_WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
var SHORT_MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

function dayWord(key, todayKey) {
  var days = daysBetween(todayKey, key)
  if (days === 1) return "tomorrow"
  var date = dateFromKey(key)
  if (days > 1 && days < 7) return SHORT_WEEKDAYS[date.getDay()]
  return date.getDate() + " " + SHORT_MONTHS[date.getMonth()]
}

var barTitleLimit = 28

function barEventLabel(event, nowMs, hour24, titleOnly) {
  if (!event) return ""
  var title = String(event.title || "")
  if (title.length > barTitleLimit) title = title.substr(0, barTitleLimit - 1).replace(/\s+$/, "") + "…"
  if (titleOnly) return title
  var when = barWhen(event, nowMs, hour24)
  return when === "" ? title : title + " · " + when
}

// When the bar starts naming an event: at its earliest HEY reminder, so an
// event you asked to hear about a day ahead is in the bar a day ahead. One
// without reminders uses the lead time; an all-day one without reminders
// is never named, the way a birthday nobody set an alert for stays quiet.
function barWindowStart(event, leadMinutes) {
  var start = event.allDay ? dateFromKey(String(event.startsAt).substr(0, 10)).getTime() : event.startMs
  if (start === null) return null
  var earliest = null
  var reminders = event.reminders || []
  for (var i = 0; i < reminders.length; i++)
    if (reminders[i] <= start && (earliest === null || reminders[i] < earliest)) earliest = reminders[i]
  if (earliest !== null) return earliest
  if (event.allDay) return null
  var lead = normalizedAlertLead(leadMinutes)
  return lead > 0 ? start - lead * 60000 : null
}

// Where an event stops being named: its end, or the end of an all-day
// event's last day.
function barWindowEnd(event) {
  if (!event.allDay) return event.endMs === null ? event.startMs : event.endMs
  var days = eventDayKeys(event)
  return days.length === 0 ? null : dateFromKey(addDays(days[days.length - 1], 1)).getTime()
}

// Every event whose bar window is open now, most deserving first:
//   1. about to start (within the lead time), soonest first: you need to
//      move, whatever else is going on;
//   2. under way, the one ending soonest first;
//   3. coming, inside its reminder window, soonest first;
//   4. all-day ones.
function barEvents(events, nowMs, leadMinutes) {
  var lead = normalizedAlertLead(leadMinutes) * 60000
  var list = Array.isArray(events) ? events : []
  var open = []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (isDeclined(event)) continue
    var from = barWindowStart(event, leadMinutes)
    var until = barWindowEnd(event)
    if (from === null || until === null || nowMs < from || nowMs >= until) continue
    var rank
    var order
    if (event.allDay) { rank = 4; order = from }
    else if (isNow(event, nowMs)) { rank = 2; order = until }
    else if (event.startMs - nowMs <= lead) { rank = 1; order = event.startMs }
    else { rank = 3; order = event.startMs }
    open.push({ event: event, rank: rank, order: order })
  }
  open.sort(function(a, b) { return a.rank - b.rank || a.order - b.order || compareEvents(a.event, b.event) })
  return open.map(function(o) { return o.event })
}

// Which events the bar names, by the `barEvent` setting: "soon" (the
// default) those inside their alert windows, "name" and "time" the same
// with only their titles or only when, "next" the next one left today all
// day, "off" none.
function barSelection(mode, events, todayEvents, nowMs, leadMinutes) {
  if (mode === "off") return []
  if (mode === "next") {
    var open = barEvents(events, nowMs, leadMinutes)
    if (open.length > 0) return open
    var next = currentOrNextEvent(todayEvents, nowMs)
    return next ? [next] : []
  }
  return barEvents(events, nowMs, leadMinutes)
}

// The first event and how many more: "Podcast · in 12m  +1". The `style`
// is the barEvent mode: "time" says only when ("in 12m  +1"), "name" only
// what ("Podcast  +1"), anything else both.
function barLabel(selection, nowMs, hour24, style) {
  if (!selection || selection.length === 0) return ""
  var label
  if (style === "time") label = barWhen(selection[0], nowMs, hour24) || "today"
  else if (style === "name") label = barEventLabel(selection[0], nowMs, hour24, true)
  else label = barEventLabel(selection[0], nowMs, hour24)
  return selection.length > 1 ? label + "  +" + (selection.length - 1) : label
}

function minutesUntil(event, nowMs) {
  if (!event || event.allDay || event.startMs === null) return 0
  return Math.round((event.startMs - nowMs) / 60000)
}

function normalizedRefreshInterval(value) {
  var seconds = Math.round(Number(value))
  if (!isFinite(seconds) || seconds < 30) return 300
  return Math.min(3600, seconds)
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

// A reminder older than this when first seen is history, not news: the shell
// was off, or asleep, when it came due.
var reminderGraceMs = 10 * 60000

function reminderKey(event, remindMs) {
  return event.key + "#" + remindMs
}

// The reminders that have come due since the last look and not been shown.
// `sinceMs` is the floor: nothing that came due before the plugin started
// is replayed, so restarting the shell does not re-announce the afternoon.
function dueReminders(events, nowMs, sinceMs, shown) {
  var out = []
  var seen = shown || {}
  var floor = Math.max(Number(sinceMs) || 0, nowMs - reminderGraceMs)
  var list = Array.isArray(events) ? events : []
  for (var i = 0; i < list.length; i++) {
    var event = list[i]
    if (isDeclined(event)) continue
    var reminders = event.reminders || []
    for (var r = 0; r < reminders.length; r++) {
      var at = reminders[r]
      if (at > nowMs || at < floor) continue
      if (seen[reminderKey(event, at)]) continue
      out.push({ event: event, remindMs: at, key: reminderKey(event, at) })
    }
  }
  out.sort(function(a, b) { return a.remindMs - b.remindMs })
  return out
}

// "In 30 minutes", "Now", "Tomorrow": what a notification leads with.
function reminderLead(event, nowMs) {
  if (!event) return ""
  if (event.allDay) {
    var days = daysBetween(keyForDate(new Date(nowMs)), String(event.startsAt).substr(0, 10))
    if (days <= 0) return "Today"
    if (days === 1) return "Tomorrow"
    return "In " + days + " days"
  }
  var minutes = Math.round((event.startMs - nowMs) / 60000)
  if (minutes <= 0) return "Now"
  if (minutes < 60) return "In " + minutes + " min"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours < 24) return "In " + hours + " h" + (rest > 0 ? " " + rest + " min" : "")
  var d = Math.round(hours / 24)
  return d === 1 ? "Tomorrow" : "In " + d + " days"
}

function notificationBody(event, nowMs, hour24) {
  var lines = [reminderLead(event, nowMs) + " · " + eventRangeLabel(event, hour24)]
  if (event.calendar !== "") lines.push(event.calendar)
  if (event.location !== "") lines.push(event.location)
  return lines.join("\n")
}

// The notification, and what to open if it is clicked. notify-send waits for
// the answer, which is why this runs detached. The text and the link are
// arguments, never interpolated.
var notifyScript = [
  "choice=$(notify-send --app-name='HEY Calendar' --icon=x-office-calendar"
    + " --action=default=Open \"$1\" \"$2\" 2>/dev/null)",
  "if [ \"$choice\" = default ] && [ -n \"$3\" ]; then xdg-open \"$3\" >/dev/null 2>&1; fi"
].join("\n")

function notifyCommand(event, nowMs, hour24) {
  var link = event.joinUrl || event.url || dayUrl(eventDayKeys(event)[0] || "")
  return ["bash", "-c", notifyScript, "hey-calendar",
    event.title, notificationBody(event, nowMs, hour24), link]
}

// ---------------------------------------------------------------------------
// Creating events
// ---------------------------------------------------------------------------

// Loose clock input: "9", "930", "9:30", "21.30", "9pm", "9:30 am".
// Returns "HH:MM", or "" when it is not a time.
function parseClock(value) {
  var text = String(value === undefined || value === null ? "" : value)
    .toLowerCase().replace(/\s+/g, "")
  if (text === "") return ""
  var match = /^(\d{1,2})(?:[:.h]?(\d{2}))?(a|am|p|pm)?$/.exec(text)
  if (!match) return ""
  var hours = parseInt(match[1], 10)
  var minutes = match[2] ? parseInt(match[2], 10) : 0
  var suffix = match[3] || ""
  if (minutes > 59) return ""
  if (suffix !== "") {
    if (hours < 1 || hours > 12) return ""
    if (suffix.charAt(0) === "p" && hours !== 12) hours += 12
    if (suffix.charAt(0) === "a" && hours === 12) hours = 0
  }
  if (hours > 23) return ""
  return pad2(hours) + ":" + pad2(minutes)
}

var WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

function matchName(word, names, minimum) {
  if (word.length < minimum) return -1
  for (var i = 0; i < names.length; i++) if (names[i].indexOf(word) === 0) return i
  return -1
}

// Loose day input, relative to today: "today", "tomorrow", "fri" (the next
// Friday, today included), "next fri" (the one after), "in 3 days", "+3",
// "3 oct", "oct 3", "3" (the next 3rd), or "2026-10-03". Returns a day key,
// or "" when it is not a day. Blank means today.
function parseDay(value, todayKey) {
  var text = String(value === undefined || value === null ? "" : value)
    .toLowerCase().replace(/[,.]/g, " ").replace(/\s+/g, " ").replace(/^ | $/g, "")
  if (!isDayKey(todayKey)) return ""
  if (text === "" || text === "today" || text === "tod") return todayKey
  if (text === "tomorrow" || text === "tmr" || text === "tom") return addDays(todayKey, 1)
  if (text === "yesterday") return addDays(todayKey, -1)
  if (isDayKey(text)) {
    var exact = dateFromKey(text)
    return keyForDate(exact) === text ? text : ""
  }

  var match = /^(?:in )?\+?(\d{1,3}) ?(d|day|days|w|wk|week|weeks)?$/.exec(text)
  if (match && (match[2] || /^(in |\+)/.test(text))) {
    var n = parseInt(match[1], 10)
    return addDays(todayKey, /^w/.test(match[2] || "") ? n * 7 : n)
  }

  match = /^(next )?([a-z]+)$/.exec(text)
  if (match) {
    var weekday = matchName(match[2], WEEKDAYS, 2)
    if (weekday !== -1) {
      var delta = (weekday - dateFromKey(todayKey).getDay() + 7) % 7
      return addDays(todayKey, delta + (match[1] ? 7 : 0))
    }
  }

  var today = dateFromKey(todayKey)
  var day = -1
  var month = -1
  match = /^(\d{1,2})(?:st|nd|rd|th)?(?: ([a-z]+))?(?: (\d{4}))?$/.exec(text)
  if (match) {
    day = parseInt(match[1], 10)
    month = match[2] ? matchName(match[2], MONTH_NAMES, 3) : -2
    if (match[2] && month === -1) return ""
  } else {
    match = /^([a-z]+) (\d{1,2})(?:st|nd|rd|th)?(?: (\d{4}))?$/.exec(text)
    if (!match) return ""
    month = matchName(match[1], MONTH_NAMES, 3)
    day = parseInt(match[2], 10)
    if (month === -1) return ""
    match = [match[0], match[2], match[1], match[3]]
  }
  var year = match[3] ? parseInt(match[3], 10) : today.getFullYear()

  // A bare day number is the next one to come: "3" on the 28th is the 3rd
  // of next month. A day and month without a year is the next one too.
  var candidate
  if (month === -2) {
    candidate = new Date(today.getFullYear(), today.getMonth(), day)
    if (candidate.getDate() !== day || keyForDate(candidate) < todayKey)
      candidate = new Date(today.getFullYear(), today.getMonth() + 1, day)
    if (candidate.getDate() !== day) return ""
    return keyForDate(candidate)
  }
  candidate = new Date(year, month, day)
  if (candidate.getDate() !== day) return ""
  if (!match[3] && keyForDate(candidate) < todayKey) candidate = new Date(year + 1, month, day)
  return candidate.getDate() === day ? keyForDate(candidate) : ""
}

function clockMinutes(hhmm) {
  var parts = String(hhmm).split(":")
  return parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10)
}

function clockFromMinutes(total) {
  var wrapped = ((total % 1440) + 1440) % 1440
  return pad2(Math.floor(wrapped / 60)) + ":" + pad2(wrapped % 60)
}

// Up and Down in a time field: moves it by `delta` minutes, landing on the
// grid of that step ("9:07" up by 15 is 9:15, not 9:22). A blank or
// unreadable field starts from `fallback`.
function nudgeClock(text, delta, fallback) {
  var current = parseClock(text)
  if (current === "") current = parseClock(fallback)
  if (current === "") return ""
  var minutes = clockMinutes(current)
  var step = Math.abs(delta) || 15
  var snapped = delta > 0 ? Math.floor(minutes / step) * step + step : Math.ceil(minutes / step) * step - step
  return clockFromMinutes(snapped)
}

// "09:30" plus 60 is "10:30", unsnapped. "" when the time is unreadable.
function shiftClock(text, minutes) {
  var current = parseClock(text)
  return current === "" ? "" : clockFromMinutes(clockMinutes(current) + minutes)
}

// Steps through a list, wrapping at both ends. Unknown current values
// start from the first entry.
function cycle(list, current, delta) {
  if (!list || list.length === 0) return current
  var index = list.indexOf(current)
  if (index === -1) return list[0]
  return list[((index + delta) % list.length + list.length) % list.length]
}

// The next half hour from now, which is what a fresh event on today starts at.
// Other days start at nine, the way HEY's own form fills in.
function suggestedStart(dayKey, now) {
  if (dayKey !== keyForDate(now)) return "09:00"
  var minutes = now.getHours() * 60 + now.getMinutes()
  var next = Math.ceil((minutes + 1) / 30) * 30
  return next >= 1440 ? "23:30" : clockFromMinutes(next)
}

var reminderChoices = ["", "10m", "30m", "1h", "1d"]

// Checks the form and turns it into `hey event add` arguments. Returns
// { error } or { command }. Nothing here is interpolated into a shell: the
// command is an argv, so a title can hold any character it likes.
function addEventCommand(form) {
  var f = form || {}
  var title = String(f.title || "").replace(/^\s+|\s+$/g, "")
  if (title === "") return { error: "Give the event a title." }
  if (title.length > 256) return { error: "That title is too long." }
  if (!isDayKey(f.date)) return { error: "Pick a day." }

  var args = ["timeout", "-k", "3", "30", "hey", "event", "add", "--title", title, "--starts-on", f.date]

  if (f.allDay) {
    args.push("--all-day")
    if (f.endDate && f.endDate !== f.date) {
      if (!isDayKey(f.endDate) || f.endDate < f.date) return { error: "It has to end after it starts." }
      args.push("--ends-on", f.endDate)
    }
  } else {
    var start = parseClock(f.startTime)
    if (start === "") return { error: "The start time is not a time." }
    args.push("--start-time", start)
    var endText = String(f.endTime || "").replace(/\s+/g, "")
    if (endText !== "") {
      var end = parseClock(endText)
      if (end === "") return { error: "The end time is not a time." }
      // An end before the start is read as the next morning, the way you
      // mean "22:00 to 01:00".
      if (clockMinutes(end) <= clockMinutes(start)) {
        if (clockMinutes(end) === clockMinutes(start)) return { error: "It has to end after it starts." }
        args.push("--ends-on", addDays(f.date, 1))
      }
      args.push("--end-time", end)
    }
  }

  if (Number(f.calendarId) > 0) args.push("--calendar", String(Math.round(Number(f.calendarId))))

  var location = String(f.location || "").replace(/^\s+|\s+$/g, "")
  if (location !== "") args.push("--location", location.substr(0, 256))

  var remind = String(f.remind || "")
  if (remind !== "" && reminderChoices.indexOf(remind) !== -1) args.push("--remind", remind)

  args.push("--json")
  return { command: args }
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function formatTime(date, hour24) {
  if (!date) return ""
  var hours = date.getHours()
  var minutes = pad2(date.getMinutes())
  if (hour24) return pad2(hours) + ":" + minutes
  var suffix = hours < 12 ? "am" : "pm"
  var hour12 = hours % 12
  if (hour12 === 0) hour12 = 12
  return hour12 + ":" + minutes + suffix
}

function eventRangeLabel(event, hour24) {
  if (!event) return ""
  if (event.allDay) return "All day"
  if (event.startMs === null) return ""
  var start = formatTime(new Date(event.startMs), hour24)
  if (event.endMs === null || event.endMs <= event.startMs) return start
  return start + " – " + formatTime(new Date(event.endMs), hour24)
}

// What the day view prints above a title. A multi-day event names the part
// of it this day holds: "from 09:00", "until 10:00", or "all day".
function eventTimeOnDay(event, dayKey, hour24) {
  if (!event) return ""
  if (event.allDay) return ""
  switch (spanPosition(event, dayKey)) {
  case "first": return "from " + formatTime(new Date(event.startMs), hour24)
  case "last": return "until " + formatTime(new Date(event.endMs), hour24)
  case "middle": return "all day"
  default: return eventRangeLabel(event, hour24)
  }
}

function durationLabel(ms) {
  var minutes = Math.max(0, Math.floor(Number(ms) / 60000))
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours === 0) return rest + " min"
  return hours + " h" + (rest > 0 ? " " + pad2(rest) : "")
}

// "Today", "Tomorrow", "Yesterday", or how far away it is.
function relativeDayLabel(dayKey, todayKey) {
  var delta = daysBetween(todayKey, dayKey)
  if (delta === 0) return "Today"
  if (delta === 1) return "Tomorrow"
  if (delta === -1) return "Yesterday"
  if (delta > 1) return "In " + delta + " days"
  return (-delta) + " days ago"
}

// External calendars come through as the address they were subscribed from.
// The local part carries the whole distinction between one account and
// another, and fits.
function calendarLabel(name) {
  var text = String(name || "").replace(/^\s+|\s+$/g, "")
  var at = text.indexOf("@")
  if (at > 0 && text.indexOf(" ") === -1) text = text.substr(0, at)
  return text.length > 22 ? text.substr(0, 21) + "…" : text
}

function dayUrl(dayKey) {
  return isDayKey(dayKey) ? "https://app.hey.com/calendar/days/" + dayKey : "https://app.hey.com/calendar"
}

// ---------------------------------------------------------------------------
// HEY's palette
// ---------------------------------------------------------------------------

// HEY names its calendar colors rather than giving hex. These are the fills
// HEY's own dark calendar paints (blue, red, gold and teal sampled from it),
// with the rest matched in the same key: light pastels that carry dark text.
var calendarPalette = {
  "black": "#c3cad3",
  "blue": "#6baffc",
  "brown": "#dcc1a0",
  "gold": "#f6da93",
  "green": "#a9e8a0",
  "orange": "#ffc08a",
  "pink": "#ffb0d9",
  "purple": "#cdb6fb",
  "red": "#fe9a99",
  "teal": "#aefbec",
  "yellow": "#fbf09a"
}

// The ink HEY sets on those fills.
var calendarInk = "#1b2632"

// HEY's "today" marker: the warm orange blob behind the day's name.
var todayColor = "#fcb55b"

// Anything HEY adds later falls through to the caller's accent, so a
// calendar the plugin has never heard of is never invisible.
function calendarColor(name, fallback) {
  var key = String(name || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  return calendarPalette[key] || fallback
}

if (typeof module !== "undefined") {
  module.exports = {
    eventProjection: eventProjection,
    rangeCommand: rangeCommand,
    listCommand: listCommand,
    fetchCommand: fetchCommand,
    versionCommand: versionCommand,
    parseCliVersion: parseCliVersion,
    cliMode: cliMode,
    formatVersion: formatVersion,
    minimumCliVersion: minimumCliVersion,
    repeatUntil: repeatUntil,
    repeatTimes: repeatTimes,
    expandRecurring: expandRecurring,
    expandAll: expandAll,
    bucketByWeek: bucketByWeek,
    calendarsCommand: calendarsCommand,
    timeTrackCommand: timeTrackCommand,
    watchCommand: watchCommand,
    timeTracksCommand: timeTracksCommand,
    timeTrackRenameCommand: timeTrackRenameCommand,
    timeTrackDeleteCommand: timeTrackDeleteCommand,
    normalizeTimeTrack: normalizeTimeTrack,
    parseTimeTracks: parseTimeTracks,
    tracksByDay: tracksByDay,
    trackedOnDay: trackedOnDay,
    newestTrackSince: newestTrackSince,
    timeTrackStartCommand: timeTrackStartCommand,
    timeTrackStopCommand: timeTrackStopCommand,
    deleteCommand: deleteCommand,
    safeUrl: safeUrl,
    normalizeEvent: normalizeEvent,
    normalizeEvents: normalizeEvents,
    parseRangeOutput: parseRangeOutput,
    parseCalendars: parseCalendars,
    writableCalendars: writableCalendars,
    parseTimeTrack: parseTimeTrack,
    mergeWeeks: mergeWeeks,
    parseHiddenCalendars: parseHiddenCalendars,
    withoutHidden: withoutHidden,
    isDayKey: isDayKey,
    dateKey: dateKey,
    keyForDate: keyForDate,
    dateFromKey: dateFromKey,
    addDays: addDays,
    daysBetween: daysBetween,
    weekStartKey: weekStartKey,
    weekKeysBetween: weekKeysBetween,
    eventDayKeys: eventDayKeys,
    compareEvents: compareEvents,
    indexByDay: indexByDay,
    eventsForDay: eventsForDay,
    spanPosition: spanPosition,
    dayChips: dayChips,
    hasEnded: hasEnded,
    isNow: isNow,
    isDeclined: isDeclined,
    currentOrNextEvent: currentOrNextEvent,
    normalizedAlertLead: normalizedAlertLead,
    imminentEvent: imminentEvent,
    minutesUntil: minutesUntil,
    barWhen: barWhen,
    barEventLabel: barEventLabel,
    barWindowStart: barWindowStart,
    barEvents: barEvents,
    barSelection: barSelection,
    barLabel: barLabel,
    normalizedRefreshInterval: normalizedRefreshInterval,
    reminderKey: reminderKey,
    dueReminders: dueReminders,
    reminderLead: reminderLead,
    notificationBody: notificationBody,
    notifyCommand: notifyCommand,
    parseClock: parseClock,
    parseDay: parseDay,
    nudgeClock: nudgeClock,
    shiftClock: shiftClock,
    cycle: cycle,
    suggestedStart: suggestedStart,
    reminderChoices: reminderChoices,
    addEventCommand: addEventCommand,
    formatTime: formatTime,
    eventRangeLabel: eventRangeLabel,
    eventTimeOnDay: eventTimeOnDay,
    durationLabel: durationLabel,
    relativeDayLabel: relativeDayLabel,
    calendarLabel: calendarLabel,
    dayUrl: dayUrl,
    calendarPalette: calendarPalette,
    calendarInk: calendarInk,
    todayColor: todayColor,
    calendarColor: calendarColor
  }
}
