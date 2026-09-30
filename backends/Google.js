// Google Calendar through the Google Workspace CLI. No credentials are stored here.
// helperPath is resolved by QML, so the fork can be installed in any directory.
function configured(helperPath, account) {
  function command(action, value) {
    var args = ["timeout", "-k", "3", "120", "python3", helperPath, action, String(account || "")]
    if (value !== undefined) args.push(JSON.stringify(value))
    return args
  }
  return {
    info: { id: "google", name: "Google Calendar", capabilities: {
      create: true, delete: true, watch: false, timeTracking: false, dayLink: true
    } },
    probeCommand: command("probe"),
    probe: probe,
    modeNote: function() { return "Google calendars selected in the web app. Changes are polled at the refresh interval." },
    fetchCommand: function(mode, weeks) { return command("events", weeks) },
    calendarsCommand: command("calendars"),
    createCommand: function(request) { return command("create", request) },
    deleteCommand: function(event) {
      if (!event || event.recurring || !event.writable || !event.calendarId || !event.seriesId) return []
      return command("delete", { calendarId: event.calendarId, id: event.seriesId })
    },
    writeResult: writeResult,
    dayUrl: function(day) { return dayUrl(day) + "?authuser=" + encodeURIComponent(String(account || "")) },
    watchCommand: [], currentTrackCommand: [], tracksCommand: []
  }
}

function probe(output) {
  try {
    var value = JSON.parse(String(output || ""))
    if (value.ok === true) return { mode: "google", version: "", error: "" }
    if (value.error) return { mode: "", version: "", error: String(value.error) }
  } catch (e) {}
  return { mode: "", version: "", error: "Google Calendar could not start. Install python3 and gws, then run gws auth login." }
}

function writeResult(exitCode, output) {
  try {
    var value = JSON.parse(String(output || ""))
    if (exitCode === 0 && value.ok === true) return { ok: true, message: "" }
    if (value.error) return { ok: false, message: String(value.error) }
  } catch (e) {}
  return { ok: false, message: "Google Calendar did not confirm the change. Refresh before retrying." }
}

function dayUrl(day) {
  return /^\d{4}-\d{2}-\d{2}$/.test(String(day || ""))
    ? "https://calendar.google.com/calendar/r/day/" + day.replace(/-/g, "/")
    : "https://calendar.google.com/"
}

if (typeof module !== "undefined") module.exports = { configured: configured, probe: probe, writeResult: writeResult, dayUrl: dayUrl }
