const assert = require('node:assert/strict')
const fs = require('node:fs')
const Zones = require('../TimeZones.js')
const names = ['Europe/Berlin', 'America/New_York', 'Asia/Tokyo', 'Pacific/Kiritimati', 'Australia/Sydney', 'Australia/Lord_Howe', 'Asia/Kathmandu', 'Africa/Casablanca', 'Europe/Dublin']
let cases = 0
for (const name of names) {
  const zone = Zones.parse(fs.readFileSync(Zones.zonePath(name)))
  assert.ok(zone, name)
  const formatter = new Intl.DateTimeFormat('en-CA', { timeZone: name, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' })
  for (const year of [2026, 2027, 2040, 2100]) {
    for (let month = 0; month < 12; month++) {
      const instant = Date.UTC(year, month, 15, 12, 34)
      const parts = Object.fromEntries(formatter.formatToParts(instant).map(p => [p.type, p.value]))
      const wall = zone.wall(instant)
      assert.equal(wall.date, `${parts.year}-${parts.month}-${parts.day}`, `${name} ${year}`)
      assert.equal(wall.clock, `${parts.hour}:${parts.minute}`, `${name} ${year}`)
      assert.equal(zone.place(wall.date, wall.clock), instant, `${name} ${year}`)
      cases++
    }
  }
}
const berlin = Zones.parse(fs.readFileSync(Zones.zonePath('Europe/Berlin')))
assert.equal(new Date(berlin.place('2027-03-28', '02:30')).toISOString(), '2027-03-28T01:30:00.000Z')
assert.equal(new Date(berlin.place('2027-10-31', '02:30')).toISOString(), '2027-10-31T00:30:00.000Z')
assert.equal(Zones.parse(new Uint8Array([1, 2, 3])), null)
for (const name of ['../secret', 'Europe/../../secret', '/etc/passwd', 'right/UTC', 'localtime', 'Local']) assert.equal(Zones.zonePath(name), '')
console.log(`ok time zones [${process.env.TZ || 'local'}]: ${cases} round trips`)
