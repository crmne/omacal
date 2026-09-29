const assert = require('node:assert/strict')
const Cal = require('../Calendar.js')
const Google = require('../backends/Google.js')
const backend = Google.configured('/tmp/a folder/google.py', 'calendar@example.test')

const id = 'event'.repeat(80)
const raw = { id, occurrence_id: id, calendar_id: 'team@example.test',
  title: 'Meeting', starts_at: '2026-09-28T09:00:00-05:00', ends_at: '2026-09-28T10:00:00-05:00', writable: true }
const event = Cal.normalizeEvent(raw)
assert.equal(event.seriesId, id)
assert.equal(event.calendarId, raw.calendar_id)
assert.notEqual(event.key, Cal.normalizeEvent({...raw, calendar_id: 'other@example.test'}).key)
assert.equal(Cal.mergeWeeks({a: {events: [event]}, b: {events: [event]}}).length, 1)
const calendars = Cal.parseCalendars(JSON.stringify([
  {id: 'team@example.test', name: 'Team', owned: true},
  {id: 'holidays@example.test', name: 'Holidays', owned: false},
  {id: 7, name: 'HEY', owned: true}
]))
assert.deepEqual(Cal.writableCalendars(calendars).map(c => c.id), ['team@example.test', 7])
const request = Cal.validateEvent({title: '"; touch /tmp/not-executed; #', date: '2026-09-28', allDay: true,
  calendarId: 'team@example.test'}).request
assert.equal(request.calendarId, 'team@example.test')
const argv = backend.createCommand(request)
assert.equal(argv[5], '/tmp/a folder/google.py')
assert.equal(argv[6], 'create')
assert.equal(argv[7], 'calendar@example.test')
assert.deepEqual(JSON.parse(argv[8]), request)
assert.equal(backend.info.capabilities.watch, false)
assert.equal(backend.info.capabilities.timeTracking, false)
assert.deepEqual(backend.deleteCommand({...event, recurring: true}), [])
assert.deepEqual(backend.deleteCommand({...event, writable: false}), [])
assert.equal(JSON.parse(backend.deleteCommand(event)[8]).id, id)
assert.equal(Google.probe('{"ok":true}').mode, 'google')
assert.equal(Google.probe('{"ok":false,"error":"Wrong account"}').error, 'Wrong account')
assert.equal(Google.probe('garbage').mode, '')
assert.equal(Google.writeResult(1, '{"ok":true}').ok, false)
assert.equal(Google.writeResult(0, '{"ok":true}').ok, true)
assert.match(Google.dayUrl('2026-09-28'), /2026\/09\/28$/)
const allDay = Cal.normalizeEvent({...raw, all_day: true, starts_at: '2026-09-28', ends_at: '2026-09-30'})
assert.deepEqual(Cal.eventDayKeys(allDay), ['2026-09-28', '2026-09-29'])
console.log('Google model and command tests passed')
