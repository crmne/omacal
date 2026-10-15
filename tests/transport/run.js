// Optional integration test: node tests/transport/run.js (needs Quickshell).
// Uses a localhost HEY fixture and a fake hey executable; never real credentials.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const http = require('node:http')
const { spawn } = require('node:child_process')
const scratchRoot = path.join(os.homedir(), '.cache', 'omacal-tests')
fs.mkdirSync(scratchRoot, { recursive: true })
const scratch = fs.mkdtempSync(path.join(scratchRoot, 'transport-'))
let rejected = false
const writes = []
let failure
const server = http.createServer(async (req, res) => {
  try {
    assert.equal(req.headers.authorization, 'Bearer synthetic-token')
    if (!rejected) { rejected = true; res.writeHead(401); res.end('{}'); return }
    let body = ''
    for await (const chunk of req) body += chunk
    let response = {}
    if (req.method !== 'GET') writes.push({ method: req.method, path: req.url, body })
    if (req.url === '/calendars.json') response = { calendars: [{ calendar: { id: 7, owned: true, kind: 'normal' } }] }
    else if (req.url.startsWith('/calendars/7/recordings.json?')) response = { 'Calendar::Event': [{ id: 41,
      title: 'Original', starts_at: '2027-12-31T09:00:00Z', ends_at: '2027-12-31T10:30:00Z',
      starts_at_time_zone: 'Europe/Berlin', ends_at_time_zone: 'Europe/Berlin', calendar: { id: 7 },
      location: 'Original place', description: 'Literal <notes> & tea', url: 'https://example.com',
      attached_entry: { id: 88 }, reminders: [{ duration: 1800 }] }] }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(response))
  } catch (error) { failure = error; res.writeHead(500); res.end('{}') }
})
server.listen(0, '127.0.0.1', async () => {
  try {
    fs.copyFileSync(path.join(__dirname, 'shell.qml'), path.join(scratch, 'shell.qml'))
    fs.symlinkSync(path.resolve(__dirname, '../..'), path.join(scratch, 'plugin'))
    for (const name of ['Commons', 'Ui']) fs.symlinkSync(path.join(process.env.OMARCHY_PATH || '/usr/share/omarchy', 'shell', name), path.join(scratch, name))
    fs.writeFileSync(path.join(scratch, 'hey'), `#!/bin/bash\ncase "$1 $2" in\n'config show') printf '{"data":[{"key":"base_url","value":"%s"}]}' "$OMACAL_TEST_URL";;\n'auth token') printf synthetic-token;;\n'auth refresh') touch "$OMACAL_TEST_REFRESH";;\n*) exit 1;;\nesac\n`, { mode: 0o700 })
    const child = spawn('quickshell', ['-p', scratch, '--no-color'], { env: { ...process.env,
      PATH: scratch + ':' + process.env.PATH, QT_QPA_PLATFORM: 'offscreen',
      OMACAL_TEST_URL: `http://127.0.0.1:${server.address().port}`, OMACAL_TEST_REFRESH: path.join(scratch, 'refreshed') } })
    let output = ''
    child.stdout.on('data', data => { output += data })
    child.stderr.on('data', data => { output += data })
    const timer = setTimeout(() => child.kill('SIGKILL'), 20000)
    const code = await new Promise((resolve, reject) => { child.on('exit', resolve); child.on('error', reject) })
    clearTimeout(timer)
    if (failure) throw failure
    assert.equal(code, 0, output)
    assert.match(output, /TRANSPORT PASSED/)
    assert.ok(fs.existsSync(path.join(scratch, 'refreshed')), 'a 401 renews the token')
    assert.equal(writes.length, 3)
    assert.equal(writes[0].method, 'POST')
    const created = new URLSearchParams(writes[0].body)
    assert.equal(created.get('calendar_event[summary]'), 'Synthetic event')
    assert.equal(created.get('calendar_event[starts_at_time_zone_name]'), 'Europe/Berlin')
    assert.equal(writes[1].method, 'PATCH')
    const edited = new URLSearchParams(writes[1].body)
    assert.equal(edited.get('calendar_event[summary]'), 'Updated synthetic event')
    assert.equal(edited.get('calendar_event[description]'), 'Literal &lt;notes&gt; &amp; tea')
    assert.equal(edited.get('calendar_event[entry_id]'), '88')
    assert.equal(edited.get('timed_reminder_durations[]'), '1800')
    assert.equal(edited.get('calendar_event[starts_at_time]'), '10:00:00')
    assert.equal(writes[2].method, 'PUT')
    assert.equal(JSON.parse(writes[2].body).calendar_time_track.category_title, 'Synthetic track')
    console.log('ok QML transport: create, edit, rename, binary time-zone files and 401 retry')
  } catch (error) { console.error(error); process.exitCode = 1 }
  finally { server.close(); fs.rmSync(scratch, { recursive: true, force: true }) }
})
