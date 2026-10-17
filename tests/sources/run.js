// Optional integration test: node tests/sources/run.js (needs Quickshell).
// The real bar widget reads HEY (a fake hey), Google (a fake gws and a
// localhost Calendar API) and a feed (served on localhost) at once, then
// creates, edits and deletes a Google event. Never real credentials.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const http = require('node:http')
const { spawn } = require('node:child_process')

const scratchRoot = path.join(os.homedir(), '.cache', 'omacal-tests')
fs.mkdirSync(scratchRoot, { recursive: true })
const scratch = fs.mkdtempSync(path.join(scratchRoot, 'sources-'))
const writes = []
let failure

const primary = { id: 'cal@example.test', summary: 'Work', accessRole: 'owner', selected: true, primary: true,
  backgroundColor: '#9fc6e7', defaultReminders: [{ method: 'popup', minutes: 30 }] }
const calendars = [primary,
  { id: 'hidden@example.test', summary: 'Hidden', accessRole: 'owner', backgroundColor: '#000000' },
  { id: 'holidays@example.test', summary: 'Holidays', accessRole: 'reader', selected: true, backgroundColor: '#16a765' }]
const stored = new Map()

function eventsFor(calendarId, timeMin) {
  const day = timeMin.substring(0, 10)
  if (calendarId === 'holidays@example.test')
    return [{ id: 'holiday', summary: 'Holiday', start: { date: day }, end: { date: day } }]
  return [
    { id: 'meeting', summary: 'Guest meeting', start: { dateTime: day + 'T12:00:00Z' }, end: { dateTime: day + 'T13:00:00Z' },
      organizer: { email: 'someone@example.test' }, attendees: [{ email: 'someone@example.test' }, { email: primary.id, self: true, responseStatus: 'accepted' }],
      hangoutLink: 'https://meet.google.com/abc-defg-hij', reminders: { useDefault: true } },
    ...[...stored.values()]
  ]
}

const server = http.createServer(async (req, res) => {
  try {
    let body = ''
    for await (const chunk of req) body += chunk
    const url = new URL(req.url, 'http://localhost')
    const send = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(value === undefined ? '' : JSON.stringify(value)) }
    if (url.pathname === '/feed.ics') {
      res.writeHead(200, { 'Content-Type': 'text/calendar', ETag: '"v1"' })
      res.end(['BEGIN:VCALENDAR', 'VERSION:2.0', 'X-WR-CALNAME:Synthetic feed', 'BEGIN:VEVENT', 'UID:weekly@example.test',
        'DTSTART;TZID=Europe/Berlin:20260105T080000', 'DTEND;TZID=Europe/Berlin:20260105T083000',
        'RRULE:FREQ=DAILY', 'SUMMARY:Daily feed event', 'END:VEVENT', 'END:VCALENDAR', ''].join('\r\n'))
      return
    }
    if (url.pathname === '/token') {
      assert.equal(new URLSearchParams(body).get('refresh_token'), 'synthetic-refresh')
      return send(200, { access_token: 'synthetic-access', expires_in: 3600 })
    }
    assert.equal(req.headers.authorization, 'Bearer synthetic-access')
    let match
    if (url.pathname === '/users/me/calendarList') return send(200, { items: calendars })
    if ((match = /^\/users\/me\/calendarList\/([^/]+)$/.exec(url.pathname))) {
      const found = calendars.find(c => c.id === decodeURIComponent(match[1]))
      return found ? send(200, found) : send(404, { error: { code: 404 } })
    }
    if ((match = /^\/calendars\/([^/]+)\/events$/.exec(url.pathname))) {
      const calendarId = decodeURIComponent(match[1])
      if (req.method === 'GET') {
        assert.equal(url.searchParams.get('singleEvents'), 'true')
        return send(200, { items: eventsFor(calendarId, url.searchParams.get('timeMin')) })
      }
      const event = JSON.parse(body)
      writes.push({ method: req.method, path: url.pathname, query: url.search, body: event })
      const made = { ...event, id: 'made' + (stored.size + 1), organizer: { self: true }, status: 'confirmed' }
      stored.set(made.id, made)
      return send(200, made)
    }
    if ((match = /^\/calendars\/([^/]+)\/events\/([^/]+)$/.exec(url.pathname))) {
      const id = decodeURIComponent(match[2])
      const event = stored.get(id) || (id === 'meeting' ? eventsFor(primary.id, '2026-01-01')[0] : null)
      if (!event) return send(404, { error: { code: 404 } })
      if (req.method === 'GET') return send(200, event)
      writes.push({ method: req.method, path: url.pathname, query: url.search, body: body ? JSON.parse(body) : null })
      if (req.method === 'PATCH') { const next = { ...event, ...JSON.parse(body) }; stored.set(id, next); return send(200, next) }
      if (req.method === 'DELETE') { stored.delete(id); res.writeHead(204); res.end(); return }
    }
    send(404, { error: { code: 404 } })
  } catch (error) { failure = failure || error; res.writeHead(500); res.end('{}') }
})

server.listen(0, '127.0.0.1', async () => {
  const base = `http://127.0.0.1:${server.address().port}`
  try {
    fs.copyFileSync(path.join(__dirname, 'shell.qml'), path.join(scratch, 'shell.qml'))
    fs.symlinkSync(path.resolve(__dirname, '../..'), path.join(scratch, 'plugin'))
    for (const name of ['Commons', 'Ui']) fs.symlinkSync(path.join(process.env.OMARCHY_PATH || '/usr/share/omarchy', 'shell', name), path.join(scratch, name))
    const bin = path.join(scratch, 'bin')
    fs.mkdirSync(bin)
    fs.writeFileSync(path.join(bin, 'hey'), `#!/bin/bash
case "$1 $2" in
  '--version '*) echo 'hey version 1.7.0';;
  'event week') printf '{"ok":true,"data":[{"id":41,"title":"HEY event","starts_at":"%sT09:00:00Z","ends_at":"%sT10:00:00Z","calendar":{"id":7,"name":"Work","color":"blue"}}]}' "$3" "$3";;
  'calendar list') echo '{"data":[{"id":7,"name":"Work","color":"blue","kind":"normal","owned":true}]}';;
  'timetrack current') echo '{"ok":true,"data":null}';;
  'timetrack list') echo '{"data":[]}';;
  *) exit 1;;
esac
`, { mode: 0o700 })
    fs.writeFileSync(path.join(bin, 'gws'), `#!/bin/bash
[ "$1 $2 $3" = "auth export --unmasked" ] || exit 2
echo '{"type":"authorized_user","client_id":"synthetic-client","client_secret":"synthetic-secret","refresh_token":"synthetic-refresh"}'
`, { mode: 0o700 })
    const config = path.join(scratch, 'config')
    fs.mkdirSync(path.join(config, 'omacal'), { recursive: true })
    fs.writeFileSync(path.join(config, 'omacal', 'feeds.json'), JSON.stringify({ feeds: [{ name: 'Synthetic feed', url: base + '/feed.ics' }] }), { mode: 0o600 })
    const runtime = path.join(scratch, 'runtime')
    fs.mkdirSync(runtime, { mode: 0o700 })

    const child = spawn('quickshell', ['-p', scratch, '--no-color'], { env: { ...process.env,
      PATH: bin + ':' + process.env.PATH, QT_QPA_PLATFORM: 'offscreen', XDG_CONFIG_HOME: config, XDG_RUNTIME_DIR: runtime,
      OMACAL_GOOGLE_API: base, OMACAL_GOOGLE_TOKEN_URL: base + '/token', OMACAL_TEST_LOOPBACK: '1', TZ: 'Europe/Berlin' } })
    let output = ''
    child.stdout.on('data', data => { output += data })
    child.stderr.on('data', data => { output += data })
    const timer = setTimeout(() => child.kill('SIGKILL'), 60000)
    const code = await new Promise((resolve, reject) => { child.on('exit', resolve); child.on('error', reject) })
    clearTimeout(timer)
    if (failure) throw failure
    assert.equal(code, 0, output)
    assert.match(output, /SOURCES PASSED/, output)
    assert.doesNotMatch(output, /TypeError|ReferenceError|is not a function|is not defined/, output)

    const created = writes.find(w => w.method === 'POST')
    assert.equal(created.body.summary, 'Synthetic Google event')
    assert.equal(created.body.location, 'Synthetic place')
    assert.deepEqual(created.body.start, { dateTime: created.body.start.dateTime, timeZone: 'Europe/Berlin' })
    assert.match(created.body.start.dateTime, /T10:00:00$/)
    assert.match(created.body.end.dateTime, /T11:30:00$/)
    assert.deepEqual(created.body.reminders, { useDefault: false, overrides: [{ method: 'popup', minutes: 10 }] })
    assert.match(created.query, /sendUpdates=none/)
    const edited = writes.find(w => w.method === 'PATCH')
    assert.deepEqual(edited.body, { summary: 'Edited Google event', reminders: { useDefault: false, overrides: [] } })
    assert.ok(writes.some(w => w.method === 'DELETE'))
    console.log('ok sources: HEY, Google and a feed read together; Google create, edit and delete')
  } catch (error) { console.error(error); process.exitCode = 1 }
  finally { server.close(); fs.rmSync(scratch, { recursive: true, force: true }) }
})
