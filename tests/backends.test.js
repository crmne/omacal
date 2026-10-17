// Plain node, no dependencies: the Google and feed backends' commands.
const assert = require('node:assert/strict')
const Google = require('../backends/Google.js')
const Feeds = require('../backends/Feeds.js')

let count = 0
function test(name, fn) {
  try { fn(); count++ } catch (error) { console.error(name); throw error }
}

const context = { dir: '/plugins/omacal/' }
const privateText = 'private-note-canary'

test('Google writes carry what was typed on stdin, never in the command', () => {
  const create = Google.writeCommand('create', { title: privateText, location: privateText, date: '2026-10-19' }, context)
  assert.ok(!create.command.join('\n').includes(privateText))
  assert.equal(JSON.parse(create.input).request.title, privateText)
  assert.deepEqual(create.command.slice(-3), ['-I', '/plugins/omacal/backends/google.py', 'write'])
  const edit = Google.writeCommand('edit', { event: { seriesId: 'g1', title: privateText, location: privateText, calendarId: 'a@example.com' },
    scope: 'all', changes: { title: privateText } }, context)
  assert.ok(!edit.command.join('\n').includes(privateText))
  const sent = JSON.parse(edit.input).request
  assert.equal(sent.event.title, undefined, 'the event is named, not copied')
  assert.equal(sent.event.calendarId, 'a@example.com')
  assert.equal(sent.changes.title, privateText)
  const removal = Google.writeCommand('delete', { event: { seriesId: 'g1', title: privateText } }, context)
  assert.ok(!(removal.command.join('\n') + removal.input).includes(privateText))
  assert.deepEqual(Google.writeCommand('nonsense', {}, context).command, [])
})

test('Google reads name only weeks', () => {
  const command = Google.fetchCommand('api', ['2026-10-19', 'rm -rf ~', '2026-10-19', '2026-10-26'], context)
  assert.deepEqual(command.slice(-3), ['weeks', '2026-10-19', '2026-10-26'])
  assert.equal(command[0], 'timeout')
})

test('Google answers are read as what they are', () => {
  assert.deepEqual(Google.probe('{"ok":true,"account":"me@example.com"}\n'), { mode: 'api', version: '', account: 'me@example.com', error: '' })
  const missing = Google.probe('{"ok":false,"error":"gws is not installed.","missing":true}')
  assert.equal(missing.mode, '')
  assert.equal(missing.missing, true)
  assert.ok(Google.probe('Traceback (most recent call last)').error)
  assert.deepEqual(Google.writeResult(0, '{"ok":true,"message":"Event created"}'), { ok: true, message: 'Event created' })
  assert.equal(Google.writeResult(1, '{"ok":false,"error":"This event has guests."}').message, 'This event has guests.')
  assert.equal(Google.writeResult(1, '{"ok":true}').ok, false, 'a failed exit is not a success')
  assert.equal(Google.writeResult(0, '').ok, false)
})

test('Google deletes only one-off events it lets you change', () => {
  assert.ok(Google.canDelete({ seriesId: 'g1', calendarId: 'a', recurring: false }))
  assert.ok(!Google.canDelete({ seriesId: 'g1', calendarId: 'a', recurring: true }))
  assert.ok(!Google.canDelete({ seriesId: 'g1', calendarId: 'a', editable: false }))
  assert.ok(!Google.canDelete({ seriesId: '', calendarId: 'a' }))
})

test("Google's day page opens as the account OmaCal reads", () => {
  assert.equal(Google.dayUrl('2026-10-19', 'me@example.com'), 'https://calendar.google.com/calendar/r/day/2026/10/19?authuser=me%40example.com')
  assert.equal(Google.dayUrl('bad', ''), 'https://calendar.google.com/calendar/r')
})

test('a feed address goes on stdin; a feed is named by its id', () => {
  const url = 'https://calendar.google.com/calendar/ical/secret-canary/basic.ics'
  const add = Feeds.addCommand('Family', url, context)
  assert.ok(!add.command.join('\n').includes('secret-canary'))
  assert.equal(JSON.parse(add.input).url, url)
  assert.deepEqual(Feeds.removeCommand('f0123456789abcdef', context).command.slice(-2), ['remove', 'f0123456789abcdef'])
  assert.deepEqual(Feeds.removeCommand('../../etc', context).command, [])
  assert.ok(Feeds.isFeedAddress('webcal://p01-calendars.icloud.com/published/2/x'))
  assert.ok(!Feeds.isFeedAddress('file:///etc/passwd'))
  assert.ok(!Feeds.isFeedAddress('http://example.com/cal.ics'))
})

test('feeds are read only, and no feeds is nothing to say', () => {
  assert.equal(Feeds.info.capabilities.create, false)
  assert.equal(Feeds.canDelete({}), false)
  assert.deepEqual(Feeds.writeCommand('create', {}).command, [])
  assert.equal(Feeds.probe('{"ok":false,"quiet":true,"error":"No calendar feeds yet."}').quiet, true)
  assert.equal(Feeds.probe('{"ok":false,"quiet":true}').error, '')
  assert.equal(Feeds.probe('{"ok":true,"feeds":2}').mode, 'ics')
  const listed = Feeds.parseList('[{"id":"f0123456789abcdef","name":"Holidays","host":"example.com"},{"id":"bad"}]')
  assert.deepEqual(listed, [{ id: 'f0123456789abcdef', name: 'Holidays', color: '', host: 'example.com' }])
})

console.log(`ok backends [${process.env.TZ || 'local'}]: ${count} cases`)
