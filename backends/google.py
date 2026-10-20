#!/usr/bin/env python3
"""Calendar for Omarchy's Google Calendar helper (backends/Google.js runs it).

Reads Google calendars and events and prints them in Calendar for Omarchy's standard
shapes (see "Backends" at the top of Calendar.js); creates, edits and
deletes events. Signing in is gws's, the Google Workspace CLI: its saved
sign-in comes from `gws auth export --unmasked` over a pipe, is turned into
an access token here, and both stay in this process's memory. Nothing is
written to disk.

What you typed (a title, a place) arrives on stdin, never as an argument,
and goes to Google in an HTTPS request body. The arguments are an action
and, for reading, the Mondays of the weeks wanted.

  google.py probe              {"ok": true, "account": "you@example.com"}
  google.py calendars          [{id, name, color, kind, owned}]
  google.py weeks KEY...       one {"week", "events"} line per week
  google.py write < request    {"ok": true, "message": ...}

Every failure prints {"ok": false, "error": ...} with a sentence for the
panel, and never Google's response, a token or an event's text.

The first version of this backend was written by David Paluy (PR #2).
"""
import concurrent.futures
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

API = "https://www.googleapis.com/calendar/v3"
TOKEN_URL = "https://oauth2.googleapis.com/token"
OUTPUT_LIMIT = 4 * 1024 * 1024
RESPONSE_LIMIT = 8 * 1024 * 1024
INPUT_LIMIT = 256 * 1024
EVENT_LIMIT = 2000
CALENDAR_LIMIT = 100
MAX_WEEKS = 8
TIMEOUT = 20
SIGN_IN = "Run `gws auth login -s calendar` to sign in to Google."


class Failure(Exception):
    def __init__(self, message, missing=False):
        super().__init__(message)
        self.missing = missing


def local_test_url(name, default):
    # The tests point the helper at a server on this machine; nothing else
    # can be put in Google's place.
    value = os.environ.get(name, "")
    if value.startswith("http://127.0.0.1:") or value.startswith("http://localhost:"):
        return value.rstrip("/")
    return default


API = local_test_url("OMACAL_GOOGLE_API", API)
TOKEN_URL = local_test_url("OMACAL_GOOGLE_TOKEN_URL", TOKEN_URL)


# ---------------------------------------------------------------------------
# Signing in, through gws
# ---------------------------------------------------------------------------

def gws_config_dir():
    configured = os.environ.get("GOOGLE_WORKSPACE_CLI_CONFIG_DIR", "")
    if configured:
        return configured
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "gws")


def read_json_file(path):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read(65536))
    except (OSError, ValueError):
        return None


def credentials():
    """gws's saved sign-in: client id and secret, and the refresh token."""
    found = None
    named = os.environ.get("GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE", "")
    if named:
        found = read_json_file(named)
    if found is None:
        try:
            result = subprocess.run(["gws", "auth", "export", "--unmasked"], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, check=False)
        except FileNotFoundError:
            raise Failure("gws, the Google Workspace CLI, is not installed. Install googleworkspace-cli and run "
                          "`gws auth login -s calendar`.", missing=True) from None
        except subprocess.TimeoutExpired:
            raise Failure("gws did not hand over its Google sign-in. Is the keyring unlocked?") from None
        if result.returncode == 0:
            try:
                found = json.loads(result.stdout[:65536])
            except ValueError:
                found = None
    if found is None:
        # gws keeps an unencrypted sign-in here when it has no keyring.
        found = read_json_file(os.path.join(gws_config_dir(), "credentials.json"))
    if not isinstance(found, dict) or not all(isinstance(found.get(k), str) and found.get(k)
                                              for k in ("client_id", "client_secret", "refresh_token")):
        raise Failure("gws is not signed in to Google. " + SIGN_IN)
    return found


def access_token():
    creds = credentials()
    form = urllib.parse.urlencode({
        "client_id": creds["client_id"], "client_secret": creds["client_secret"],
        "refresh_token": creds["refresh_token"], "grant_type": "refresh_token",
    }).encode()
    request = urllib.request.Request(TOKEN_URL, data=form, method="POST",
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            answer = json.loads(response.read(65536))
    except urllib.error.HTTPError as error:
        if error.code in (400, 401):
            raise Failure("Google no longer accepts gws's sign-in. " + SIGN_IN) from None
        raise Failure("Google's sign-in service had a problem (HTTP %d). Try again in a moment." % error.code) from None
    except (urllib.error.URLError, OSError, ValueError):
        raise Failure("Could not reach Google. Check the connection.") from None
    token = answer.get("access_token") if isinstance(answer, dict) else None
    if not isinstance(token, str) or not token:
        raise Failure("Google did not hand over a sign-in. " + SIGN_IN)
    return token


# ---------------------------------------------------------------------------
# Google's API
# ---------------------------------------------------------------------------

class Google:
    def __init__(self):
        self.token = access_token()

    def call(self, method, path, params=None, body=None):
        url = API + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = None
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                raw = response.read(RESPONSE_LIMIT + 1)
        except urllib.error.HTTPError as error:
            raise Failure(failure(error)) from None
        except (urllib.error.URLError, OSError):
            raise Failure("Could not reach Google. Check the connection.") from None
        if len(raw) > RESPONSE_LIMIT:
            raise Failure("Google answered with more than Calendar for Omarchy will read.")
        if not raw.strip():
            return {}
        try:
            value = json.loads(raw)
        except ValueError:
            raise Failure("Google answered with something Calendar for Omarchy cannot read.") from None
        if not isinstance(value, dict):
            raise Failure("Google answered with something Calendar for Omarchy cannot read.")
        return value

    def pages(self, path, params, limit):
        items = []
        seen = set()
        params = dict(params)
        for _ in range(50):
            page = self.call("GET", path, params)
            listed = page.get("items", [])
            if not isinstance(listed, list):
                raise Failure("Google answered with something Calendar for Omarchy cannot read.")
            items.extend(item for item in listed if isinstance(item, dict))
            if len(items) > limit:
                raise Failure("Google has more there than Calendar for Omarchy will read.")
            token = page.get("nextPageToken")
            if not token:
                return items
            if token in seen:
                break
            seen.add(token)
            params["pageToken"] = token
        raise Failure("Google kept answering with more pages. Try again in a moment.")


def failure(error):
    reason = ""
    try:
        detail = json.loads(error.read(65536))
        errors = detail.get("error", {}).get("errors", [])
        reason = str(errors[0].get("reason", "")) if errors else str(detail.get("error", {}).get("status", ""))
    except (ValueError, AttributeError, OSError, IndexError, TypeError):
        pass
    code = error.code
    if code == 401:
        return "Google no longer accepts gws's sign-in. " + SIGN_IN
    if code == 403 and reason in ("insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"):
        return "gws's Google sign-in has no Calendar access. " + SIGN_IN
    if code == 403 and reason in ("rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded"):
        return "Google asked Calendar for Omarchy to slow down. Try again in a minute."
    if code == 403:
        return "Google does not let you change that event."
    if code == 404:
        return "Google no longer has that event, or does not let you see it. Refresh and try again."
    if code == 410:
        return "That event is gone from Google. Refresh and try again."
    if code == 412:
        return "The event changed in Google meanwhile. Refresh and try again."
    if code == 429:
        return "Google asked Calendar for Omarchy to slow down. Try again in a minute."
    if code >= 500:
        return "Google had a problem (HTTP %d). Try again in a moment." % code
    return "Google did not accept that (HTTP %d)." % code


def quoted(value):
    return urllib.parse.quote(str(value), safe="")


# ---------------------------------------------------------------------------
# Calendars
# ---------------------------------------------------------------------------

def writable(calendar):
    return calendar.get("accessRole") in ("owner", "writer")


def listed_calendars(google):
    """The calendars shown in Google Calendar's own list."""
    calendars = google.pages("/users/me/calendarList", {"maxResults": 250}, CALENDAR_LIMIT)
    return [c for c in calendars if isinstance(c.get("id"), str) and c.get("selected") is True
            and not c.get("hidden") and not c.get("deleted")
            and c.get("accessRole") in ("freeBusyReader", "reader", "writer", "owner")]


def calendar_name(calendar):
    return str(calendar.get("summaryOverride") or calendar.get("summary") or calendar.get("id") or "")


def project_calendar(calendar):
    return {"id": calendar["id"], "name": calendar_name(calendar),
            "color": str(calendar.get("backgroundColor") or ""),
            "kind": "primary" if calendar.get("primary") else "",
            "owned": writable(calendar)}


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

def parse_instant(value):
    parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed


def local_midnight(day):
    return dt.datetime.combine(day, dt.time()).astimezone()


def video_link(event):
    if isinstance(event.get("hangoutLink"), str) and event["hangoutLink"]:
        return event["hangoutLink"], "Google Meet"
    conference = event.get("conferenceData") or {}
    for point in conference.get("entryPoints") or []:
        if isinstance(point, dict) and point.get("entryPointType") == "video" and isinstance(point.get("uri"), str):
            name = (conference.get("conferenceSolution") or {}).get("name") or "Join"
            return point["uri"], str(name)
    return "", ""


def others_invited(event):
    return any(isinstance(a, dict) and not a.get("self") and not a.get("resource")
               for a in event.get("attendees") or [])


def editable(event, calendar):
    if not writable(calendar) or event.get("locked") or event.get("privateCopy"):
        return False
    if event.get("eventType") in ("birthday", "fromGmail"):
        return False
    organizer = event.get("organizer") or {}
    return bool(organizer.get("self")) or not others_invited(event) or bool(event.get("guestsCanModify"))


def reminder_minutes(event, calendar):
    reminders = event.get("reminders") or {}
    if reminders.get("useDefault"):
        rules = calendar.get("defaultReminders") or []
    else:
        rules = reminders.get("overrides") or []
    out = []
    for rule in rules:
        if isinstance(rule, dict) and rule.get("method") == "popup" and isinstance(rule.get("minutes"), int) \
                and 0 <= rule["minutes"] <= 40320:
            out.append(rule["minutes"])
    return out[:8]


def event_bounds(event):
    """(start, end) as aware datetimes, and whether the event is all day.
    An all-day event runs from midnight of its first day to midnight after
    its last, here."""
    start, end = event.get("start") or {}, event.get("end") or {}
    if start.get("date"):
        first = dt.date.fromisoformat(start["date"])
        after = dt.date.fromisoformat(end["date"]) if end.get("date") else first + dt.timedelta(days=1)
        if after <= first:
            after = first + dt.timedelta(days=1)
        return local_midnight(first), local_midnight(after), True
    begins = parse_instant(start["dateTime"])
    ends = parse_instant(end["dateTime"]) if end.get("dateTime") else begins
    return begins, max(ends, begins), False


def project_event(event, calendar, palette):
    """One Google event in Calendar for Omarchy's standard shape, or None to leave it out."""
    if event.get("status") == "cancelled" or event.get("eventType") == "workingLocation":
        return None
    start, end = event.get("start") or {}, event.get("end") or {}
    if not isinstance(event.get("id"), str) or not (start.get("date") or start.get("dateTime")):
        return None
    begins, _, all_day = event_bounds(event)
    if all_day:
        first = dt.date.fromisoformat(start["date"])
        after = dt.date.fromisoformat(end["date"]) if end.get("date") else first + dt.timedelta(days=1)
        last = max(first, after - dt.timedelta(days=1))
        starts_at, ends_at = first.isoformat() + "T00:00:00Z", last.isoformat() + "T00:00:00Z"
    else:
        starts_at = start["dateTime"]
        ends_at = end.get("dateTime") or start["dateTime"]
    minutes = reminder_minutes(event, calendar)
    join_url, join_title = video_link(event)
    color = calendar.get("backgroundColor") or ""
    if event.get("colorId") and event["colorId"] in palette:
        color = palette[event["colorId"]]
    series = event.get("recurringEventId") or ""
    return {
        "id": event["id"], "occurrence_id": event["id"] if series else "", "parent_id": series,
        "recurring": bool(series or event.get("recurrence")),
        "title": str(event.get("summary") or "(untitled)"),
        "all_day": all_day, "starts_at": starts_at, "ends_at": ends_at,
        "calendar_id": calendar["id"], "calendar": calendar_name(calendar), "color": str(color),
        "location": str(event.get("location") or ""), "url": str(event.get("htmlLink") or ""),
        "join_url": join_url, "join_title": join_title,
        "status": next((str(a.get("responseStatus", "")) for a in event.get("attendees") or []
                        if isinstance(a, dict) and a.get("self")), ""),
        "reminders": [(begins - dt.timedelta(minutes=m)).astimezone(dt.timezone.utc).isoformat() for m in minutes],
        "reminder_leads": [m * 60 for m in minutes],
        "editable": editable(event, calendar),
    }


def week_keys(values):
    keys = []
    for value in values:
        try:
            day = dt.date.fromisoformat(value)
        except ValueError:
            continue
        if day.isoformat() == value and day.weekday() == 0 and value not in keys:
            keys.append(value)
    return sorted(keys)[:MAX_WEEKS]


def palette_of(google, events):
    if not any(event.get("colorId") for event in events):
        return {}
    colors = google.call("GET", "/colors").get("event") or {}
    return {key: str(value.get("background", "")) for key, value in colors.items() if isinstance(value, dict)}


def read_weeks(google, keys):
    """Every listed calendar over the span the weeks cover, filed by week."""
    first = dt.date.fromisoformat(keys[0])
    last = dt.date.fromisoformat(keys[-1]) + dt.timedelta(days=7)
    lower, upper = local_midnight(first), local_midnight(last)
    calendars = listed_calendars(google)

    def read(calendar):
        return calendar, google.pages("/calendars/%s/events" % quoted(calendar["id"]), {
            "timeMin": lower.isoformat(), "timeMax": upper.isoformat(), "singleEvents": "true",
            "maxResults": 2500, "showDeleted": "false"}, EVENT_LIMIT)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        answers = list(pool.map(read, calendars))
    palette = palette_of(google, [e for _, events in answers for e in events])
    weeks = {key: [] for key in keys}
    count = 0
    for calendar, events in answers:
        for raw in events:
            event = project_event(raw, calendar, palette)
            if event is None:
                continue
            begins, ends, _ = event_bounds(raw)
            # Filed under every week it touches, the way HEY's weeks answer.
            for key in keys:
                monday = local_midnight(dt.date.fromisoformat(key))
                sunday_night = local_midnight(dt.date.fromisoformat(key) + dt.timedelta(days=7))
                if begins < sunday_night and (ends > monday or (ends == begins and begins >= monday)):
                    weeks[key].append(event)
                    count += 1
            if count > EVENT_LIMIT * 2:
                raise Failure("Google has more events there than Calendar for Omarchy will read.")
    return [{"week": key, "events": weeks[key]} for key in keys]


# ---------------------------------------------------------------------------
# Writing: times
# ---------------------------------------------------------------------------

def zone(name):
    try:
        return ZoneInfo(str(name))
    except (ValueError, KeyError, OSError):
        raise Failure("“%s” is not a time zone I know." % name) from None


def wall(day, clock, tz):
    """A date and HH:MM in a zone, refusing a time the clocks skip."""
    naive = dt.datetime.combine(dt.date.fromisoformat(day), dt.time.fromisoformat(clock))
    placed = naive.replace(tzinfo=tz)
    if placed.astimezone(dt.timezone.utc).astimezone(tz).replace(tzinfo=None) != naive:
        raise Failure("%s on %s does not exist there: the clocks change. Pick another time." % (clock, day))
    return placed


def google_time(moment, tz_name):
    return {"dateTime": moment.replace(tzinfo=None).isoformat(timespec="seconds"), "timeZone": tz_name, "date": None}


def schedule_body(s, date, end_date):
    """Google's start and end for Calendar for Omarchy's schedule, on these days."""
    if s.get("allDay"):
        last = max(dt.date.fromisoformat(end_date), dt.date.fromisoformat(date))
        return ({"date": date, "dateTime": None, "timeZone": None},
                {"date": (last + dt.timedelta(days=1)).isoformat(), "dateTime": None, "timeZone": None})
    tz_name = str(s.get("timeZone") or "")
    if not tz_name:
        raise Failure("Pick a time zone for the times.")
    tz = zone(tz_name)
    start = wall(date, s["startTime"], tz)
    if not s.get("endTime"):
        end = (start.astimezone(dt.timezone.utc) + dt.timedelta(hours=1)).astimezone(tz)
        return google_time(start, tz_name), google_time(end, tz_name)
    end_name = str(s.get("endTimeZone") or tz_name)
    end_tz = zone(end_name)
    end = wall(end_date, s["endTime"], end_tz)
    if end_name != tz_name and end_date == date and end <= start:
        # An end on another clock that comes before the start is the next
        # day's, as a red-eye lands.
        end = wall((dt.date.fromisoformat(date) + dt.timedelta(days=1)).isoformat(), s["endTime"], end_tz)
    if end < start or (end_name != tz_name and end == start):
        raise Failure("It has to end after it starts.")
    return google_time(start, tz_name), google_time(end, end_name)


def reminders_body(remind):
    lead = {"10m": 10, "30m": 30, "1h": 60, "1d": 1440}.get(str(remind or ""))
    return {"useDefault": False, "overrides": [] if lead is None else [{"method": "popup", "minutes": lead}]}


def text(value, limit):
    return str(value if value is not None else "").strip()[:limit]


def checked_day(value):
    day = str(value or "")
    try:
        if dt.date.fromisoformat(day).isoformat() == day:
            return day
    except ValueError:
        pass
    raise Failure("Pick a day.")


# ---------------------------------------------------------------------------
# Writing: create, edit, delete
# ---------------------------------------------------------------------------

def target_calendar(google, calendar_id):
    calendar_id = text(calendar_id, 512) or "primary"
    calendar = google.call("GET", "/users/me/calendarList/" + quoted(calendar_id))
    if not writable(calendar):
        raise Failure("You can only read that Google calendar. Pick another.")
    return calendar


def create(google, r):
    title = text(r.get("title"), 256)
    if not title:
        raise Failure("Give the event a title.")
    date = checked_day(r.get("date"))
    end_date = checked_day(r.get("endDate") or date)
    calendar = target_calendar(google, r.get("calendarId"))
    start, end = schedule_body({"allDay": bool(r.get("allDay")) or not r.get("startTime"),
                                "startTime": r.get("startTime"), "endTime": r.get("endTime"),
                                "timeZone": r.get("timeZone"), "endTimeZone": r.get("endTimeZone")}, date, end_date)
    body = {"summary": title, "start": strip_nulls(start), "end": strip_nulls(end), "reminders": reminders_body(r.get("remind"))}
    location = text(r.get("location"), 256)
    if location:
        body["location"] = location
    made = google.call("POST", "/calendars/%s/events" % quoted(calendar["id"]), {"sendUpdates": "none"}, body)
    if not made.get("id"):
        raise Failure("Google did not confirm the event. Refresh before trying again.")
    return "Event created"


def strip_nulls(value):
    return {k: v for k, v in value.items() if v is not None}


def series_dates(google, calendar_id, series_id, s):
    """The days a whole series' first event is on, in the zone the new
    times are in, so new times keep the series where it is."""
    series = google.call("GET", "/calendars/%s/events/%s" % (quoted(calendar_id), quoted(series_id)))
    if not series.get("start"):
        raise Failure("Google no longer has that series. Refresh and try again.")
    begins, ends, all_day = event_bounds(series)
    if s.get("allDay"):
        first = begins.date() if all_day else begins.astimezone(zone(s.get("timeZone") or "UTC")).date()
    else:
        first = begins.astimezone(zone(s.get("timeZone"))).date()
    span = (dt.date.fromisoformat(s["endDate"]) - dt.date.fromisoformat(s["date"])).days
    return first.isoformat(), (first + dt.timedelta(days=max(0, span))).isoformat()


def edit(google, r):
    event = r.get("event") or {}
    changes = r.get("changes") or {}
    one = r.get("scope") == "one"
    recurring = bool(event.get("recurring"))
    calendar_id = text(event.get("calendarId"), 512)
    own_id = text(event.get("seriesId"), 512)
    series_id = text(event.get("parentId"), 512) or own_id
    target = own_id if (one or not recurring) else series_id
    if not calendar_id or not target:
        raise Failure("Calendar for Omarchy cannot name that event to Google. Edit it there.")
    calendar = target_calendar(google, calendar_id)
    path = "/calendars/%s/events/%s" % (quoted(calendar["id"]), quoted(target))
    current = google.call("GET", path)
    if current.get("status") == "cancelled":
        raise Failure("Google no longer has that event. Refresh and try again.")
    if not editable(current, calendar):
        raise Failure("Google does not let you change that event here. Open it in Google Calendar.")

    body = {}
    if "title" in changes:
        title = text(changes["title"], 256)
        if not title:
            raise Failure("Give the event a title.")
        body["summary"] = title
    if "location" in changes:
        body["location"] = text(changes["location"], 256)
    if "remind" in changes:
        body["reminders"] = reminders_body(changes["remind"])
    s = changes.get("schedule")
    if s:
        if s.get("dates", True):
            date, end_date = checked_day(s.get("date")), checked_day(s.get("endDate") or s.get("date"))
        else:
            date, end_date = series_dates(google, calendar["id"], target, s)
        body["start"], body["end"] = schedule_body(s, date, end_date)
    # What the guests see is the organizer's to change, and Google would
    # either email them or not tell them: Google Calendar's own form asks.
    shared = {"summary", "location", "start", "end"} & set(body)
    if shared and others_invited(current):
        raise Failure("This event has guests. Change it in Google Calendar, which asks whether to tell them.")

    moving_to = text(changes.get("calendarId"), 512)
    if moving_to and moving_to != calendar["id"]:
        if recurring and one:
            raise Failure("Google moves a whole series, not one day. Choose Every day to move it.")
        target_calendar(google, moving_to)
    if body:
        google.call("PATCH", path, {"sendUpdates": "none"}, body)
    if moving_to and moving_to != calendar["id"]:
        google.call("POST", path + "/move", {"destination": moving_to, "sendUpdates": "none"})
    return "Event updated"


def delete(google, r):
    event = r.get("event") or {}
    calendar_id, event_id = text(event.get("calendarId"), 512), text(event.get("seriesId"), 512)
    if not calendar_id or not event_id:
        raise Failure("Calendar for Omarchy cannot name that event to Google. Delete it there.")
    calendar = target_calendar(google, calendar_id)
    path = "/calendars/%s/events/%s" % (quoted(calendar["id"]), quoted(event_id))
    # Checked against Google, not against the copy on screen.
    current = google.call("GET", path)
    if current.get("recurrence") or current.get("recurringEventId"):
        raise Failure("Delete repeating events in Google Calendar.")
    if others_invited(current):
        raise Failure("This event has guests. Delete it in Google Calendar, which asks whether to tell them.")
    if not editable(current, calendar):
        raise Failure("Google does not let you delete that event.")
    google.call("DELETE", path, {"sendUpdates": "none"})
    return "Event deleted"


def write(google, request):
    if not isinstance(request, dict):
        raise Failure("Calendar for Omarchy could not work out that change.")
    kind = request.get("kind")
    if kind == "create":
        return create(google, request.get("request") or {})
    if kind == "edit":
        return edit(google, request.get("request") or {})
    if kind == "delete":
        return delete(google, request.get("request") or {})
    raise Failure("Calendar for Omarchy does not know that change.")


def read_request():
    raw = sys.stdin.buffer.read(INPUT_LIMIT + 1)
    if len(raw) > INPUT_LIMIT:
        raise Failure("That change is too large.")
    try:
        return json.loads(raw)
    except ValueError:
        raise Failure("Calendar for Omarchy could not work out that change.") from None


# ---------------------------------------------------------------------------

def emit(lines):
    output = "\n".join(json.dumps(line, separators=(",", ":"), ensure_ascii=False) for line in lines)
    if len(output.encode()) > OUTPUT_LIMIT:
        raise Failure("Google has more there than Calendar for Omarchy will read.")
    sys.stdout.write(output + "\n")


def main(argv):
    action = argv[1] if len(argv) > 1 else ""
    keys = week_keys(argv[2:]) if action == "weeks" else []
    try:
        if action not in ("probe", "calendars", "weeks", "write"):
            raise Failure("Calendar for Omarchy does not know that Google action.")
        request = read_request() if action == "write" else None
        google = Google()
        if action == "probe":
            calendars = listed_calendars(google)
            primary = next((c["id"] for c in calendars if c.get("primary")), "")
            emit([{"ok": True, "account": primary, "calendars": len(calendars)}])
        elif action == "calendars":
            emit([[project_calendar(c) for c in listed_calendars(google)]])
        elif action == "weeks":
            if not keys:
                raise Failure("No weeks to read.")
            emit(read_weeks(google, keys))
        else:
            emit([{"ok": True, "message": write(google, request)}])
        return 0
    except Failure as error:
        if action == "weeks":
            emit([{"week": key, "error": True} for key in keys] + [{"ok": False, "error": str(error)}])
        else:
            emit([{"ok": False, "error": str(error), "missing": error.missing}])
        return 1
    except (KeyError, TypeError, ValueError, AttributeError):
        # Never a traceback: it could carry an event's text.
        if action == "weeks":
            emit([{"week": key, "error": True} for key in keys])
        else:
            emit([{"ok": False, "error": "Google answered with something Calendar for Omarchy cannot read."}])
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
