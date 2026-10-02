// Plain node, no dependencies: `tests/run` runs this in several timezones.
var assert = require("assert")
var Hey = require("../Calendar.js")
var Backend = require("../backends/Hey.js")

var tz = process.env.TZ || "local"
var failures = 0

function test(name, fn) {
  try {
    fn()
  } catch (e) {
    failures++
    console.error("FAIL [" + tz + "] " + name + "\n  " + e.message)
  }
}

// A timed event at local wall-clock times, so expectations hold in any zone.
function timed(id, title, y, m, d, h, min, durationMin, extra) {
  var start = new Date(y, m - 1, d, h, min)
  var end = new Date(start.getTime() + durationMin * 60000)
  var raw = {
    id: id, title: title, all_day: false,
    starts_at: start.toISOString(), ends_at: end.toISOString(),
    calendar: "Work", color: "blue", reminders: []
  }
  for (var k in extra || {}) raw[k] = extra[k]
  return Hey.normalizeEvent(raw)
}

function allDay(id, title, startKey, endKey, extra) {
  var raw = {
    id: id, title: title, all_day: true,
    starts_at: startKey + "T00:00:00Z", ends_at: (endKey || startKey) + "T00:00:00Z",
    calendar: "Relationships", color: "red", reminders: []
  }
  for (var k in extra || {}) raw[k] = extra[k]
  return Hey.normalizeEvent(raw)
}

// ---- HEY backend: versions

function mode(text) { return Backend.probe(text).mode }

test("Omarchy's packaged 1.3.0 reads by list, 1.4+ by week", function() {
  assert.strictEqual(mode("hey version 1.3.0"), "list")
  assert.strictEqual(mode("hey version 1.3.9"), "list")
  assert.strictEqual(mode("hey version 1.4.0"), "week")
  assert.strictEqual(mode("hey version 1.7.0"), "week")
  assert.strictEqual(mode("hey version 2.0.0"), "week")
})

test("older or missing CLIs are refused, unreadable versions assumed new", function() {
  assert.strictEqual(mode("hey version 1.2.9"), "")
  assert.strictEqual(mode(""), "")
  assert.strictEqual(mode("hey version dev"), "week")
})

test("list mode pads the window a day each side and names the span", function() {
  var cmd = Backend.fetchCommand("list", ["2026-10-05", "2026-09-28"])
  assert.deepStrictEqual(cmd.slice(-4), ["2026-09-28", "2026-10-11", "2026-09-27", "2026-10-12"])
})

// ---- Days

test("all-day events stay on their date in every zone", function() {
  var e = allDay(1, "Bday", "2026-09-26")
  assert.deepStrictEqual(Hey.eventDayKeys(e), ["2026-09-26"])
})

// HEY stores a trip from the 13th to the 16th with the 16th as its end, and
// draws it on all four days (`hey event day` lists it on the 16th).
test("multi-day all-day events end on their last day", function() {
  var e = allDay(1, "Trip", "2026-10-13", "2026-10-16")
  assert.deepStrictEqual(Hey.eventDayKeys(e), ["2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"])
})

test("timed events span every local day they cover", function() {
  var e = timed(1, "Train", 2026, 10, 6, 9, 0, (5 * 24 + 1) * 60)
  var keys = Hey.eventDayKeys(e)
  assert.strictEqual(keys[0], "2026-10-06")
  assert.strictEqual(keys[keys.length - 1], "2026-10-11")
  assert.strictEqual(Hey.spanPosition(e, "2026-10-06"), "first")
  assert.strictEqual(Hey.spanPosition(e, "2026-10-08"), "middle")
  assert.strictEqual(Hey.spanPosition(e, "2026-10-11"), "last")
})

test("a timed event ending at midnight does not spill into the next day", function() {
  var e = timed(1, "Late", 2026, 9, 28, 22, 0, 120)
  assert.deepStrictEqual(Hey.eventDayKeys(e), ["2026-09-28"])
})

test("weekKeysBetween names HEY's Monday weeks", function() {
  assert.deepStrictEqual(Hey.weekKeysBetween("2026-08-30", "2026-10-10"),
    ["2026-08-24", "2026-08-31", "2026-09-07", "2026-09-14", "2026-09-21", "2026-09-28", "2026-10-05"])
})

// ---- Chips

test("chips group a day by color with counts, in the day's order", function() {
  var events = [
    timed(1, "Podcast", 2026, 9, 28, 13, 0, 90),
    timed(2, "Standup", 2026, 9, 28, 9, 0, 15),
    timed(3, "Dinner", 2026, 9, 28, 18, 30, 60, { color: "red", calendar: "Relationships" })
  ]
  var chips = Hey.dayChips(Hey.eventsForDay(events, "2026-09-28"), 3)
  assert.deepStrictEqual(chips.map(function(c) { return c.color + ":" + c.count }), ["blue:2", "red:1"])
})

test("past the limit, the last chip is +N for the rest", function() {
  var colors = ["blue", "red", "gold", "teal", "green"]
  var events = colors.map(function(color, i) {
    return timed(i + 1, "E" + i, 2026, 9, 28, 8 + i, 0, 30, { color: color })
  })
  var chips = Hey.dayChips(Hey.eventsForDay(events, "2026-09-28"), 3)
  assert.strictEqual(chips.length, 3)
  assert.strictEqual(chips[2].overflow, true)
  assert.strictEqual(chips[2].count, 3)
})

// ---- Parsing

test("week output: failures are null, not empty", function() {
  var out = '{"week":"2026-09-28","events":[{"id":1,"title":"A","starts_at":"2026-09-28T10:00:00Z","ends_at":"2026-09-28T11:00:00Z"}]}\n'
    + '{"week":"2026-10-05","error":true}\n'
  var weeks = Hey.parseRangeOutput(out)
  assert.strictEqual(weeks["2026-09-28"].length, 1)
  assert.strictEqual(weeks["2026-10-05"], null)
  assert.strictEqual(Hey.parseRangeOutput(""), null)
})

test("unsafe links are dropped", function() {
  assert.strictEqual(Hey.safeUrl("javascript:alert(1)"), "")
  assert.strictEqual(Hey.safeUrl("https://meet.example.com/x"), "https://meet.example.com/x")
})

test("hidden calendars are matched by name, case-insensitively", function() {
  var events = [timed(1, "A", 2026, 9, 28, 9, 0, 30), timed(2, "B", 2026, 9, 28, 10, 0, 30, { calendar: "Todoist" })]
  var hidden = Hey.parseHiddenCalendars("todoist, ")
  assert.deepStrictEqual(Hey.withoutHidden(events, hidden).map(function(e) { return e.title }), ["A"])
})

// ---- Repeats (hey-cli 1.3.x)

test("yearly all-day series land on their date in the range", function() {
  var e = allDay(9, "Bday", "1987-07-14", "1987-07-14", { repeat_kind: "rrule", repeat_description: "yearly on the 14th day of the month in July" })
  var out = Hey.expandRecurring(e, "2026-07-01", "2026-07-31")
  assert.deepStrictEqual(out.map(function(o) { return o.startsAt.substr(0, 10) }), ["2026-07-14"])
})

test("weekly series stop at their 'until' date", function() {
  var e = timed(5, "Meetup", 2026, 7, 30, 19, 30, 60, { repeat_kind: "every_week", repeat_description: "every week until September  3, 2026" })
  var keys = Hey.expandRecurring(e, "2026-08-24", "2026-09-13").map(function(o) { return Hey.eventDayKeys(o)[0] })
  assert.deepStrictEqual(keys, ["2026-08-27", "2026-09-03"])
})

test("weekday series skip weekends and honour a count", function() {
  var e = timed(6, "Standup", 2026, 9, 25, 9, 0, 15, { repeat_kind: "every_weekday", repeat_description: "every weekday 4 times" })
  var keys = Hey.expandRecurring(e, "2026-09-20", "2026-10-10").map(function(o) { return Hey.eventDayKeys(o)[0] })
  assert.deepStrictEqual(keys, ["2026-09-25", "2026-09-28", "2026-09-29", "2026-09-30"])
})

test("monthly series skip months without that day", function() {
  var e = allDay(7, "Rent", "2026-01-31", "2026-01-31", { repeat_kind: "every_day_of_month", repeat_description: "every month" })
  var keys = Hey.expandRecurring(e, "2026-02-01", "2026-04-30").map(function(o) { return o.startsAt.substr(0, 10) })
  assert.deepStrictEqual(keys, ["2026-03-31"])
})

test("occurrences keep their local wall-clock time across DST", function() {
  var e = timed(8, "Gym", 2026, 3, 20, 7, 0, 60, { repeat_kind: "every_week", repeat_description: "every week" })
  var out = Hey.expandRecurring(e, "2026-04-01", "2026-04-07")
  assert.strictEqual(out.length, 1)
  var start = new Date(out[0].startMs)
  assert.strictEqual(start.getHours(), 7)
  assert.strictEqual(out[0].key !== e.key, true)
})

// ---- Bar

test("the bar names an event and says when", function() {
  var e = timed(1, "Team sync", 2026, 9, 28, 13, 0, 90)
  var before = e.startMs - 12 * 60000
  assert.strictEqual(Hey.barEventLabel(e, before, true), "Team sync · in 12m")
  assert.strictEqual(Hey.barEventLabel(e, e.startMs + 60000, true), "Team sync · until 14:30")
  assert.strictEqual(Hey.barEventLabel(e, e.startMs - 3 * 3600000, true), "Team sync · at 13:00")
  assert.strictEqual(Hey.barEventLabel(e, e.startMs - 24 * 3600000, true), "Team sync · tomorrow 13:00")
})

test("the bar opens at the earliest reminder, or the lead time without one", function() {
  var e = timed(1, "Flight", 2026, 9, 28, 13, 0, 90)
  e.reminders = [e.startMs - 30 * 60000, e.startMs - 24 * 3600000]
  assert.deepStrictEqual(Hey.barSelection("soon", [e], [], e.startMs - 20 * 3600000, 15), [e])
  assert.deepStrictEqual(Hey.barSelection("soon", [e], [], e.startMs - 25 * 3600000, 15), [])
  var plain = timed(2, "Call", 2026, 9, 28, 13, 0, 30)
  assert.deepStrictEqual(Hey.barSelection("soon", [plain], [], plain.startMs - 20 * 60000, 15), [])
  assert.deepStrictEqual(Hey.barSelection("soon", [plain], [], plain.startMs - 10 * 60000, 15), [plain])
  assert.deepStrictEqual(Hey.barSelection("soon", [plain], [], plain.endMs, 15), [])
})

test("all-day events show from their reminder, never without one", function() {
  var bday = allDay(3, "Lena's bday", "2026-09-29")
  var eve = new Date(2026, 8, 28, 20, 0).getTime()
  assert.deepStrictEqual(Hey.barSelection("soon", [bday], [], eve, 15), [])
  bday.reminders = [new Date(2026, 8, 28, 8, 0).getTime()]
  assert.deepStrictEqual(Hey.barSelection("soon", [bday], [], eve, 15), [bday])
  assert.strictEqual(Hey.barEventLabel(bday, eve, true), "Lena's bday · tomorrow")
  assert.deepStrictEqual(Hey.barSelection("soon", [bday], [], new Date(2026, 8, 30, 0, 1).getTime(), 15), [])
})

test("overlaps: about to start beats under way beats coming beats all day", function() {
  var now = new Date(2026, 9, 1, 10, 0).getTime()
  var meeting = timed(1, "Meeting", 2026, 10, 1, 9, 30, 60)
  var soon = timed(2, "Standup", 2026, 10, 1, 10, 10, 15)
  var later = timed(3, "Lunch", 2026, 10, 1, 12, 0, 60)
  later.reminders = [later.startMs - 3 * 3600000]
  var holiday = allDay(4, "Holiday", "2026-10-01", "2026-10-01", { reminders: ["2026-09-30T08:00:00Z"] })
  var pick = Hey.barSelection("soon", [holiday, later, meeting, soon], [], now, 15)
  assert.deepStrictEqual(pick.map(function(e) { return e.title }), ["Standup", "Meeting", "Lunch", "Holiday"])
  assert.strictEqual(Hey.barLabel(pick, now, true), "Standup · in 10m  +3")
  var afterStandup = Hey.barSelection("soon", [meeting, later], [], now + 5 * 60000, 15)
  assert.strictEqual(afterStandup[0].title, "Meeting")
})

test("time mode drops the title and keeps the when", function() {
  var e = timed(1, "Secret meeting", 2026, 9, 28, 13, 0, 30)
  var now = e.startMs - 12 * 60000
  var pick = Hey.barSelection("time", [e], [e], now, 15)
  assert.strictEqual(Hey.barLabel(pick, now, true, "time"), "in 12m")
})

test("name mode keeps the title and drops the when", function() {
  var a = timed(1, "Standup", 2026, 9, 28, 13, 0, 15)
  var b = timed(2, "Lunch", 2026, 9, 28, 13, 5, 60)
  var now = a.startMs - 5 * 60000
  var pick = Hey.barSelection("name", [a, b], [a, b], now, 15)
  assert.strictEqual(Hey.barLabel(pick, now, true, "name"), "Standup  +1")
})

test("next mode falls back to today's next event", function() {
  var e = timed(1, "Dinner", 2026, 9, 28, 18, 30, 60)
  var now = e.startMs - 3 * 3600000
  assert.deepStrictEqual(Hey.barSelection("next", [e], [e], now, 15), [e])
  assert.deepStrictEqual(Hey.barSelection("off", [e], [e], e.startMs - 60000, 15), [])
})

test("long titles are cut to fit the bar", function() {
  var e = timed(1, "A very long meeting title that goes on and on", 2026, 9, 28, 13, 0, 30)
  assert.ok(Hey.barEventLabel(e, e.startMs - 60000, true).indexOf("…") !== -1)
})

// ---- Standard shapes any backend prints

test("time tracks are read from the standard shape", function() {
  var tracks = Hey.parseTimeTracks(JSON.stringify([
    { id: 1, name: "Writing", named: true, notes: "", starts_at: "2026-09-28T10:00:00Z", ends_at: "2026-09-28T11:00:00Z" },
    { id: 2, name: "", named: false, starts_at: "2026-09-28T12:00:00Z", ends_at: "2026-09-28T12:30:00Z" }
  ]))
  assert.deepStrictEqual(tracks.map(function(t) { return [t.name, t.named] }), [["Writing", true], ["Time track", false]])
  assert.strictEqual(Hey.parseCurrentTrack('{"ok":true,"track":null}'), null)
  assert.strictEqual(Hey.parseCurrentTrack('{"ok":true,"track":{"id":5,"name":"Deep work","starts_at":"2026-09-28T10:00:00Z"}}').title, "Deep work")
  assert.strictEqual(Hey.parseCurrentTrack('{"ok":false}'), undefined)
})

test("calendar colors: HEY's names, other services' hex, the accent otherwise", function() {
  assert.strictEqual(Hey.calendarColor("blue", "#000000"), "#6baffc")
  assert.strictEqual(Hey.calendarColor("#1A2B3C", "#000000"), "#1a2b3c")
  assert.strictEqual(Hey.calendarColor("chartreuse", "#000000"), "#000000")
})

test("the HEY backend probes its CLI and says why it cannot run", function() {
  assert.ok(Backend.probe("").error.indexOf("not installed") !== -1)
  assert.ok(Backend.probe("hey version 1.2.0").error.indexOf("too old") !== -1)
  assert.strictEqual(Backend.probe("hey version 1.3.0").version, "1.3.0")
  assert.strictEqual(Backend.writeResult(0, '{"ok":true,"summary":"Created"}').ok, true)
  assert.strictEqual(Backend.writeResult(124, "").message, "HEY took too long to answer.")
})

// ---- Reminders

test("due reminders fire once, and never for what came due before start", function() {
  var now = Date.UTC(2026, 8, 28, 10, 30)
  var e = Hey.normalizeEvent({ id: 1, title: "Podcast", starts_at: "2026-09-28T11:00:00Z", ends_at: "2026-09-28T12:30:00Z",
    reminders: ["2026-09-28T10:30:00Z", "2026-09-28T09:00:00Z"] })
  var due = Hey.dueReminders([e], now, now - 60000, {})
  assert.strictEqual(due.length, 1)
  var shown = {}
  shown[due[0].key] = now
  assert.strictEqual(Hey.dueReminders([e], now + 15000, now - 60000, shown).length, 0)
  assert.strictEqual(Hey.reminderLead(e, now), "In 30 min")
})

test("a reminder carries a safe marker and a calendar-coloured icon", function() {
  var e = Hey.normalizeEvent({ id: 7, title: "Stand-up; rm -rf /", starts_at: "2026-09-29T09:30:00Z",
    ends_at: "2026-09-29T09:45:00Z", color: "blue", reminders: ["2026-09-29T09:15:00Z"] })
  var env = Hey.notifyCommand(e, e.startMs - 15 * 60000, true, "", e.reminders[0]).environment
  assert.ok(/^[A-Za-z0-9_-]+$/.test(env.OMACAL_MARKER), env.OMACAL_MARKER)
  assert.ok(/^icon-6baffc-\d{1,2}\.svg$/.test(env.OMACAL_ICON), env.OMACAL_ICON)
  assert.ok(env.OMACAL_SVG.indexOf('fill="#6baffc"') !== -1)
  assert.strictEqual(env.OMACAL_TITLE, "Stand-up; rm -rf /")
})

// Any user can read a process's arguments, but only its owner its environment.
test("a reminder keeps the event's details off the command line", function() {
  var e = Hey.normalizeEvent({ id: 8, title: "Doctor appointment", starts_at: "2026-09-29T09:30:00Z",
    ends_at: "2026-09-29T10:30:00Z", calendar: "Private", location: "12 Secret Street",
    join_url: "https://meet.example.com/abc-defg-hij", reminders: ["2026-09-29T09:15:00Z"] })
  var cmd = Hey.notifyCommand(e, e.startMs - 15 * 60000, true, "", e.reminders[0])
  var argv = cmd.command.join("\n")
  ;["Doctor appointment", "Private", "12 Secret Street", "meet.example.com"].forEach(function(secret) {
    assert.strictEqual(argv.indexOf(secret), -1, secret)
  })
  assert.strictEqual(cmd.command[0], "/usr/bin/python3")
  assert.strictEqual(cmd.environment.OMACAL_TITLE, "Doctor appointment")
  assert.ok(cmd.environment.OMACAL_BODY.indexOf("12 Secret Street") !== -1)
  assert.strictEqual(cmd.environment.OMACAL_LINK, "https://meet.example.com/abc-defg-hij")
})

test("declined events never notify", function() {
  var now = Date.UTC(2026, 8, 28, 10, 30)
  var e = Hey.normalizeEvent({ id: 1, title: "Nope", starts_at: "2026-09-28T11:00:00Z", status: "declined",
    reminders: ["2026-09-28T10:30:00Z"] })
  assert.strictEqual(Hey.dueReminders([e], now, 0, {}).length, 0)
})

// ---- New events

test("clock input is forgiving", function() {
  assert.strictEqual(Hey.parseClock("9"), "09:00")
  assert.strictEqual(Hey.parseClock("930"), "09:30")
  assert.strictEqual(Hey.parseClock("21.30"), "21:30")
  assert.strictEqual(Hey.parseClock("9:30pm"), "21:30")
  assert.strictEqual(Hey.parseClock("12am"), "00:00")
  assert.strictEqual(Hey.parseClock("25:00"), "")
  assert.strictEqual(Hey.parseClock("soon"), "")
})

test("day input is forgiving, relative to today (a Monday)", function() {
  var today = "2026-09-28"
  assert.strictEqual(Hey.parseDay("", today), today)
  assert.strictEqual(Hey.parseDay("tomorrow", today), "2026-09-29")
  assert.strictEqual(Hey.parseDay("fri", today), "2026-10-02")
  assert.strictEqual(Hey.parseDay("mon", today), today)
  assert.strictEqual(Hey.parseDay("next mon", today), "2026-10-05")
  assert.strictEqual(Hey.parseDay("in 3 days", today), "2026-10-01")
  assert.strictEqual(Hey.parseDay("+2w", today), "2026-10-12")
  assert.strictEqual(Hey.parseDay("3 oct", today), "2026-10-03")
  assert.strictEqual(Hey.parseDay("Oct 3rd", today), "2026-10-03")
  assert.strictEqual(Hey.parseDay("3", today), "2026-10-03")
  assert.strictEqual(Hey.parseDay("30", today), "2026-09-30")
  assert.strictEqual(Hey.parseDay("1 jan", today), "2027-01-01")
  assert.strictEqual(Hey.parseDay("2026-12-24", today), "2026-12-24")
  assert.strictEqual(Hey.parseDay("31 feb", today), "")
  assert.strictEqual(Hey.parseDay("someday", today), "")
})

test("arrow keys nudge times on a quarter-hour grid, and wrap lists", function() {
  assert.strictEqual(Hey.nudgeClock("9:07", 15, ""), "09:15")
  assert.strictEqual(Hey.nudgeClock("9:07", -15, ""), "09:00")
  assert.strictEqual(Hey.nudgeClock("09:00", 15, ""), "09:15")
  assert.strictEqual(Hey.nudgeClock("", 15, "14:00"), "14:15")
  assert.strictEqual(Hey.nudgeClock("23:45", 15, ""), "00:00")
  assert.strictEqual(Hey.shiftClock("9:30", 60), "10:30")
  assert.strictEqual(Hey.cycle([1, 2, 3], 3, 1), 1)
  assert.strictEqual(Hey.cycle([1, 2, 3], 1, -1), 3)
  assert.strictEqual(Hey.cycle(["", "10m"], "", 1), "10m")
})

// validateEvent checks the form; the backend turns the request into argv.
function build(form) {
  var checked = Hey.validateEvent(Object.assign({ timeZone: "Europe/Berlin" }, form))
  return checked.error ? checked : { command: Backend.createCommand(checked.request) }
}

test("the add command is an argv, with every field in its own argument", function() {
  var built = build({ title: "Dinner; rm -rf ~", date: "2026-09-28", startTime: "7pm", endTime: "22:00",
    calendarId: 3, location: "Café Luna", remind: "30m" })
  var args = built.command
  assert.ok(args.indexOf("Dinner; rm -rf ~") !== -1)
  assert.deepStrictEqual(args.slice(args.indexOf("--start-time"), args.indexOf("--start-time") + 2), ["--start-time", "19:00"])
  assert.ok(args.indexOf("--calendar") !== -1 && args.indexOf("3") !== -1)
  assert.ok(args.indexOf("--remind") !== -1)
})

test("an end before the start is the next morning", function() {
  var args = build({ title: "Party", date: "2026-09-28", startTime: "22:00", endTime: "1:00" }).command
  assert.deepStrictEqual(args.slice(args.indexOf("--ends-on"), args.indexOf("--ends-on") + 2), ["--ends-on", "2026-09-29"])
})

test("the form refuses what HEY would", function() {
  assert.ok(Hey.validateEvent({ title: " ", date: "2026-09-28" }).error)
  assert.ok(Hey.validateEvent({ title: "X", date: "2026-09-28", startTime: "nope", timeZone: "UTC" }).error)
  assert.ok(Hey.validateEvent({ title: "X", date: "2026-09-28", startTime: "10:00", endTime: "10:00", timeZone: "UTC" }).error)
})

// hey-cli up to 1.7 sends no zone when $TZ is unset, and HEY then reads the
// clock times as UTC: 18:30 in Berlin became 20:30.
test("a timed event always names the zone its times are in", function() {
  var args = build({ title: "Palestra", date: "2026-09-30", startTime: "18:30", endTime: "20:00" }).command
  assert.deepStrictEqual(args.slice(args.indexOf("--time-zone"), args.indexOf("--time-zone") + 2), ["--time-zone", "Europe/Berlin"])
  args = build({ title: "Call", date: "2026-09-30", startTime: "9", timeZone: "America/New_York" }).command
  assert.strictEqual(args[args.indexOf("--time-zone") + 1], "America/New_York")
})

test("a timed event with no zone, or a made-up one, is refused rather than guessed", function() {
  assert.ok(Hey.validateEvent({ title: "X", date: "2026-09-30", startTime: "18:30", timeZone: "" }).error)
  assert.ok(Hey.validateEvent({ title: "X", date: "2026-09-30", startTime: "18:30", timeZone: "Berlin" }).error)
  assert.ok(Hey.validateEvent({ title: "X", date: "2026-09-30", startTime: "18:30", timeZone: "--help" }).error)
})

// HEY keeps a zone per end; hey-cli takes one, so the backend moves an end
// on another clock onto the start's. Runs the real script, echoing the argv.
function across(form) {
  var args = build(form).command
  assert.strictEqual(args[0], "sh")
  var at = args.indexOf("timeout")
  var run = require("child_process").spawnSync(args[0], args.slice(1, at).concat(["echo"], args.slice(at)))
  return String(run.stdout).trim()
}

test("an end in another zone is the same instant on the start's clock", function() {
  var out = across({ title: "Flight", date: "2027-01-05", startTime: "10:00", endTime: "13:00",
    timeZone: "Europe/Berlin", endTimeZone: "America/New_York" })
  assert.ok(/--time-zone Europe\/Berlin /.test(out), out)
  assert.ok(/--ends-on 2027-01-05 --end-time 19:00$/.test(out), out)
  out = across({ title: "Red-eye", date: "2027-01-05", startTime: "22:00", endTime: "06:00",
    timeZone: "America/New_York", endTimeZone: "Europe/Berlin" })
  assert.ok(/--ends-on 2027-01-06 --end-time 00:00$/.test(out), out)
})

test("the end's zone is ignored when it is the start's, and checked when it is not", function() {
  var args = build({ title: "X", date: "2027-01-05", startTime: "10:00", endTime: "11:00",
    timeZone: "Europe/Berlin", endTimeZone: "Europe/Berlin" }).command
  assert.strictEqual(args[0], "timeout")
  assert.ok(Hey.validateEvent({ title: "X", date: "2027-01-05", startTime: "10:00", endTime: "11:00",
    timeZone: "Europe/Berlin", endTimeZone: "Nowhere" }).error)
  // No end time: an hour after the start, whatever the end's zone says.
  args = build({ title: "X", date: "2027-01-05", startTime: "10:00", timeZone: "Europe/Berlin", endTimeZone: "Asia/Tokyo" }).command
  assert.strictEqual(args[0], "timeout")
})

// ---- Editing

function edit(event, change, scope, occurrences) {
  var before = Hey.eventFormValues(event, "Europe/Berlin")
  var after = Object.assign({}, before, change)
  return Hey.editRequest(event, before, after, scope || "all", occurrences !== false)
}

function flag(args, name) {
  var i = args.indexOf(name)
  return i === -1 ? undefined : args[i + 1]
}

test("the edit form opens on the event as it is, and saving it unchanged sends nothing", function() {
  var e = timed(41, "Palestra", 2026, 9, 30, 18, 30, 90, { location: "Evo", calendar_id: 7, reminder_leads: [1800] })
  var values = Hey.eventFormValues(e, "Europe/Berlin")
  assert.strictEqual(values.date, "2026-09-30")
  assert.strictEqual(values.startTime, "18:30")
  assert.strictEqual(values.endTime, "20:00")
  assert.strictEqual(values.remind, "30m")
  assert.strictEqual(values.spanDays, 0)
  assert.ok(edit(e, {}).unchanged)
})

test("an edit sends only what changed", function() {
  var e = timed(41, "Palestra", 2026, 9, 30, 18, 30, 90, { location: "Evo", calendar_id: 7, reminder_leads: [1800] })
  var args = Backend.editCommand(edit(e, { title: "Gym" }).request)
  assert.deepStrictEqual(args.slice(4, 8), ["hey", "event", "edit", "41"])
  assert.strictEqual(flag(args, "--title"), "Gym")
  assert.strictEqual(args.indexOf("--start-time"), -1)
  assert.strictEqual(args.indexOf("--remind"), -1)
  assert.strictEqual(args.indexOf("--location"), -1)
})

test("a new time is sent with its day and zone, so hey-cli never reads it as UTC", function() {
  var e = timed(41, "Palestra", 2026, 9, 30, 18, 30, 90)
  var args = Backend.editCommand(edit(e, { startTime: "19:00", endTime: "20:30" }).request)
  assert.strictEqual(flag(args, "--start-time"), "19:00")
  assert.strictEqual(flag(args, "--end-time"), "20:30")
  assert.strictEqual(flag(args, "--time-zone"), "Europe/Berlin")
  assert.strictEqual(flag(args, "--starts-on"), "2026-09-30")
  assert.strictEqual(flag(args, "--ends-on"), "2026-09-30")
})

test("an overnight event keeps its end on the next day", function() {
  var e = timed(42, "Night train", 2026, 9, 30, 22, 0, 180)
  var values = Hey.eventFormValues(e, "Europe/Berlin")
  assert.strictEqual(values.endTime, "01:00")
  var args = Backend.editCommand(edit(e, { title: "Sleeper" , startTime: "22:30" }).request)
  assert.strictEqual(flag(args, "--ends-on"), "2026-10-01")
})

test("a multi-day all-day event moves as a whole", function() {
  var e = allDay(43, "Lisbon", "2026-10-13", "2026-10-16")
  var values = Hey.eventFormValues(e, "Europe/Berlin")
  assert.strictEqual(values.spanDays, 3)
  var args = Backend.editCommand(edit(e, { date: "2026-10-20" }).request)
  assert.ok(args.indexOf("--all-day") !== -1)
  assert.strictEqual(flag(args, "--starts-on"), "2026-10-20")
  assert.strictEqual(flag(args, "--ends-on"), "2026-10-23")
})

test("reminders the form cannot show are kept, and cannot be cleared", function() {
  var e = timed(44, "Flight", 2026, 10, 2, 10, 0, 120, { reminder_leads: [86400, 7200] })
  assert.strictEqual(Hey.eventFormValues(e, "Europe/Berlin").remind, "keep")
  assert.ok(edit(e, { title: "Flight home" }).request.changes.remind === undefined)
  assert.ok(edit(e, { remind: "" }).error)
  assert.strictEqual(flag(Backend.editCommand(edit(e, { remind: "1h" }).request), "--remind"), "1h")
})

test("one day of a series is edited by occurrence, the whole series by its id", function() {
  var day = timed(45, "Standup", 2026, 10, 5, 9, 30, 15, { recurring: true, occurrence_id: "45_2026-10-05" })
  var args = Backend.editCommand(edit(day, { startTime: "10:00", endTime: "10:15" }, "one").request)
  assert.deepStrictEqual(args.slice(7, 12), ["45", "--occurrence", "45_2026-10-05", "--apply-to", "current"])
  args = Backend.editCommand(edit(day, { startTime: "10:00", endTime: "10:15" }, "all").request)
  assert.strictEqual(args[7], "45")
  assert.strictEqual(args.indexOf("--occurrence"), -1)
  assert.strictEqual(args.indexOf("--starts-on"), -1, "a series keeps the day it began")
  assert.ok(edit(day, { date: "2026-10-06" }, "all").error)
  assert.ok(edit(day, { title: "X" }, "one", false).error, "old hey-cli cannot edit one day")
})

test("a day HEY wrote out on its own is edited by its own id", function() {
  var day = timed(46, "Standup", 2026, 10, 6, 9, 30, 15, { recurring: true, parent_id: 45, occurrence_id: "45_2026-10-06" })
  var args = Backend.editCommand(edit(day, { title: "Standup (moved)" }, "one").request)
  assert.strictEqual(args[7], "46")
  assert.strictEqual(args.indexOf("--occurrence"), -1)
  assert.strictEqual(Backend.editCommand(edit(day, { title: "All standups" }, "all").request)[7], "45")
})

test("hey-cli from 1.6.0 edits single days of a series", function() {
  assert.strictEqual(Backend.editsOccurrences("1.5.0"), false)
  assert.strictEqual(Backend.editsOccurrences("1.6.0"), true)
  assert.strictEqual(Backend.editsOccurrences("1.7.0"), true)
})

test("an all-day event needs no zone and sends none", function() {
  var args = build({ title: "Holiday", date: "2026-09-30", allDay: true, timeZone: "" }).command
  assert.strictEqual(args.indexOf("--time-zone"), -1)
})

test("the zone list reads the machine's zone and skips aliases", function() {
  var parsed = Hey.parseZones("Europe/Berlin\nAmerica/New_York\nEurope/Berlin\nEtc/GMT+2\nposix/Europe/Rome\nGMT\nAmerica/Argentina/Buenos_Aires\n")
  assert.strictEqual(parsed.local, "Europe/Berlin")
  assert.deepStrictEqual(parsed.zones, ["America/Argentina/Buenos_Aires", "America/New_York", "Europe/Berlin", "UTC"])
  assert.strictEqual(Hey.parseZones("\nEurope/Rome\n").local, "")
})

test("a typed zone filter puts the likeliest city first", function() {
  var zones = ["America/New_York", "America/Argentina/Buenos_Aires", "Asia/Tokyo", "Europe/Berlin", "Europe/Rome", "UTC"]
  assert.deepStrictEqual(Hey.matchZones(zones, "new y"), ["America/New_York"])
  assert.strictEqual(Hey.matchZones(zones, "buenos")[0], "America/Argentina/Buenos_Aires")
  assert.strictEqual(Hey.matchZones(zones, "europe", 1).length, 1)
  assert.strictEqual(Hey.matchZones(zones, "rom")[0], "Europe/Rome")
  assert.strictEqual(Hey.matchZones(["Arctic/Longyearbyen", "Europe/London"], "lon")[0], "Europe/London")
  assert.deepStrictEqual(Hey.matchZones(zones, "  "), [])
  assert.strictEqual(Hey.zoneLabel("America/New_York"), "America/New York")
  assert.strictEqual(Hey.zoneCity("America/Argentina/Buenos_Aires"), "Buenos Aires")
  assert.strictEqual(Hey.zoneCity("UTC"), "UTC")
})

test("repeating events are never deleted by series id", function() {
  var e = timed(1, "Standup", 2026, 9, 28, 9, 0, 15, { recurring: true })
  assert.deepStrictEqual(Backend.deleteCommand(e), [])
  assert.deepStrictEqual(Backend.deleteCommand(timed(42, "Once", 2026, 9, 28, 9, 0, 15)).slice(-3), ["delete", "42", "--json"])
})

if (failures > 0) {
  console.error(failures + " failed [" + tz + "]")
  process.exit(1)
}
console.log("ok [" + tz + "]")
