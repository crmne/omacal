const assert = require('node:assert/strict')
const Cal = require('../Calendar.js')
const now = new Date(2026, 8, 29, 11, 42).getTime()
const meeting = Cal.normalizeEvent({id: 1, title: 'Today meeting',
  starts_at: new Date(2026, 8, 29, 13).toISOString(), ends_at: new Date(2026, 8, 29, 14).toISOString()})
const birthday = Cal.normalizeEvent({id: 2, title: 'Future birthday', all_day: true,
  starts_at: '2026-10-02', ends_at: '2026-10-03', reminders: [new Date(now - 60000).toISOString()]})
const events = [birthday, meeting]
const today = Cal.indexByDay(events)['2026-09-29']
for (const mode of ['soon', 'name', 'time', 'next']) {
  // Omitted and false both preserve original reminder-based behavior.
  assert.deepEqual(Cal.barSelection(mode, events, today, now, 15), [birthday])
  assert.deepEqual(Cal.barSelection(mode, events, today, now, 15, false), [birthday])
  assert.deepEqual(Cal.barSelection(mode, events, today, now, 15, true), [meeting])
  assert.deepEqual(Cal.barSelection(mode, [birthday], [], now, 15, true), [])
  assert.deepEqual(Cal.barSelection(mode, events, today, meeting.endMs, 15, true), [])
}
assert.deepEqual(Cal.barSelection('off', events, today, now, 15, true), [])
assert.deepEqual(Cal.barSelection('off', events, today, now, 15, false), [])
assert.deepEqual(Cal.barSelection('soon', [meeting], today, now, 15, false), [])
assert.deepEqual(Cal.barSelection('next', [meeting], today, now, 15, false), [meeting])
// Notifications still include future events with reminders due now.
assert.equal(Cal.dueReminders(events, now, now - 120000, {}).length, 1)
const holiday = Cal.normalizeEvent({id: 3, title: 'Today holiday', all_day: true,
  starts_at: '2026-09-29', ends_at: '2026-09-30', reminders: [new Date(now - 3600000).toISOString()]})
assert.deepEqual(Cal.barSelection('name', [holiday, meeting], [holiday, meeting], now, 15, true), [meeting])
assert.deepEqual(Cal.barSelection('name', [holiday], [holiday], now, 15, true), [holiday])
holiday.reminders = []
assert.deepEqual(Cal.barSelection('name', [holiday], [holiday], now, 15, true), [holiday])
const overnight = Cal.normalizeEvent({id: 4, title: 'Overnight',
  starts_at: new Date(2026, 8, 28, 23, 30).toISOString(), ends_at: new Date(2026, 8, 29, 1, 30).toISOString()})
const declined = {...meeting, status: 'declined'}
const overnightToday = Cal.indexByDay([overnight, declined])['2026-09-29']
assert.deepEqual(Cal.barSelection('name', [overnight, declined], overnightToday,
  new Date(2026, 8, 29, 0, 30).getTime(), 15, true), [overnight])
assert.deepEqual(Cal.barSelection('name', [overnight, declined], overnightToday, now, 15, true), [])
console.log('Today-only and original behavior tests passed')
