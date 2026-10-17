// HTTP payloads are exercised against synthetic HEY recordings, with no network.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const Api = require('../backends/HeyApi.js')
const Zones = require('../TimeZones.js')
const Backend = require('../backends/Hey.js')
let count = 0
function test(name, fn) {
  try { fn(); count++ } catch (error) { console.error(name); throw error }
}
const eventType = 'Calendar::Event'
const countdownType = 'Calendar::Countdown'
function event(extra = {}) {
  return Object.assign({ id: 41, title: 'Original', all_day: false,
    starts_at: '2027-12-31T09:00:00Z', ends_at: '2027-12-31T10:30:00Z',
    starts_at_time_zone: 'Europe/Berlin', ends_at_time_zone: 'Europe/Berlin',
    calendar: { id: 7 }, location: 'Old place', description: '',
    url: 'https://example.com/meeting', attached_entry: { id: 123 },
    reminders: [{ duration: 1800 }, { duration: 86400 }] }, extra)
}
function edit(changes, record = event(), scope = 'all') {
  return { kind: 'edit', request: { scope, changes, event: {
    seriesId: String(record.id), parentId: String(record.parent_id || ''),
    occurrenceId: record.occurrence_id || '', recurring: !!record.recurring,
    startMs: Date.parse(record.starts_at), calendarId: 7
  } } }
}
function run(job, record = event(), options = {}) {
  const state = { answers: {}, zones: {}, today: '2026-10-15' }
  const reads = []
  for (let i = 0; i < 50; i++) {
    const next = Api.step(job, state)
    if (next.zones) {
      for (const name of next.zones) state.zones[name] = Zones.parse(fs.readFileSync(Zones.zonePath(name)))
    } else if (next.read) {
      const { key, path: url } = next.read
      reads.push(url)
      let json
      if (url === '/calendars.json') json = { calendars: [{ calendar: { id: 7, owned: true, kind: 'normal' } }] }
      else if (url === '/identity.json') json = { time_zone: 'Europe/Berlin' }
      else if (url.startsWith('/calendar/days/')) json = { recordings: { [eventType]: [record] } }
      else json = { [eventType]: [record], [countdownType]: options.countdown ? [options.countdown] : [] }
      const answer = options.answer ? options.answer(url, json) : { status: 200, json, next: '' }
      state.answers[key] = answer
    } else {
      return Object.assign(next, { reads, form: next.write ? new URLSearchParams(next.write.body) : null })
    }
  }
  throw new Error('Plan did not finish')
}
function field(result, name) {
  assert.ok(result.write, result.error)
  return result.form.get('calendar_event[' + name + ']')
}
function create(extra = {}) {
  return { kind: 'create', request: Object.assign({ title: 'Dinner; $(echo private)', date: '2027-12-31',
    timeZone: 'Europe/Berlin', startTime: '10:00', endTime: '11:30', calendarId: 7,
    location: 'Café <Luna> & friends', remind: '30m' }, extra) }
}

test('creating an event sends literal text only in the request body', () => {
  const r = run(create())
  assert.equal(r.write.method, 'POST')
  assert.equal(r.write.path, '/calendar/events.json')
  assert.equal(field(r, 'summary'), 'Dinner; $(echo private)')
  assert.equal(field(r, 'location'), 'Café <Luna> & friends')
  assert.equal(field(r, 'starts_at_time'), '10:00:00')
  assert.equal(field(r, 'starts_at_time_zone_name'), 'Europe/Berlin')
  assert.deepEqual(r.form.getAll('timed_reminder_durations[]'), ['1800'])
})
test('an omitted calendar uses the first owned normal calendar', () => {
  assert.equal(field(run(create({ calendarId: 0 })), 'calendar_id'), '7')
})
test('multi-day all-day events keep their inclusive last day and reminders', () => {
  const r = run(create({ allDay: true, date: '2027-12-29', endDate: '2027-12-31' }))
  assert.equal(field(r, 'all_day'), '1')
  assert.equal(field(r, 'ends_at'), '2027-12-31')
  assert.equal(field(r, 'starts_at_time'), null)
  assert.deepEqual(r.form.getAll('all_day_reminder_durations[]'), ['1800'])
})
test('each end keeps its own zone, including red-eyes and explicit multi-day spans', () => {
  let r = run(create({ startTime: '10:00', endTime: '13:00', endTimeZone: 'America/New_York' }))
  assert.equal(field(r, 'ends_at_time'), '13:00:00')
  assert.equal(field(r, 'ends_at_time_zone_name'), 'America/New_York')
  r = run(create({ startTime: '22:00', endTime: '06:00', timeZone: 'America/New_York', endTimeZone: 'Europe/Berlin' }))
  assert.equal(field(r, 'ends_at'), '2028-01-01')
  r = run(create({ endDate: '2028-01-02', endTimeZone: 'America/New_York' }))
  assert.equal(field(r, 'ends_at'), '2028-01-02')
})
test('the default duration is an hour and ignores an unused end zone', () => {
  const r = run(create({ endTime: '', endTimeZone: 'Asia/Tokyo' }))
  assert.equal(field(r, 'ends_at_time'), '11:00:00')
  assert.equal(field(r, 'ends_at_time_zone_name'), 'Europe/Berlin')
})
test('title edits keep both stored times and their zones', () => {
  const r = run(edit({ title: 'New title' }))
  assert.equal(r.write.method, 'PATCH')
  assert.equal(r.write.path, '/calendar/events/41.json')
  assert.equal(field(r, 'summary'), 'New title')
  assert.equal(field(r, 'starts_at'), '2027-12-31')
  assert.equal(field(r, 'starts_at_time'), '10:00:00')
  assert.equal(field(r, 'ends_at_time'), '11:30:00')
  assert.equal(field(r, 'starts_at_time_zone_name'), 'Europe/Berlin')
  assert.equal(field(r, 'ends_at_time_zone_name'), 'Europe/Berlin')
  assert.ok(r.reads.some(url => url.includes('starts_on=2027-12-30')), 'read the known event day beyond the old one-year limit')
})
test('title edits preserve every existing reminder', () => {
  const r = run(edit({ title: 'New title' }))
  assert.deepEqual(r.form.getAll('timed_reminder_durations[]'), ['1800', '86400'])
})
test('title and location edits preserve literal note text, escaping HTML', () => {
  const record = event({ description: 'Bring <samples> & tea\nSecond line' })
  for (const changes of [{ title: 'New title' }, { location: 'New place' }]) {
    assert.equal(field(run(edit(changes, record), record), 'description'), 'Bring &lt;samples&gt; &amp; tea<br>Second line')
  }
})
test('title edits preserve the location; location edits preserve the title', () => {
  assert.equal(field(run(edit({ title: 'New title' })), 'location'), 'Old place')
  assert.equal(field(run(edit({ location: 'New place' })), 'summary'), 'Original')
})
test('unrelated edits preserve the event link and attached email', () => {
  const r = run(edit({ title: 'New title' }))
  assert.equal(field(r, 'url'), 'https://example.com/meeting')
  assert.equal(field(r, 'entry_id'), '123')
  assert.equal(field(r, 'attendance_email_addresses][]'), null)
  assert.equal(field(r, 'highlighted'), null)
})
test('all-day edits keep dates and use the all-day reminder list', () => {
  const record = event({ all_day: true, starts_at: '2027-12-29T00:00:00Z', ends_at: '2027-12-31T00:00:00Z' })
  const job = edit({ title: 'Trip' }, record)
  job.request.event.startMs = null
  job.request.event.startsAt = record.starts_at
  const r = run(job, record)
  assert.ok(r.reads.some(url => url.includes('starts_on=2027-12-28')))
  assert.equal(field(r, 'starts_at'), '2027-12-29')
  assert.equal(field(r, 'ends_at'), '2027-12-31')
  assert.deepEqual(r.form.getAll('all_day_reminder_durations[]'), ['1800', '86400'])
})
test('an explicit reminder replaces the list', () => {
  assert.deepEqual(run(edit({ remind: '1h' })).form.getAll('timed_reminder_durations[]'), ['3600'])
})
test('zoneless event times stay at their instants', () => {
  const record = event({ starts_at_time_zone: '', ends_at_time_zone: '' })
  const r = run(edit({ title: 'New title' }, record), record)
  assert.equal(field(r, 'starts_at_time'), '09:00:00')
  assert.equal(field(r, 'set_time_zone'), '0')
})
test('a whole-series title edit leaves recurrence and guests alone', () => {
  const record = event({ recurring: true, recurrence_schedule: { preset: 'every_week' } })
  const r = run(edit({ title: 'Weekly' }, record), record)
  assert.equal(r.form.get('repeat_frequency'), null)
  assert.ok(!r.write.body.includes('attendance_email_addresses'))
})
test('an occurrence edit preserves repetition, notes, reminders and highlight', () => {
  const record = event({ recurring: true, recurrence_schedule: { preset: 'every_week' }, highlighted: true, description: 'Keep me' })
  const job = edit({ title: 'This day' }, record, 'one')
  job.request.event.occurrenceId = '41_2027-12-31'
  const r = run(job, record)
  assert.equal(r.write.path, '/calendar/events/41/occurrences/2027-12-31.json')
  assert.equal(r.form.get('repeat_frequency'), 'custom')
  assert.equal(r.form.get('apply_to_future'), '0')
  assert.equal(field(r, 'description'), 'Keep me')
  assert.equal(field(r, 'highlighted'), '1')
  assert.deepEqual(r.form.getAll('timed_reminder_durations[]'), ['1800', '86400'])
})
test('countdowns are resent or the edit refuses to destroy them', () => {
  const countdown = { parent_id: 41, label: '2 days before', starts_at: '2027-12-29T00:00:00Z', ends_at: '2027-12-31T09:00:00Z' }
  let r = run(edit({ title: 'New title' }), event(), { countdown })
  assert.ok(r.write, r.error)
  assert.equal(r.form.get('countdown_interval_duration_value'), '2')
  assert.equal(r.form.get('countdown_interval_duration_unit'), '86400')
  r = run(edit({ title: 'New title' }), event(), { countdown: { ...countdown, label: 'Unreadable' } })
  assert.match(r.error, /countdown/)
  assert.equal(r.write, undefined)
})
test('ambiguous stored times and sub-minute instants refuse silent movement', () => {
  for (const start of ['2027-10-31T01:30:00Z', '2027-12-31T09:00:30Z']) {
    const record = event({ starts_at: start, ends_at: new Date(Date.parse(start) + 3600000).toISOString() })
    assert.match(run(edit({ title: 'New title' }, record), record).error, /Retype/)
  }
})
test('paginated reads continue, and failed or repeated pages never write', () => {
  const r = run(edit({ title: 'New title' }), event(), { answer(url, json) {
    if (url.includes('starts_on=2027-12-30') && !url.includes('page=')) return { status: 200, json: { [eventType]: [{ id: 999 }] }, next: 'next' }
    return { status: 200, json, next: '' }
  } })
  assert.ok(r.write, r.error)
  assert.ok(r.reads.some(url => url.includes('page=next')))
  assert.ok(run(edit({ title: 'New title' }), event(), { answer() { return { status: 500, json: null, next: '' } } }).error)
  assert.match(run(edit({ title: 'New title' }), event(), { answer(url, json) { return { status: 200, json, next: 'same' } } }).error, /same page/)
})
test('track names are JSON body data, including Unicode and shell syntax', () => {
  const r = run({ kind: 'renameTrack', id: '123', name: 'Private & café $(whoami)' })
  assert.equal(r.write.path, '/calendar/time_tracks/123.json')
  assert.equal(JSON.parse(r.write.body).calendar_time_track.category_title, 'Private & café $(whoami)')
})
test('no write command can contain event text or time-track names', () => {
  assert.equal(Backend.createCommand, undefined)
  assert.equal(Backend.editCommand, undefined)
  assert.equal(Backend.trackRenameCommand, undefined)
  const privateText = 'private-note-canary'
  const commands = [Api.sessionCommand(false), Api.sessionCommand(true), Backend.deleteCommand({ seriesId: '41', title: privateText }),
    Backend.trackStartCommand(), Backend.trackStopCommand(), Backend.trackDeleteCommand('123')]
  for (const command of commands) assert.ok(!command.join('\n').includes(privateText))
  for (const filename of ['BarWidget.qml', 'QuickAdd.qml']) {
    const source = fs.readFileSync(path.join(__dirname, '..', filename), 'utf8')
    assert.ok(source.includes('writer.heyCreate('))
    assert.ok(!/(Backend|Hey)\.(createCommand|editCommand|trackRenameCommand)/.test(source))
  }
  assert.ok(fs.readFileSync(path.join(__dirname, '..', 'Writer.qml'), 'utf8').includes('apiWriter.create('))
})
test('session parsing rejects cleartext remote servers and malformed tokens', () => {
  assert.deepEqual(Api.parseSession('\nexample-token'), { baseUrl: 'https://app.hey.com', token: 'example-token' })
  assert.ok(Api.parseSession('http://example.com\ntoken').error)
  assert.ok(Api.parseSession('https://app.hey.com\ntoken\nInjected: header').error)
  assert.ok(Api.parseSession('https://app.hey.com\n').error)
  assert.ok(Api.parseSession('https://app.hey.com@evil.example\ntoken').error)
})
test('bad responses and denied moves are not reported as success', () => {
  assert.equal(Api.answer(200, 'not json', '').json, null)
  assert.equal(Api.answer(200, 'x'.repeat(Api.responseByteLimit + 1), '').json, null)
  assert.equal(Api.writeResult({ movedTo: '7' }, 200, '{"calendar":{"id":8}}').ok, false)
  for (const status of [0, 401, 403, 404, 422, 429, 500]) assert.equal(Api.writeResult({}, status, '{}').ok, false)
  assert.equal(Api.nextPage('<https://app.hey.com/x?page=abc%2Bdef>; rel="next"'), 'abc+def')
})
console.log(`ok HTTP writes [${process.env.TZ || 'local'}]: ${count} cases`)
