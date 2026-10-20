// HEY's own API, for the writes that carry what you typed.
//
// `hey event add --title "Dentist"` puts the title on a command line, which
// any user on the machine can read from the process list. So events are
// created and edited, and time tracks named, over HEY's API instead, from
// inside the shell: hey-cli hands over its access token on stdout, the
// request is built here, and the shell sends it over HTTPS. Reads, the live
// watch and the writes that carry only ids stay with hey-cli (Hey.js).
//
// HEY's event update replaces rather than patches: an update without the
// reminders removes them, notes, place, link and attached email are one set
// replaced together, a write without a countdown deletes it, and a write to
// one day of a series without a repeat stops the series. hey-cli avoids
// that by reading the event first and sending back everything it is not
// changing, and this does the same, field for field (hey-cli's
// internal/cmd/events.go and events_occurrence.go, and the HEY SDK's
// calendar_events.go). Where hey-cli's whole-event edit drops a countdown,
// this reads it back as hey-cli's one-day edit does, and refuses rather than
// drops one it cannot read.
//
// It is a plan, not a client: `step` says what to read next, which zone
// files it needs, or the write to send, and the shell does the sending
// (ApiWriter.qml). Qt-free, so the tests run it against a pretend HEY.

var Zones = typeof require === "function" ? require("../TimeZones.js") : null

// QML cannot require: ApiWriter.qml hands the zone library in.
function useZones(library) {
  Zones = library
}

var responseByteLimit = 4 * 1024 * 1024
var requestTimeoutMs = 20000

// ---------------------------------------------------------------------------
// The token and where to send it
// ---------------------------------------------------------------------------

// Prints the API's base URL (hey-cli's own setting, so HEY_BASE_URL and its
// config are respected) on the first line, then hey-cli's access token. Run
// with "refresh" after HEY refused the token: hey-cli renews it first.
// The token goes from hey-cli's stdout to Calendar for Omarchy's, never through an
// argument, a variable that is exported, a file or a log.
var sessionScript = [
  "if [ \"$1\" = refresh ]; then timeout -k 3 20 hey auth refresh >/dev/null 2>&1; fi",
  "base=$(timeout -k 3 10 hey config show --json 2>/dev/null"
    + " | jq -r '[.data[]? | select(.key == \"base_url\") | .value][0] // \"\"' 2>/dev/null | head -c 2048)",
  "printf '%s\\n' \"$base\"",
  "timeout -k 3 20 hey auth token 2>/dev/null | head -c 16384"
].join("\n")

function sessionCommand(refresh) {
  return ["bash", "-c", sessionScript, "omacal"].concat(refresh ? ["refresh"] : [])
}

// The session script's output as { baseUrl, token } or { error }. HTTPS
// only, but for a server on this machine, as hey-cli allows.
function parseSession(output) {
  var text = String(output || "")
  var newline = text.indexOf("\n")
  if (newline === -1) return { error: "hey-cli did not answer. Is it installed and signed in (`hey setup`)?" }
  var base = text.substring(0, newline).replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
  if (base === "") base = "https://app.hey.com"
  var local = /^http:\/\/(localhost|127\.0\.0\.1|\[::1\]|[A-Za-z0-9.-]+\.localhost)(:\d+)?$/.test(base)
  if (!local && !/^https:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(base))
    return { error: "hey-cli's server is not an HTTPS address, so Calendar for Omarchy will not send your calendar there." }
  var token = text.substring(newline + 1).replace(/^\s+|\s+$/g, "")
  if (token === "" || !/^[\x21-\x7e]+$/.test(token))
    return { error: "hey-cli did not hand over a HEY sign-in. Run `hey auth login`." }
  return { baseUrl: base, token: token }
}

// ---------------------------------------------------------------------------
// Form encoding, as Go's url.Values.Encode: keys sorted, values kept in
// order, everything but letters, digits and -_.~ escaped, spaces as +.
// ---------------------------------------------------------------------------

function escapeComponent(value) {
  var text = String(value)
  var encoded
  try {
    encoded = encodeURIComponent(text)
  } catch (e) {
    // A lone surrogate cannot be UTF-8; HEY gets the replacement character.
    encoded = encodeURIComponent(text.replace(/[\ud800-\udbff](?![\udc00-\udfff])|(^|[^\ud800-\udbff])[\udc00-\udfff]/g,
      function(match, before) { return (before || "") + "�" }))
  }
  return encoded.replace(/[!'()*]/g, function(c) {
    return "%" + c.charCodeAt(0).toString(16).toUpperCase()
  }).replace(/%20/g, "+")
}

// `pairs` is [[key, value], ...]; a key may repeat.
function formEncode(pairs) {
  var keys = []
  var byKey = {}
  for (var i = 0; i < pairs.length; i++) {
    var key = pairs[i][0]
    if (!byKey.hasOwnProperty(key)) {
      byKey[key] = []
      keys.push(key)
    }
    byKey[key].push(pairs[i][1])
  }
  keys.sort()
  var out = []
  for (i = 0; i < keys.length; i++)
    for (var j = 0; j < byKey[keys[i]].length; j++)
      out.push(escapeComponent(keys[i]) + "=" + escapeComponent(byKey[keys[i]][j]))
  return out.join("&")
}

// A form being built: set replaces, add appends, as url.Values does.
function newForm() {
  var pairs = []
  return {
    set: function(key, value) {
      pairs = pairs.filter(function(pair) { return pair[0] !== key })
      pairs.push([key, String(value)])
    },
    add: function(key, value) { pairs.push([key, String(value)]) },
    pairs: function() { return pairs.slice() }
  }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

// Thrown to ask the shell for something before the plan can go on.
function Need(what) {
  this.need = what
}

// Thrown to stop with a message for the form.
function Refusal(message) {
  this.message = message
}

function refuse(message) {
  throw new Refusal(message)
}

function isDayKey(value) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(value || ""))
}

function isClock(value) {
  var match = /^(\d{2}):(\d{2})$/.exec(String(value || ""))
  return !!match && Number(match[1]) < 24 && Number(match[2]) < 60
}

function addDays(key, delta) {
  var parts = String(key).split("-")
  var date = new Date(Date.UTC(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) + delta))
  return date.toISOString().substring(0, 10)
}

function addYears(key, delta) {
  var parts = String(key).split("-")
  var date = new Date(Date.UTC(Number(parts[0]) + delta, Number(parts[1]) - 1, Number(parts[2])))
  return date.toISOString().substring(0, 10)
}

// An instant HEY served ("2026-10-15T08:00:00Z") in milliseconds, or null.
function instant(value) {
  if (typeof value !== "string" || value === "") return null
  var ms = Date.parse(value)
  return isNaN(ms) ? null : ms
}

function utcDay(ms) {
  return new Date(ms).toISOString().substring(0, 10)
}

function idOf(value) {
  var text = String(value === undefined || value === null ? "" : value)
  return /^[1-9]\d{0,17}$/.test(text) ? text : ""
}

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// "10m", "1h", "1d" as seconds, as hey-cli reads --remind; 0 when not one.
function noticeSeconds(notice) {
  var match = /^(\d+)([smhd])$/.exec(String(notice || ""))
  if (!match || Number(match[1]) <= 0) return 0
  return Number(match[1]) * { s: 1, m: 60, h: 3600, d: 86400 }[match[2]]
}

// ---------------------------------------------------------------------------
// Reading what HEY holds
// ---------------------------------------------------------------------------

// The answer the shell put away for a GET, asking for it when it has not.
// An answer is { status, json, next } (next: the page after, from Link).
function read(state, key, path) {
  var answer = state.answers ? state.answers[key] : undefined
  if (answer === undefined) throw new Need({ read: { key: key, path: path } })
  return answer
}

function readOk(state, key, path) {
  var answer = read(state, key, path)
  if (answer.status < 200 || answer.status >= 300 || answer.json === null || typeof answer.json !== "object")
    refuse(failure(answer.status, answer.json, "read"))
  return answer.json
}

// A zone by name, loaded from its file by the shell. "" is UTC.
function zone(state, name) {
  if (name === "" || name === "UTC") return Zones.utc
  if (!Zones.isZoneName(name)) return null
  var loaded = state.zones ? state.zones[name] : undefined
  if (loaded === undefined) throw new Need({ zones: [name] })
  return loaded
}

function calendars(state) {
  var json = readOk(state, "calendars", "/calendars.json")
  var list = Array.isArray(json.calendars) ? json.calendars : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var calendar = list[i] && list[i].calendar ? list[i].calendar : list[i]
    if (calendar && idOf(calendar.id) !== "") out.push(calendar)
  }
  return out
}

// The recordings of some types on one calendar over [from, to), every page.
// HEY groups them by type; each row is tagged with its group.
function readCalendar(state, calendarId, from, to, types) {
  var rows = []
  var page = ""
  var seen = {}
  for (;;) {
    var query = "starts_on=" + from + "&ends_on=" + to + (page !== "" ? "&page=" + encodeURIComponent(page) : "")
    var key = "recordings:" + calendarId + ":" + from + ":" + to + ":" + page
    var json = readOk(state, key, "/calendars/" + calendarId + "/recordings.json?" + query)
    var empty = true
    for (var group in json) {
      var list = Array.isArray(json[group]) ? json[group] : []
      if (list.length > 0) empty = false
      if (types.indexOf(group) === -1) continue
      for (var i = 0; i < list.length; i++) if (list[i] && typeof list[i] === "object") {
        list[i].__group = group
        rows.push(list[i])
      }
    }
    var next = text(state.answers[key].next)
    if (next === "" || empty) return rows
    if (seen[next]) refuse("HEY kept answering the same page. Try again in a moment.")
    seen[next] = true
    page = next
  }
}

var eventType = "Calendar::Event"
var countdownType = "Calendar::Countdown"

// The account's own zone, which HEY's web app reads times in.
function accountZone(state) {
  var json = readOk(state, "identity", "/identity.json")
  return text(json.time_zone)
}

// ---------------------------------------------------------------------------
// When an event happens: hey-cli's scheduleFrom and editZones
// ---------------------------------------------------------------------------

// A zone to read and write one end in: name "" with zone UTC is a zoneless
// end, written back as UTC.
function clockZone(name, z) {
  return { name: name, zone: z }
}

function loadZone(state, name, what) {
  var z = zone(state, name)
  if (z === null) refuse(what + " is in time zone " + name + ", which this machine does not know. Edit it in HEY.")
  return z
}

// The zone Calendar for Omarchy's form named, or else the account's (hey-cli's writeZone).
function writeZone(state, flags) {
  if (flags.timeZone !== undefined) {
    var z = zone(state, flags.timeZone)
    if (z === null) refuse("“" + flags.timeZone + "” is not a time zone I know.")
    return clockZone(flags.timeZone, z)
  }
  var name = accountZone(state)
  if (name === "") refuse("Your HEY account has no time zone set, so Calendar for Omarchy cannot place the times. Set one in HEY.")
  return clockZone(name, loadZone(state, name, "Your HEY account"))
}

function editZones(state, flags, event, allDay) {
  if (flags.timeZone !== undefined) {
    var start = writeZone(state, flags)
    // A different zone for the end: HEY keeps one for each.
    if (flags.endTimeZone !== undefined) {
      var endZone = zone(state, flags.endTimeZone)
      if (endZone === null) refuse("“" + flags.endTimeZone + "” is not a time zone I know.")
      return [start, clockZone(flags.endTimeZone, endZone)]
    }
    return [start, start]
  }
  if (allDay && flags.startsOn !== undefined && flags.endsOn !== undefined)
    return [clockZone("", Zones.utc), clockZone("", Zones.utc)]
  if (!event.all_day && text(event.starts_at_time_zone) !== "") {
    var stored = clockZone(event.starts_at_time_zone, loadZone(state, event.starts_at_time_zone, "The event"))
    if (text(event.ends_at_time_zone) === "") return [stored, stored]
    return [stored, clockZone(event.ends_at_time_zone, loadZone(state, event.ends_at_time_zone, "The event"))]
  }
  var retyped = flags.startsOn !== undefined || flags.endsOn !== undefined
    || flags.startTime !== undefined || flags.endTime !== undefined
  if (allDay === !!event.all_day && (allDay || !retyped))
    return [clockZone("", Zones.utc), clockZone("", Zones.utc)]
  var account = writeZone(state, flags)
  // A zoneless event stays zoneless: only what was typed is read in the
  // account's zone.
  if (!event.all_day) account = clockZone("", account.zone)
  return [account, account]
}

// When a date and clock time sent in this zone happen: as HEY places them,
// and as UTC for a zoneless end, which is sent that way.
function placed(cz, date, clock) {
  return (cz.name === "" ? Zones.utc : cz.zone).place(date, clock)
}

function eventClock(ms, z) {
  if (ms === null) return { date: "", clock: "" }
  var wall = z.wall(ms)
  return { date: wall.date, clock: wall.clock }
}

// An end with no end time runs an hour: on the given day at the start's
// clock an hour on, or an hour of real time after the start.
function defaultEnd(startsOn, startTime, endsOn, z) {
  if (endsOn !== "") {
    var minutes = (Number(startTime.substr(0, 2)) * 60 + Number(startTime.substr(3, 2)) + 60) % 1440
    return { date: endsOn, clock: (minutes < 600 ? "0" : "") + Math.floor(minutes / 60) + ":" + (minutes % 60 < 10 ? "0" : "") + (minutes % 60) }
  }
  var end = z.place(startsOn, startTime) + 3600000
  var wall = z.wall(end)
  if (z.place(wall.date, wall.clock) !== end)
    refuse("An hour after it starts falls in the hour the clocks go back. Give it an end time.")
  return { date: wall.date, clock: wall.clock }
}

function keepsItsMoment(which, had, date, clock, cz) {
  if (placed(cz, date, clock) === had) return
  if (had % 60000 !== 0)
    refuse("The event's " + which + " is not on a whole minute, and HEY takes only whole minutes. Retype its " + which + " time to save it.")
  refuse("The event's " + which + " falls in the hour the clocks repeat, and saving it would move it. Retype its " + which + " time to save it.")
}

// `flags` is what the form changed, as hey-cli's flags: startsOn, endsOn,
// startTime, endTime, timeZone, endTimeZone, allDay; undefined is not given.
function scheduleFrom(state, flags, event) {
  var allDay = !!event.all_day
  if (flags.allDay !== undefined) allDay = flags.allDay
  if (flags.startTime !== undefined || flags.endTime !== undefined) allDay = false

  var zones = editZones(state, flags, event, allDay)
  var startZone = zones[0]
  var endZone = zones[1]
  var startsAt = instant(event.starts_at)
  var endsAt = instant(event.ends_at)
  var start = eventClock(startsAt, event.all_day ? Zones.utc : startZone.zone)
  var end = eventClock(endsAt, event.all_day ? Zones.utc : endZone.zone)

  var schedule = {
    startsAt: flags.startsOn !== undefined ? flags.startsOn : start.date,
    endsAt: flags.endsOn !== undefined ? flags.endsOn : end.date,
    allDay: allDay, startTime: start.clock, endTime: end.clock,
    zone: startZone.name, endZone: endZone.name
  }
  if (!isDayKey(schedule.startsAt) || !isDayKey(schedule.endsAt)) refuse("Calendar for Omarchy could not read that event's days. Edit it in HEY.")
  if (allDay) {
    if (schedule.endsAt < schedule.startsAt) refuse("It has to end after it starts.")
    return { startsAt: schedule.startsAt, endsAt: schedule.endsAt, allDay: true, startTime: "", endTime: "", zone: "", endZone: "" }
  }

  var startTime = flags.startTime !== undefined ? flags.startTime : schedule.startTime
  var endTime = flags.endTime !== undefined ? flags.endTime : schedule.endTime
  // An all-day event made a timed one starts at HEY's default hour and runs
  // the default hour, unless told otherwise.
  if (event.all_day) {
    if (flags.startTime === undefined) startTime = "09:00"
    if (flags.endTime === undefined) endTime = ""
  }
  if (!isClock(startTime) || (endTime !== "" && !isClock(endTime))) refuse("Calendar for Omarchy could not read that event's times. Edit it in HEY.")
  schedule.startTime = startTime
  schedule.endTime = endTime
  if (endTime === "") {
    var fallback = defaultEnd(schedule.startsAt, startTime, flags.endsOn !== undefined ? schedule.endsAt : "", endZone.zone)
    schedule.endsAt = fallback.date
    schedule.endTime = fallback.clock
  }

  var startRetyped = flags.startsOn !== undefined || flags.startTime !== undefined
  var endRetyped = flags.endsOn !== undefined || flags.endTime !== undefined
  if (startZone.name === "") {
    var s = zonelessEnd(startsAt, schedule.startsAt, schedule.startTime, startZone.zone, startRetyped)
    schedule.startsAt = s.date
    schedule.startTime = s.clock
  }
  if (endZone.name === "") {
    var e = zonelessEnd(endsAt, schedule.endsAt, schedule.endTime, endZone.zone, endRetyped)
    schedule.endsAt = e.date
    schedule.endTime = e.clock
  }
  if (!event.all_day && !startRetyped && startsAt !== null)
    keepsItsMoment("start", startsAt, schedule.startsAt, schedule.startTime, startZone)
  if (!event.all_day && !endRetyped && endsAt !== null)
    keepsItsMoment("end", endsAt, schedule.endsAt, schedule.endTime, endZone)

  // An end on another clock, on the start's day, that comes before the
  // start is the next day's (a red-eye), as Calendar for Omarchy always read it.
  if (flags.endTimeZone !== undefined && flags.endsOn === flags.startsOn
      && placed(endZone, schedule.endsAt, schedule.endTime) <= placed(startZone, schedule.startsAt, schedule.startTime))
    schedule.endsAt = addDays(schedule.endsAt, 1)
  endsAfterItStarts(schedule, startZone, endZone, flags.endTimeZone !== undefined)
  return schedule
}

function zonelessEnd(had, date, clock, z, retyped) {
  if (!retyped) return eventClock(had, Zones.utc)
  return eventClock(z.place(date, clock), Zones.utc)
}

// HEY's own check: a timed event does not end before it starts, compared
// as instants, since each end can have its own zone.
function endsAfterItStarts(schedule, startZone, endZone, strictly) {
  var start = placed(startZone, schedule.startsAt, schedule.startTime)
  var end = placed(endZone, schedule.endsAt, schedule.endTime)
  if (end < start || (strictly && end === start)) refuse("It has to end after it starts.")
}

// ---------------------------------------------------------------------------
// The countdown: a recording of its own, read back as hey-cli's one-day
// edit does (countdownFromRecording)
// ---------------------------------------------------------------------------

var countdownUnits = { days: 86400, weeks: 604800, months: 2629746 }

function countdownLabelMatches(seconds, value, unit) {
  if (seconds <= 0) return false
  var candidates = [["month", countdownUnits.months], ["week", countdownUnits.weeks], ["day", countdownUnits.days]]
  for (var i = 0; i < candidates.length; i++) {
    if (seconds % candidates[i][1] <= countdownUnits.days)
      return Math.floor(seconds / candidates[i][1]) === value && candidates[i][0] === unit
  }
  return false
}

function countdownForInterval(seconds) {
  if (seconds <= 0) return null
  var unit = countdownUnits.days
  var value
  if (seconds % countdownUnits.months === 0) { unit = countdownUnits.months; value = seconds / countdownUnits.months }
  else if (seconds % countdownUnits.weeks === 0) { unit = countdownUnits.weeks; value = seconds / countdownUnits.weeks }
  else if (seconds % countdownUnits.days === 0) value = seconds / countdownUnits.days
  else return null
  if (value < 1 || value > 30) return null
  return { value: value, unit: unit }
}

// { value, unit } from the countdown recording, or a refusal: a countdown
// the write does not name is a countdown removed.
function countdownFromRecording(state, countdown, event) {
  var unreadable = "Calendar for Omarchy could not read back the event's countdown, and saving would remove it. Edit it in HEY."
  var match = /^(\d+) (day|week|month)s? before$/.exec(text(countdown.label))
  if (!match) refuse(unreadable)
  var starts = instant(countdown.starts_at)
  var ends = instant(countdown.ends_at)
  var eventStarts = instant(event.starts_at)
  if (starts === null || ends === null || eventStarts === null || ends <= starts || ends !== eventStarts) refuse(unreadable)
  if (!countdownLabelMatches(Math.round((ends - starts) / 1000), Number(match[1]), match[2])) refuse(unreadable)

  // A JSON write runs in UTC, the web form in the reader's zone, and the
  // recording does not say which: UTC, the event's zone and the account's
  // are tried, and they have to agree.
  var names = ["UTC"]
  var account = accountZone(state)
  var candidates = [text(event.starts_at_time_zone), account]
  for (var i = 0; i < candidates.length; i++)
    if (candidates[i] !== "" && names.indexOf(candidates[i]) === -1) names.push(candidates[i])
  var answer = null
  for (i = 0; i < names.length; i++) {
    var z = zone(state, names[i])
    if (z === null) refuse(unreadable)
    var beginning = z.goDate(z.wall(ends).date, "00:00")
    var candidate = countdownForInterval(Math.round((beginning - starts) / 1000))
    if (candidate === null) continue
    if (answer !== null && (candidate.value !== answer.value || candidate.unit !== answer.unit)) refuse(unreadable)
    answer = candidate
  }
  if (answer === null) refuse(unreadable)
  return answer
}

function countdownOf(rows, eventId) {
  for (var i = 0; i < rows.length; i++)
    if (rows[i].__group === countdownType && idOf(rows[i].parent_id) === eventId) return rows[i]
  return null
}

// The countdown ending where the event starts: that day, on its calendar.
function countdownEnding(state, event, calendarIds) {
  var starts = instant(event.starts_at)
  if (starts === null) return null
  var cal = event.calendar && idOf(event.calendar.id) !== "" ? [idOf(event.calendar.id)] : calendarIds
  var day = utcDay(starts)
  var rows = []
  for (var i = 0; i < cal.length; i++) rows = rows.concat(readCalendar(state, cal[i], day, addDays(day, 1), [countdownType]))
  var countdown = countdownOf(rows, idOf(event.id))
  return countdown ? countdownFromRecording(state, countdown, event) : null
}

// ---------------------------------------------------------------------------
// Building the writes: the SDK's updateEventValues and Create
// ---------------------------------------------------------------------------

function setContent(form, content) {
  form.set("calendar_event[description]", content.notes)
  form.set("calendar_event[location]", content.location)
  form.set("calendar_event[url]", content.link)
  form.set("calendar_event[entry_id]", content.entryId ? content.entryId : "")
}

function setTimeZones(form, start, end) {
  if (start === "" && end === "") {
    form.set("calendar_event[set_time_zone]", "0")
    return
  }
  if (start === "") start = end
  if (end === "") end = start
  form.set("calendar_event[set_time_zone]", "1")
  form.set("calendar_event[starts_at_time_zone_name]", start)
  form.set("calendar_event[ends_at_time_zone_name]", end)
}

function setReminders(form, allDay, reminders) {
  var key = allDay ? "all_day_reminder_durations[]" : "timed_reminder_durations[]"
  for (var i = 0; i < reminders.length; i++) form.add(key, String(Math.floor(reminders[i])))
}

function setCountdown(form, countdown) {
  if (!countdown || countdown.value <= 0) return
  form.set("countdown_interval_duration_value", String(countdown.value))
  form.set("countdown_interval_duration_unit", String(countdown.unit))
}

function setHighlighted(form, highlighted) {
  if (highlighted === undefined) return
  form.set("calendar_event[highlighted]", highlighted ? "1" : "0")
  form.set("calendar_event[highlight_id]", "")
}

// p: { title?, calendarId?, schedule, reminders, content, countdown, highlighted? }
function updateForm(p) {
  var form = newForm()
  var s = p.schedule
  if (p.title !== undefined) form.set("calendar_event[summary]", p.title)
  form.set("calendar_event[starts_at]", s.startsAt)
  form.set("calendar_event[ends_at]", s.endsAt)
  form.set("calendar_event[all_day]", s.allDay ? "1" : "0")
  if (!s.allDay) {
    form.set("calendar_event[starts_at_time]", s.startTime + ":00")
    form.set("calendar_event[ends_at_time]", s.endTime + ":00")
  }
  if (p.calendarId !== undefined) form.set("calendar_event[calendar_id]", p.calendarId)
  setContent(form, p.content)
  setHighlighted(form, p.highlighted)
  setCountdown(form, p.countdown)
  setTimeZones(form, s.zone, s.endZone)
  setReminders(form, s.allDay, p.reminders)
  return form
}

// ---------------------------------------------------------------------------
// Create
// ---------------------------------------------------------------------------

// HEY's own default when no calendar is named: the first ordinary calendar
// you own, never Maybe, the personal calendar or a subscription.
function defaultCalendarId(state) {
  var list = calendars(state)
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (c.owned && !c.personal && !c.external && c.kind === "normal") return idOf(c.id)
  }
  refuse("HEY has no calendar of yours to put the event on.")
}

// `request` is Calendar.validateEvent's.
function planCreate(state, request) {
  var r = request || {}
  var title = text(r.title)
  if (title === "" || !isDayKey(r.date)) refuse("Give the event a title and a day.")
  var calendarId = Number(r.calendarId) > 0 ? String(Math.round(Number(r.calendarId))) : defaultCalendarId(state)
  var reminders = []
  if (r.remind) {
    var seconds = noticeSeconds(r.remind)
    if (seconds === 0) refuse("Calendar for Omarchy does not know that reminder.")
    reminders.push(seconds)
  }

  var schedule
  var endDate = isDayKey(r.endDate) ? r.endDate : r.date
  if (r.allDay || !r.startTime) {
    if (endDate < r.date) refuse("It has to end after it starts.")
    schedule = { startsAt: r.date, endsAt: endDate, allDay: true, startTime: "", endTime: "", zone: "", endZone: "" }
  } else {
    var startZone = zone(state, text(r.timeZone))
    if (!r.timeZone || startZone === null) refuse("Pick a time zone for the times.")
    if (!isClock(r.startTime) || (r.endTime && !isClock(r.endTime))) refuse("The times are not times.")
    var across = !!r.endTime && !!r.endTimeZone && r.endTimeZone !== r.timeZone
    var endZone = startZone
    if (across) {
      endZone = zone(state, text(r.endTimeZone))
      if (endZone === null) refuse("“" + r.endTimeZone + "” is not a time zone I know.")
    }
    schedule = { startsAt: r.date, endsAt: endDate, allDay: false, startTime: r.startTime, endTime: text(r.endTime),
      zone: r.timeZone, endZone: across ? r.endTimeZone : r.timeZone }
    if (schedule.endTime === "") {
      var fallback = defaultEnd(r.date, r.startTime, endDate !== r.date ? endDate : "", startZone)
      schedule.endsAt = fallback.date
      schedule.endTime = fallback.clock
    } else if (across && endDate === r.date
        && endZone.place(endDate, schedule.endTime) <= startZone.place(r.date, r.startTime)) {
      // The end's day is the first on which it falls after the start.
      schedule.endsAt = addDays(r.date, 1)
    }
    endsAfterItStarts(schedule, clockZone(schedule.zone, startZone), clockZone(schedule.endZone, endZone), across)
  }

  var form = newForm()
  form.set("calendar_event[calendar_id]", calendarId)
  form.set("calendar_event[summary]", title)
  form.set("calendar_event[starts_at]", schedule.startsAt)
  form.set("calendar_event[ends_at]", schedule.endsAt)
  setContent(form, { notes: "", location: text(r.location), link: "", entryId: "" })
  if (schedule.allDay) {
    form.set("calendar_event[all_day]", "1")
    setReminders(form, true, reminders)
  } else {
    form.set("calendar_event[all_day]", "0")
    form.set("calendar_event[starts_at_time]", schedule.startTime + ":00")
    form.set("calendar_event[ends_at_time]", schedule.endTime + ":00")
    setTimeZones(form, schedule.zone, schedule.endZone)
    setReminders(form, false, reminders)
  }
  return { method: "POST", path: "/calendar/events.json", form: form.pairs(), summary: "Event created" }
}

// ---------------------------------------------------------------------------
// Edit
// ---------------------------------------------------------------------------

// What an edit writes to: an event by its id, or one day of a series.
// Mirrors how Calendar for Omarchy always named it to hey-cli.
function editTarget(request) {
  var r = request || {}
  var event = r.event || {}
  var id = idOf(event.seriesId)
  var parent = idOf(event.parentId)
  var occurrence = /^[0-9A-Za-z_-]+$/.test(text(event.occurrenceId)) ? text(event.occurrenceId) : ""
  if (!event.recurring) return id ? { id: id } : null
  if (r.scope === "one") {
    // A day HEY wrote out edits alone by its own id; any other day is the
    // series' occurrence.
    if (parent !== "" && parent !== id && id !== "") return { id: id }
    var series = parent || id
    var match = /^(\d+)_(\d{4}-\d{2}-\d{2})$/.exec(occurrence)
    if (!series || !match || match[1] !== series) return null
    return { id: series, occurrence: occurrence, date: match[2] }
  }
  return (parent || id) ? { id: parent || id } : null
}

// Calendar.editRequest's changes as the flags Calendar for Omarchy would have given
// hey-cli: only what changed.
function editFlags(changes) {
  var c = changes || {}
  var flags = {}
  if (c.title !== undefined) flags.title = text(c.title)
  if (c.location !== undefined) flags.location = text(c.location)
  if (c.calendarId) flags.calendarId = String(Math.round(Number(c.calendarId)))
  if (c.remind) {
    var seconds = noticeSeconds(c.remind)
    if (seconds === 0) refuse("Calendar for Omarchy does not know that reminder.")
    flags.reminders = [seconds]
  }
  var s = c.schedule
  if (s) {
    if (s.allDay) {
      flags.allDay = true
      if (s.dates) {
        flags.startsOn = s.date
        flags.endsOn = s.endDate
      }
    } else {
      if (s.dates) flags.startsOn = s.date
      flags.startTime = s.startTime
      flags.timeZone = s.timeZone
      var across = !!s.endTimeZone && s.endTimeZone !== s.timeZone && !!s.endTime
      if (across) {
        flags.endTimeZone = s.endTimeZone
        flags.endsOn = s.endDate || s.date
        flags.startsOn = s.date
      } else if (s.dates) {
        flags.endsOn = s.endDate
      }
      if (s.endTime) flags.endTime = s.endTime
    }
  }
  return flags
}

function remindersOf(event) {
  var out = []
  var list = Array.isArray(event.reminders) ? event.reminders : []
  for (var i = 0; i < list.length; i++) {
    var seconds = Number(list[i] && list[i].duration)
    if (seconds > 0) out.push(seconds)
  }
  return out
}

function contentOf(flags, event) {
  return {
    // HEY returns plain text but accepts HTML. Escape literal markup and
    // retain line breaks. The original formatting is unavailable on reads.
    notes: text(event.description).replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/\r?\n/g, "<br>"),
    location: flags.location !== undefined ? flags.location : text(event.location),
    link: text(event.url),
    entryId: event.attached_entry ? idOf(event.attached_entry.id) : ""
  }
}

function allCalendarIds(state, first) {
  var ids = first ? [first] : []
  var list = calendars(state)
  for (var i = 0; i < list.length; i++) if (ids.indexOf(idOf(list[i].id)) === -1) ids.push(idOf(list[i].id))
  return ids
}

// hey-cli's findEvent: a year either side of today, calendar by calendar,
// stopping at the one it is on. The calendar Calendar for Omarchy saw it on is read
// first; it is matched by id, so the order changes nothing but the cost.
function findEvent(state, id, calendarHint, dateHint) {
  var today = isDayKey(state.today) ? state.today : new Date().toISOString().substring(0, 10)
  var from = addYears(today, -1)
  var to = addYears(today, 1)
  // The UI already knows which day this event occupies. Prefer that small
  // window, including events more than a year away or in the past.
  if (isDayKey(dateHint)) {
    from = addDays(dateHint, -1)
    to = addDays(dateHint, 2)
  }
  var ids = allCalendarIds(state, calendarHint)
  for (var i = 0; i < ids.length; i++) {
    var rows = readCalendar(state, ids[i], from, to, [eventType])
    for (var j = 0; j < rows.length; j++) if (idOf(rows[j].id) === id) return rows[j]
  }
  refuse("HEY no longer has that event. Refresh and try again.")
}

function planEditEvent(state, target, flags, calendarHint, dateHint) {
  var event = findEvent(state, target.id, calendarHint, dateHint)
  var schedule = scheduleFrom(state, flags, event)
  var reminders = flags.reminders !== undefined ? flags.reminders : remindersOf(event)
  var countdown = countdownEnding(state, event, allCalendarIds(state, calendarHint))
  var title = flags.title !== undefined ? flags.title : text(event.title)
  var form = updateForm({
    title: title !== "" ? title : undefined,
    calendarId: flags.calendarId,
    schedule: schedule, reminders: reminders, content: contentOf(flags, event), countdown: countdown
  })
  return { method: "PATCH", path: "/calendar/events/" + target.id + ".json", form: form.pairs(),
    summary: "Event updated", movedTo: flags.calendarId || "" }
}

// One day of a preset series, as HEY builds it: the series with the day's
// start and end (hey-cli's virtualOccurrence and occurrenceInstants).
function virtualOccurrence(state, series, date) {
  var copy = {}
  for (var k in series) copy[k] = series[k]
  copy.id = 0
  copy.parent_id = series.id
  copy.occurrence_id = idOf(series.id) + "_" + date
  var starts = instant(series.starts_at)
  var ends = instant(series.ends_at)
  if (starts === null || ends === null) refuse("Calendar for Omarchy could not read that series' times. Edit it in HEY.")
  var duration = ends - starts
  var start
  if (series.all_day) {
    start = Date.parse(date + "T00:00:00Z")
  } else {
    var z = Zones.utc
    if (text(series.starts_at_time_zone) !== "") {
      var named = zone(state, series.starts_at_time_zone)
      if (named !== null) z = named
    }
    var wall = z.wall(starts)
    var clock = wall.clock + ":" + (wall.second < 10 ? "0" : "") + wall.second
    start = z.place(date, clock)
    var deltas = [0, -1, 1]
    for (var i = 0; i < deltas.length; i++) {
      var candidate = z.place(addDays(date, deltas[i]), clock)
      if (utcDay(candidate) === date) { start = candidate; break }
    }
  }
  copy.starts_at = new Date(start).toISOString()
  copy.ends_at = new Date(start + duration).toISOString()
  return copy
}

// A day of a custom schedule, exactly as HEY's Day view serves it.
function customVirtualOccurrence(state, occurrence, date) {
  var deltas = [0, -1, 1]
  for (var i = 0; i < deltas.length; i++) {
    var day = addDays(date, deltas[i])
    var answer = read(state, "day:" + day, "/calendar/days/" + day + ".json")
    if (answer.status === 404) continue
    if (answer.status < 200 || answer.status >= 300 || !answer.json) refuse(failure(answer.status, answer.json, "read"))
    var groups = answer.json.recordings || {}
    var list = Array.isArray(groups[eventType]) ? groups[eventType] : []
    for (var j = 0; j < list.length; j++) if (list[j] && list[j].occurrence_id === occurrence) return list[j]
  }
  refuse("HEY did not serve that day of the series. Refresh and try again.")
}

// hey-cli's editOccurrence with --apply-to current.
function planEditOccurrence(state, target, flags) {
  var ids = allCalendarIds(state, "")
  var rows = []
  for (var i = 0; i < ids.length; i++)
    rows = rows.concat(readCalendar(state, ids[i], target.date, addDays(target.date, 1), [eventType, countdownType]))
  var series = null
  var realized = null
  var countdowns = []
  for (i = 0; i < rows.length; i++) {
    var row = rows[i]
    if (row.__group === countdownType) countdowns.push(row)
    else if (idOf(row.id) === target.id) series = row
    else if (row.occurrence_id === target.occurrence) realized = row
  }
  if (series === null) refuse("HEY no longer has that day of the series. Refresh and try again.")
  if (text(series.occurrence_id) !== "" || !series.recurring) refuse("That event does not repeat any more. Refresh and try again.")

  var event = realized
  if (event === null) {
    event = series.recurrence_schedule && series.recurrence_schedule.preset
      ? virtualOccurrence(state, series, target.date)
      : customVirtualOccurrence(state, target.occurrence, target.date)
  }
  var schedule = scheduleFrom(state, flags, event)
  var reminders = flags.reminders !== undefined ? flags.reminders : remindersOf(event)

  // The day's own countdown is sent back; the series' stays inherited.
  var countdown = null
  if (realized !== null) {
    var own = countdownOf(countdowns, idOf(realized.id))
    if (own !== null) countdown = countdownFromRecording(state, own, realized)
    else if (instant(realized.starts_at) !== null && utcDay(instant(realized.starts_at)) !== target.date)
      countdown = countdownEnding(state, realized, ids)
  }

  var title = flags.title !== undefined ? flags.title : text(event.title)
  var form = updateForm({
    title: title !== "" ? title : undefined,
    calendarId: flags.calendarId,
    schedule: schedule, reminders: reminders, content: contentOf(flags, event), countdown: countdown,
    highlighted: !!event.highlighted
  })
  form.set("apply_to_future", "0")
  // Without a repeat, HEY reads a write to one day as "stop repeating".
  form.set("repeat_frequency", "custom")
  return { method: "PATCH", path: "/calendar/events/" + target.id + "/occurrences/" + target.date + ".json",
    form: form.pairs(), summary: "Occurrence updated", movedTo: flags.calendarId || "", occurrence: true }
}

// ---------------------------------------------------------------------------
// Time tracks
// ---------------------------------------------------------------------------

// HEY names a track by its category: filing one "files the track under a
// category title, which HEY creates if it has none by that title".
function planRenameTrack(id, name) {
  var trackId = idOf(id)
  var title = text(name).replace(/^\s+|\s+$/g, "").substr(0, 128)
  if (trackId === "" || title === "") refuse("Give the track a name.")
  return { method: "PUT", path: "/calendar/time_tracks/" + trackId + ".json",
    json: { calendar_time_track: { category_title: title } }, summary: "Time track updated" }
}

// ---------------------------------------------------------------------------
// The plan
// ---------------------------------------------------------------------------

// job: { kind: "create", request } | { kind: "edit", request }
//    | { kind: "renameTrack", id, name }
// state: { answers: { key: { status, json, next } }, zones: { name: zone },
//          today: "YYYY-MM-DD" }
// Answers one of { read: { key, path } }, { zones: [name] },
// { write: { method, path, headers, body, summary, ... } } or { error }.
function step(job, state) {
  try {
    var plan
    if (job.kind === "create") {
      plan = planCreate(state, job.request)
    } else if (job.kind === "edit") {
      var target = editTarget(job.request)
      if (target === null) return { error: "Calendar for Omarchy cannot name that event to HEY. Edit it there." }
      var flags = editFlags(job.request.changes)
      var event = job.request.event || {}
      var hint = idOf(event.calendarId)
      var dateHint = typeof event.startMs === "number" && isFinite(event.startMs)
        ? utcDay(event.startMs) : text(event.startsAt).substring(0, 10)
      plan = target.occurrence ? planEditOccurrence(state, target, flags) : planEditEvent(state, target, flags, hint, dateHint)
    } else if (job.kind === "renameTrack") {
      plan = planRenameTrack(job.id, job.name)
    } else {
      return { error: "Calendar for Omarchy does not know that change." }
    }
    return { write: request(plan) }
  } catch (e) {
    if (e instanceof Need) return e.need
    if (e instanceof Refusal) return { error: e.message }
    throw e
  }
}

function request(plan) {
  var write = { method: plan.method, path: plan.path, summary: plan.summary,
    movedTo: plan.movedTo || "", occurrence: !!plan.occurrence }
  if (plan.json) {
    write.headers = { "Content-Type": "application/json", "Accept": "application/json" }
    write.body = JSON.stringify(plan.json)
  } else {
    write.headers = { "Content-Type": "application/x-www-form-urlencoded", "Accept": "*/*" }
    write.body = formEncode(plan.form)
  }
  return write
}

// The headers every request carries, the token among them.
function headers(token, extra) {
  var out = { "Authorization": "Bearer " + token }
  if (extra) for (var k in extra) out[k] = extra[k]
  if (!out.Accept) out.Accept = "application/json"
  return out
}

// The cursor for the next page, from HEY's Link header.
function nextPage(link) {
  var match = /<([^>]*)>\s*;\s*rel="?next"?/.exec(String(link || ""))
  if (!match) return ""
  var page = /[?&]page=([^&#]*)/.exec(match[1])
  if (!page) return ""
  try { return decodeURIComponent(page[1].replace(/\+/g, " ")) }
  catch (e) { return "" }
}

// A GET's answer, as `step` reads it. A body over the limit, or not JSON,
// is no answer.
function answer(status, body, link) {
  var json = null
  var raw = String(body || "")
  if (raw.length > 0 && raw.length <= responseByteLimit) {
    try {
      json = JSON.parse(raw)
    } catch (e) {
      json = null
    }
  }
  return { status: Number(status) || 0, json: json, next: nextPage(link) }
}

function failure(status, json, during) {
  if (status === 0) return "Could not reach HEY. Check the connection and try again."
  if (status === 401) return "HEY did not accept Calendar for Omarchy's sign-in. Run `hey auth login`."
  if (status === 403) return "HEY does not let you change that event."
  if (status === 404) return during === "read"
    ? "HEY could not find what Calendar for Omarchy asked for. Refresh and try again."
    : "HEY no longer has that event, or does not let you change it. Refresh and try again."
  if (status === 429) return "HEY asked Calendar for Omarchy to slow down. Try again in a minute."
  var message = json && typeof json === "object" ? text(json.error || json.message) : ""
  if (message !== "" && message.length < 300) return "HEY did not accept that: " + message
  return status >= 500 ? "HEY had a problem (HTTP " + status + "). Try again in a moment."
    : "HEY did not accept that (HTTP " + status + ")."
}

// What a write's answer means for the form: { ok, message }.
function writeResult(write, status, body) {
  var code = Number(status) || 0
  if (code >= 200 && code < 300) {
    if (write.movedTo) {
      var json = answer(code, body, "").json
      var on = json && json.calendar ? idOf(json.calendar.id) : ""
      // HEY drops a calendar it will not move an event to and saves the
      // rest; saying "updated" then would be the one wrong answer.
      if (on !== "" && on !== write.movedTo)
        return { ok: false, message: "HEY kept the event on its calendar: an invitation moves only onto a calendar nobody else is on. The rest was saved." }
    }
    return { ok: true, message: write.summary }
  }
  if (code === 404 && write.occurrence)
    return { ok: false, message: "HEY no longer has that day of the series, or does not let you change it. Refresh and try again." }
  if (code === 404 && write.movedTo)
    return { ok: false, message: "HEY files events only on a calendar you own or share. Pick another calendar." }
  return { ok: false, message: failure(code, answer(code, body, "").json, "write") }
}

if (typeof module !== "undefined") {
  module.exports = {
    useZones: useZones,
    requestTimeoutMs: requestTimeoutMs,
    responseByteLimit: responseByteLimit,
    sessionCommand: sessionCommand,
    parseSession: parseSession,
    formEncode: formEncode,
    escapeComponent: escapeComponent,
    editTarget: editTarget,
    editFlags: editFlags,
    step: step,
    headers: headers,
    nextPage: nextPage,
    answer: answer,
    writeResult: writeResult
  }
}
