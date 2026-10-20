// IANA time zones, read from the system's zone files (TZif, RFC 8536).
//
// Qt's JavaScript has no Intl, so it cannot say what the clock reads in New
// York at a given instant, or which instant 09:00 in Tokyo is. Writing an
// event to HEY needs both: an edit sends back the times it did not change,
// as clock times in the event's own zone. The zone file is the same data
// hey-cli and HEY read, so the answers are theirs. Qt-free; the QML side
// hands in the file's bytes, and plain node runs it in the tests.

var hourSeconds = 3600
var daySeconds = 86400

// A zone Calendar for Omarchy will load: a path under the zone directory, never an alias
// hey-cli refuses (Local, posix/, right/ and the like).
function isZoneName(name) {
  var text = String(name || "")
  if (text === "UTC") return true
  if (!/^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/.test(text)) return false
  if (/^(Local|localtime|posixrules|Factory)$/.test(text) || /^(posix|right)\//.test(text)) return false
  return text.length <= 64
}

function zonePath(name) {
  return isZoneName(name) ? "/usr/share/zoneinfo/" + name : ""
}

// ---------------------------------------------------------------------------
// Calendar arithmetic on plain numbers, no Date involved
// ---------------------------------------------------------------------------

function isLeap(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0
}

var monthStarts = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

function daysInMonth(year, month) {
  return [31, isLeap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
}

// Seconds from the epoch to midnight UTC on that day.
function daySecondsOf(year, month, day) {
  return Date.UTC(year, month - 1, day) / 1000
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function pad4(n) {
  var text = String(n)
  while (text.length < 4) text = "0" + text
  return text
}

// ---------------------------------------------------------------------------
// The POSIX TZ string a zone file ends with, for times past its last
// transition: "CET-1CEST,M3.5.0,M10.5.0/3"
// ---------------------------------------------------------------------------

function parsePosix(text) {
  var at = 0
  var s = String(text || "")
  function name() {
    if (s.charAt(at) === "<") {
      var close = s.indexOf(">", at)
      if (close === -1) return null
      var quoted = s.substring(at + 1, close)
      at = close + 1
      return quoted
    }
    var start = at
    while (at < s.length && /[A-Za-z]/.test(s.charAt(at))) at++
    return at - start >= 3 ? s.substring(start, at) : null
  }
  // [+-]hh[:mm[:ss]], as seconds.
  function clock() {
    var sign = 1
    if (s.charAt(at) === "+" || s.charAt(at) === "-") {
      if (s.charAt(at) === "-") sign = -1
      at++
    }
    var match = /^(\d{1,3})(?::(\d{1,2}))?(?::(\d{1,2}))?/.exec(s.substring(at))
    if (!match) return null
    at += match[0].length
    return sign * (Number(match[1]) * hourSeconds + Number(match[2] || 0) * 60 + Number(match[3] || 0))
  }
  function rule() {
    var r = null
    var match
    if ((match = /^M(\d{1,2})\.(\d)\.(\d)/.exec(s.substring(at)))) {
      r = { kind: "M", month: Number(match[1]), week: Number(match[2]), day: Number(match[3]) }
    } else if ((match = /^J(\d{1,3})/.exec(s.substring(at)))) {
      r = { kind: "J", day: Number(match[1]) }
    } else if ((match = /^(\d{1,3})/.exec(s.substring(at)))) {
      r = { kind: "N", day: Number(match[1]) }
    } else {
      return null
    }
    at += match[0].length
    r.time = 2 * hourSeconds
    if (s.charAt(at) === "/") {
      at++
      var time = clock()
      if (time === null) return null
      r.time = time
    }
    return r
  }

  var std = name()
  if (std === null) return null
  var stdOffset = clock()
  if (stdOffset === null) return null
  var zone = { std: -stdOffset, dst: null }
  if (at >= s.length) return zone
  if (name() === null) return null
  zone.dst = zone.std + hourSeconds
  if (at < s.length && s.charAt(at) !== ",") {
    var dstOffset = clock()
    if (dstOffset === null) return null
    zone.dst = -dstOffset
  }
  // A daylight name without rules takes the US rules, as Go's tzset does.
  if (at >= s.length) {
    zone.start = { kind: "M", month: 3, week: 2, day: 0, time: 2 * hourSeconds }
    zone.end = { kind: "M", month: 11, week: 1, day: 0, time: 2 * hourSeconds }
    return zone
  }
  if (s.charAt(at) !== ",") return null
  at++
  zone.start = rule()
  if (zone.start === null || s.charAt(at) !== ",") return null
  at++
  zone.end = rule()
  if (zone.end === null || at !== s.length) return null
  return zone
}

// Seconds into the year (UTC-based, as if local were UTC) at which a rule
// fires, before its own time of day.
function ruleDay(year, rule) {
  if (rule.kind === "J") {
    var day = rule.day - 1
    if (isLeap(year) && rule.day >= 60) day++
    return day * daySeconds
  }
  if (rule.kind === "N") return rule.day * daySeconds
  var first = daySecondsOf(year, rule.month, 1)
  var weekday = (new Date(first * 1000).getUTCDay())
  var dayOfMonth = (rule.day - weekday + 7) % 7 + (rule.week - 1) * 7
  if (rule.week === 5) while (dayOfMonth >= daysInMonth(year, rule.month)) dayOfMonth -= 7
  return (monthStarts[rule.month - 1] + (rule.month > 2 && isLeap(year) ? 1 : 0) + dayOfMonth) * daySeconds
}

// { offset, isDst } at an instant, under the POSIX rules: what Go's tzset
// answers, on the UTC year of the instant.
function posixAt(zone, seconds) {
  if (zone.dst === null) return { offset: zone.std, isDst: false }
  var year = new Date(seconds * 1000).getUTCFullYear()
  var yearStart = daySecondsOf(year, 1, 1)
  var start = yearStart + ruleDay(year, zone.start) + zone.start.time - zone.std
  var end = yearStart + ruleDay(year, zone.end) + zone.end.time - zone.dst
  var inDst = start < end ? (seconds >= start && seconds < end) : !(seconds >= end && seconds < start)
  return inDst ? { offset: zone.dst, isDst: true } : { offset: zone.std, isDst: false }
}

// ---------------------------------------------------------------------------
// Zone files
// ---------------------------------------------------------------------------

// A zone from its file's bytes (a Uint8Array, an ArrayBuffer, or a node
// Buffer), or null when they are not a zone file.
function parse(data) {
  var bytes = data instanceof Uint8Array ? data : (data ? new Uint8Array(data) : null)
  if (!bytes || bytes.length < 44) return null
  if (String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) !== "TZif") return null
  var version = bytes[4]

  function u32(at) {
    return ((bytes[at] << 24) >>> 0) + (bytes[at + 1] << 16) + (bytes[at + 2] << 8) + bytes[at + 3]
  }
  function s32(at) {
    var value = u32(at)
    return value >= 0x80000000 ? value - 0x100000000 : value
  }
  function s64(at) {
    return s32(at) * 0x100000000 + u32(at + 4)
  }
  function header(at) {
    return { isutcnt: u32(at + 20), isstdcnt: u32(at + 24), leapcnt: u32(at + 28),
      timecnt: u32(at + 32), typecnt: u32(at + 36), charcnt: u32(at + 40) }
  }
  function blockLength(h, timeSize) {
    return h.timecnt * timeSize + h.timecnt + h.typecnt * 6 + h.charcnt
      + h.leapcnt * (timeSize + 4) + h.isstdcnt + h.isutcnt
  }

  var h = header(0)
  var at = 44
  var timeSize = 4
  if (version >= 0x32) {
    // Version 2 and later repeat the data with 64-bit times, which is the
    // copy to read; the first is for old readers.
    at += blockLength(h, 4)
    if (at + 44 > bytes.length) return null
    h = header(at)
    at += 44
    timeSize = 8
  }
  if (at + blockLength(h, timeSize) > bytes.length || h.typecnt === 0) return null

  var transitions = []
  for (var i = 0; i < h.timecnt; i++) transitions.push(timeSize === 8 ? s64(at + i * 8) : s32(at + i * 4))
  at += h.timecnt * timeSize
  var kinds = []
  for (i = 0; i < h.timecnt; i++) kinds.push(bytes[at + i])
  at += h.timecnt
  var infos = []
  for (i = 0; i < h.typecnt; i++) infos.push({ offset: s32(at + i * 6), isDst: bytes[at + i * 6 + 4] !== 0 })
  at += h.typecnt * 6
  for (i = 0; i < kinds.length; i++) if (kinds[i] >= infos.length) return null
  at += h.charcnt + h.leapcnt * (timeSize + 4) + h.isstdcnt + h.isutcnt

  var footer = null
  if (timeSize === 8 && bytes[at] === 10) {
    var end = at + 1
    while (end < bytes.length && bytes[end] !== 10) end++
    var text = ""
    for (var j = at + 1; j < end; j++) text += String.fromCharCode(bytes[j])
    if (text !== "") footer = parsePosix(text)
  }

  // Before the first transition, the first type that is not daylight time,
  // as Go's lookupFirstZone has it.
  var first = infos[0]
  for (i = 0; i < infos.length; i++) if (!infos[i].isDst) { first = infos[i]; break }

  return makeZone(function(seconds) {
    if (transitions.length === 0 || seconds < transitions[0]) {
      if (transitions.length === 0 && footer) return posixAt(footer, seconds)
      return first
    }
    if (seconds >= transitions[transitions.length - 1] && footer) return posixAt(footer, seconds)
    var lo = 0
    var hi = transitions.length - 1
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1
      if (transitions[mid] <= seconds) lo = mid
      else hi = mid - 1
    }
    return infos[kinds[lo]]
  })
}

// UTC, which needs no file.
var utc = makeZone(function() { return { offset: 0, isDst: false } })

// ---------------------------------------------------------------------------
// A zone: what its clock reads, and which instant a clock time names
// ---------------------------------------------------------------------------

function makeZone(lookup) {
  // { date: "YYYY-MM-DD", clock: "HH:MM", second } as the zone's clock reads
  // an instant in milliseconds.
  function wall(ms) {
    var seconds = Math.floor(ms / 1000)
    var at = new Date((seconds + lookup(seconds).offset) * 1000)
    return {
      date: pad4(at.getUTCFullYear()) + "-" + pad2(at.getUTCMonth() + 1) + "-" + pad2(at.getUTCDate()),
      clock: pad2(at.getUTCHours()) + ":" + pad2(at.getUTCMinutes()),
      second: at.getUTCSeconds()
    }
  }

  // Every instant (seconds) whose clock reads `local` (seconds, local time
  // counted as if UTC): none in a gap, two in a fall-back, one elsewhere.
  // Each offset the zone has within a day and a half either side is tried,
  // as hey-cli's instantsReading does; the offsets are sampled every 15
  // minutes, finer than any change of the clocks in the zone database.
  function instantsReading(local) {
    var offsets = []
    for (var at = local - 36 * hourSeconds; at <= local + 36 * hourSeconds; at += 900) {
      var offset = lookup(at).offset
      if (offsets.indexOf(offset) === -1) offsets.push(offset)
    }
    var instants = []
    for (var i = 0; i < offsets.length; i++) {
      var candidate = local - offsets[i]
      if (lookup(candidate).offset === offsets[i] && instants.indexOf(candidate) === -1) instants.push(candidate)
    }
    instants.sort(function(a, b) { return a - b })
    return instants
  }

  // The instant (ms) HEY stores for a day ("YYYY-MM-DD") and a clock time
  // ("HH:MM" or "HH:MM:SS") in this zone: hey-cli's timezone.WallClock. A
  // time the clocks skip moves on an hour, date and all, until it exists; a
  // time they repeat is the daylight-saving one, or the later where neither
  // or both are.
  function place(date, clock) {
    var d = String(date).split("-")
    var c = String(clock).split(":")
    var local = daySecondsOf(Number(d[0]), Number(d[1]), Number(d[2]))
      + Number(c[0]) * hourSeconds + Number(c[1]) * 60 + Number(c[2] || 0)
    for (var tries = 0; tries < 48; tries++) {
      var instants = instantsReading(local)
      if (instants.length > 0) {
        var saving = instants.filter(function(at) { return lookup(at).isDst })
        var pick = saving.length > 0 ? saving : instants
        return pick[pick.length - 1] * 1000
      }
      local += hourSeconds
    }
    return goDate(date, clock)
  }

  // Go's time.Date for the same: one side of a gap or an overlap by Go's
  // own rule. hey-cli uses it for a day's midnight, and nothing else.
  function goDate(date, clock) {
    var d = String(date).split("-")
    var c = String(clock || "00:00").split(":")
    var local = daySecondsOf(Number(d[0]), Number(d[1]), Number(d[2]))
      + Number(c[0]) * hourSeconds + Number(c[1]) * 60 + Number(c[2] || 0)
    var offset = lookup(local).offset
    var again = lookup(local - offset).offset
    return (local - (again !== offset ? again : offset)) * 1000
  }

  return {
    offsetAt: function(ms) { return lookup(Math.floor(ms / 1000)).offset },
    isDstAt: function(ms) { return lookup(Math.floor(ms / 1000)).isDst },
    wall: wall,
    place: place,
    goDate: goDate
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    isZoneName: isZoneName,
    zonePath: zonePath,
    parse: parse,
    parsePosix: parsePosix,
    utc: utc
  }
}
