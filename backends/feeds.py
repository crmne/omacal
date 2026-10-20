#!/usr/bin/env python3
"""Calendar for Omarchy's calendar-feed helper (backends/Feeds.js runs it).

Reads iCalendar (.ics) feeds: the "secret address in iCal format" of a
Google calendar, an iCloud or Outlook published calendar, a holiday or
sports calendar, anything served over HTTPS. Prints their events in
Calendar for Omarchy's standard shapes (see "Backends" at the top of Calendar.js), with
every repeating event unrolled here: RRULE (daily, weekly, monthly, yearly,
with BYDAY, BYMONTHDAY, BYMONTH, BYSETPOS, COUNT and UNTIL), RDATE, EXDATE,
and single days moved or cancelled (RECURRENCE-ID). Times are read in their
TZID through the system's zone files.

A feed's address is a password: whoever has it can read the calendar. So
the addresses live in one file, ~/.config/omacal/feeds.json, readable only
by you, and reach this helper through it, never as an argument. A new one
arrives on stdin. Settings and the panel see a feed's id, name and host.

  feeds.py probe               {"ok": true, "feeds": 2}
  feeds.py list                [{id, name, color, host}]
  feeds.py calendars           [{id, name, color, kind, owned}]
  feeds.py weeks KEY...        one {"week", "events"} line per week
  feeds.py add < {name, url}   {"ok": true, "message": ...}
  feeds.py remove ID           {"ok": true, "message": ...}

What a feed served is kept for two minutes in $XDG_RUNTIME_DIR/omacal,
readable only by you and gone when you log out, so browsing months does not
fetch every feed again; after that it is asked for again with its ETag.
"""
import calendar as monthcal
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

OUTPUT_LIMIT = 4 * 1024 * 1024
FEED_LIMIT = 20 * 1024 * 1024
INPUT_LIMIT = 64 * 1024
EVENT_LIMIT = 2000
MAX_FEEDS = 20
MAX_WEEKS = 8
TIMEOUT = 20
FRESH_SECONDS = 120
COLORS = ["teal", "purple", "orange", "pink", "green", "brown", "gold", "blue", "red"]


class Failure(Exception):
    pass


# The tests serve feeds from this machine over plain HTTP; nothing else is
# ever read without TLS.
LOOPBACK = os.environ.get("OMACAL_TEST_LOOPBACK") == "1"


def allowed_url(url):
    return url.startswith("https://") or (LOOPBACK and url.startswith("http://127.0.0.1:"))


def local_zone():
    """This machine's zone, so a floating time keeps its clock across a
    change of the clocks."""
    name = os.environ.get("TZ", "").lstrip(":")
    if name:
        try:
            return ZoneInfo(name)
        except (ValueError, KeyError, OSError):
            pass
    try:
        with open("/etc/localtime", "rb") as handle:
            return ZoneInfo.from_file(handle)
    except (OSError, ValueError):
        return None


LOCAL = local_zone()


def local(naive):
    return naive.replace(tzinfo=LOCAL) if LOCAL is not None else naive.astimezone()


def midnight(day):
    return local(dt.datetime.combine(day, dt.time()))


# ---------------------------------------------------------------------------
# The feed list
# ---------------------------------------------------------------------------

def config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "omacal", "feeds.json")


def load_feeds():
    try:
        with open(config_path(), "rb") as handle:
            value = json.loads(handle.read(1024 * 1024))
    except FileNotFoundError:
        return []
    except (OSError, ValueError):
        raise Failure("Calendar for Omarchy could not read its feed list, %s." % config_path()) from None
    feeds = value.get("feeds") if isinstance(value, dict) else None
    out = []
    for feed in feeds if isinstance(feeds, list) else []:
        if isinstance(feed, dict) and isinstance(feed.get("url"), str) and allowed_url(feed["url"]):
            out.append({"url": feed["url"], "name": str(feed.get("name") or "")[:128] or host_of(feed["url"]),
                        "color": str(feed.get("color") or "")[:32]})
    return out[:MAX_FEEDS]


def save_feeds(feeds):
    path = config_path()
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".feeds.")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump({"feeds": feeds}, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(temporary, path)
    except OSError:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise Failure("Calendar for Omarchy could not save its feed list to %s." % path) from None


def feed_id(url):
    return "f" + hashlib.sha256(url.encode()).hexdigest()[:16]


def host_of(url):
    return urllib.parse.urlsplit(url).hostname or ""


def normalized_url(text):
    url = str(text or "").strip()
    if url.lower().startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    parts = urllib.parse.urlsplit(url)
    if not allowed_url(url) or not parts.hostname or parts.username or parts.password \
            or re.search(r"[\s\"'<>\\]", url):
        raise Failure("That is not an https:// or webcal:// calendar address.")
    return url


def colored(feeds):
    out = []
    for index, feed in enumerate(feeds):
        out.append(dict(feed, id=feed_id(feed["url"]), color=feed["color"] or COLORS[index % len(COLORS)]))
    return out


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------

class HttpsOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not allowed_url(newurl):
            raise Failure("A feed redirected away from HTTPS, so Calendar for Omarchy did not follow it.")
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        # CPython reads a redirect's whole body before following it, with no
        # limit; closed first, that read gets nothing.
        if new is not None:
            fp.close()
        return new


def cache_dir():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime or not os.path.isdir(runtime):
        return ""
    path = os.path.join(runtime, "omacal", "feeds")
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        os.chmod(os.path.join(runtime, "omacal"), 0o700)
        os.chmod(path, 0o700)
    except OSError:
        return ""
    return path


def read_cached(name):
    folder = cache_dir()
    if not folder:
        return None, {}
    try:
        with open(os.path.join(folder, name + ".json"), "rb") as handle:
            meta = json.loads(handle.read(65536))
        with open(os.path.join(folder, name + ".ics"), "rb") as handle:
            return handle.read(FEED_LIMIT + 1), meta
    except (OSError, ValueError):
        return None, {}


def write_cached(name, body, meta):
    folder = cache_dir()
    if not folder:
        return
    for suffix, data in ((".ics", body), (".json", json.dumps(meta).encode())):
        fd, temporary = tempfile.mkstemp(dir=folder, prefix="." + name)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
            os.replace(temporary, os.path.join(folder, name + suffix))
        except OSError:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def fetch(feed, fresh_seconds=FRESH_SECONDS):
    name = feed["id"]
    cached, meta = read_cached(name)
    if cached is not None and time.time() - float(meta.get("at", 0)) < fresh_seconds:
        return cached
    headers = {"User-Agent": "Calendar for Omarchy (+https://github.com/crmne/omarchy-calendar)", "Accept": "text/calendar, */*;q=0.5"}
    if cached is not None and meta.get("etag"):
        headers["If-None-Match"] = meta["etag"]
    if cached is not None and meta.get("modified"):
        headers["If-Modified-Since"] = meta["modified"]
    opener = urllib.request.build_opener(HttpsOnly)
    try:
        with opener.open(urllib.request.Request(feed["url"], headers=headers), timeout=TIMEOUT) as response:
            body = response.read(FEED_LIMIT + 1)
            meta = {"at": time.time(), "etag": response.headers.get("ETag", ""),
                    "modified": response.headers.get("Last-Modified", "")}
    except urllib.error.HTTPError as error:
        if error.code == 304 and cached is not None:
            meta["at"] = time.time()
            write_cached(name, cached, meta)
            return cached
        if error.code in (401, 403, 404, 410):
            raise Failure("“%s” no longer serves its calendar (HTTP %d). Its address may have been reset." % (feed["name"], error.code)) from None
        raise Failure("“%s” could not be read (HTTP %d)." % (feed["name"], error.code)) from None
    except (urllib.error.URLError, OSError, ValueError):
        if cached is not None:
            return cached
        raise Failure("“%s” could not be reached. Check the connection." % feed["name"]) from None
    if len(body) > FEED_LIMIT:
        raise Failure("“%s” is larger than Calendar for Omarchy will read." % feed["name"])
    if b"BEGIN:VCALENDAR" not in body[:4096].upper():
        raise Failure("“%s” is not a calendar feed." % feed["name"])
    write_cached(name, body, meta)
    return body


# ---------------------------------------------------------------------------
# Reading iCalendar (RFC 5545)
# ---------------------------------------------------------------------------

def unfold(text):
    return re.sub(r"\r?\n[ \t]", "", text).splitlines()


def parse_line(line):
    """NAME;PARAM=VALUE:value as (name, {param: value}, value)."""
    i, quoted, cut = 0, False, -1
    while i < len(line):
        c = line[i]
        if c == '"':
            quoted = not quoted
        elif c == ":" and not quoted:
            cut = i
            break
        i += 1
    if cut <= 0:
        return None
    head, value = line[:cut], line[cut + 1:]
    pieces = re.findall(r'(?:[^;"]|"[^"]*")+', head)
    if not pieces:
        return None
    params = {}
    for piece in pieces[1:]:
        if "=" in piece:
            key, val = piece.split("=", 1)
            params[key.upper()] = val.strip('"')
    return pieces[0].upper(), params, value


def unescape(value):
    return re.sub(r"\\([\\;,nN])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), value)


def components(text):
    """Every VEVENT, with its VALARMs, as {"props": [...], "alarms": [[...]]}."""
    events = []
    stack = []
    for raw in unfold(text):
        parsed = parse_line(raw)
        if parsed is None:
            continue
        name, params, value = parsed
        if name == "BEGIN":
            kind = value.strip().upper()
            stack.append(kind)
            if kind == "VEVENT":
                events.append({"props": [], "alarms": []})
            elif kind == "VALARM" and events and "VEVENT" in stack:
                events[-1]["alarms"].append([])
            if len(events) > EVENT_LIMIT * 5:
                raise Failure("A feed has more events than Calendar for Omarchy will read.")
            continue
        if name == "END":
            if stack:
                stack.pop()
            continue
        if not stack or not events:
            continue
        if stack[-1] == "VEVENT":
            events[-1]["props"].append((name, params, value))
        elif stack[-1] == "VALARM" and "VEVENT" in stack and events[-1]["alarms"]:
            events[-1]["alarms"][-1].append((name, params, value))
    return events


def first(props, name):
    for prop in props:
        if prop[0] == name:
            return prop
    return None


def every(props, name):
    return [prop for prop in props if prop[0] == name]


# Windows zone names, as Outlook and Exchange feeds write TZID.
WINDOWS_ZONES = {
    "UTC": "UTC", "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
    "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
    "Romance Standard Time": "Europe/Paris", "Central European Standard Time": "Europe/Warsaw",
    "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev",
    "GTB Standard Time": "Europe/Bucharest", "Russian Standard Time": "Europe/Moscow",
    "Turkey Standard Time": "Europe/Istanbul", "Israel Standard Time": "Asia/Jerusalem",
    "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Kolkata",
    "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
    "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
    "AUS Eastern Standard Time": "Australia/Sydney", "E. Australia Standard Time": "Australia/Brisbane",
    "New Zealand Standard Time": "Pacific/Auckland", "Eastern Standard Time": "America/New_York",
    "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver",
    "US Mountain Standard Time": "America/Phoenix", "Pacific Standard Time": "America/Los_Angeles",
    "Alaskan Standard Time": "America/Anchorage", "Hawaiian Standard Time": "Pacific/Honolulu",
    "Atlantic Standard Time": "America/Halifax", "Canada Central Standard Time": "America/Regina",
    "SA Pacific Standard Time": "America/Bogota", "E. South America Standard Time": "America/Sao_Paulo",
    "Argentina Standard Time": "America/Argentina/Buenos_Aires", "Mexico Standard Time": "America/Mexico_City",
    "Central Standard Time (Mexico)": "America/Mexico_City", "South Africa Standard Time": "Africa/Johannesburg",
    "Egypt Standard Time": "Africa/Cairo", "W. Central Africa Standard Time": "Africa/Lagos",
}

_zones = {}
_known = None


def zone_for(tzid):
    """A TZID's zone, or None for local time when it names none we know."""
    name = str(tzid or "").strip().strip('"')
    if name in _zones:
        return _zones[name]
    found = None
    candidates = [name, WINDOWS_ZONES.get(name, "")]
    # "/mozilla.org/20070129_1/Europe/Berlin" and the like end in a zone.
    match = re.search(r"([A-Za-z]+/[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)?)$", name)
    if match:
        candidates.append(match.group(1))
    for candidate in candidates:
        if not candidate:
            continue
        try:
            found = ZoneInfo(candidate)
            break
        except (ValueError, KeyError, OSError):
            continue
    _zones[name] = found
    return found


def parse_when(value, params):
    """A DATE (dt.date) or DATE-TIME (aware dt.datetime; floating is local)."""
    text = value.strip()
    if params.get("VALUE", "").upper() == "DATE" or re.fullmatch(r"\d{8}", text):
        return dt.date(int(text[:4]), int(text[4:6]), int(text[6:8]))
    match = re.fullmatch(r"(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)", text)
    if not match:
        raise ValueError("not a date")
    naive = dt.datetime(*[int(g) for g in match.groups()[:6]])
    if match.group(7):
        return naive.replace(tzinfo=dt.timezone.utc)
    tz = zone_for(params.get("TZID")) if params.get("TZID") else None
    return naive.replace(tzinfo=tz) if tz else local(naive)


def parse_list(value, params):
    out = []
    for part in value.split(","):
        part = part.strip()
        if not part or "/" in part:
            continue
        try:
            out.append(parse_when(part, params))
        except ValueError:
            continue
    return out


def parse_duration(text):
    match = re.fullmatch(r"([+-]?)P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", text.strip())
    if not match:
        return None
    sign = -1 if match.group(1) == "-" else 1
    weeks, days, hours, minutes, seconds = [int(g or 0) for g in match.groups()[1:]]
    return sign * dt.timedelta(weeks=weeks, days=days, hours=hours, minutes=minutes, seconds=seconds)


def same_moment(a, b):
    if isinstance(a, dt.datetime) and isinstance(b, dt.datetime):
        return a == b
    return as_date(a) == as_date(b)


def as_date(value):
    return value.date() if isinstance(value, dt.datetime) else value


# ---------------------------------------------------------------------------
# Repeats (RFC 5545 3.3.10)
# ---------------------------------------------------------------------------

WEEKDAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


def parse_rule(text):
    rule = {}
    for part in text.split(";"):
        if "=" in part:
            key, value = part.split("=", 1)
            rule[key.strip().upper()] = value.strip()
    return rule


def ints(text):
    out = []
    for part in str(text or "").split(","):
        try:
            out.append(int(part))
        except ValueError:
            continue
    return out


def by_days(text):
    """BYDAY as [(ordinal or 0, weekday)]."""
    out = []
    for part in str(text or "").split(","):
        match = re.fullmatch(r"([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)", part.strip().upper())
        if match:
            out.append((int(match.group(1) or 0), WEEKDAYS[match.group(2)]))
    return out


def nth_weekdays(days, wanted):
    """Of `days` (sorted dates), those matching BYDAY with its ordinals."""
    out = set()
    for ordinal, weekday in wanted:
        matching = [d for d in days if d.weekday() == weekday]
        if ordinal == 0:
            out.update(matching)
        elif 0 < ordinal <= len(matching):
            out.add(matching[ordinal - 1])
        elif ordinal < 0 and -ordinal <= len(matching):
            out.add(matching[ordinal])
    return out


def month_days(year, month):
    return [dt.date(year, month, d) for d in range(1, monthcal.monthrange(year, month)[1] + 1)]


def month_day_matches(day, wanted):
    last = monthcal.monthrange(day.year, day.month)[1]
    return any(n == day.day or (n < 0 and last + 1 + n == day.day) for n in wanted)


def add_months(year, month, delta):
    index = year * 12 + (month - 1) + delta
    return index // 12, index % 12 + 1


def period_dates(freq, rule, start, n):
    """The candidate days of the n-th period of a rule from `start`."""
    interval = max(1, int(rule.get("INTERVAL", "1") or 1))
    months = ints(rule.get("BYMONTH"))
    monthdays = ints(rule.get("BYMONTHDAY"))
    days = by_days(rule.get("BYDAY"))
    if freq == "DAILY":
        day = start + dt.timedelta(days=n * interval)
        candidates = [day]
    elif freq == "WEEKLY":
        wkst = WEEKDAYS.get(rule.get("WKST", "MO").upper(), 0)
        week = start - dt.timedelta(days=(start.weekday() - wkst) % 7) + dt.timedelta(weeks=n * interval)
        wanted = [w for _, w in days] or [start.weekday()]
        candidates = sorted(week + dt.timedelta(days=(w - wkst) % 7) for w in set(wanted))
        days = []
    elif freq == "MONTHLY":
        year, month = add_months(start.year, start.month, n * interval)
        pool = month_days(year, month)
        if days and monthdays:
            chosen = nth_weekdays(pool, days) & {d for d in pool if month_day_matches(d, monthdays)}
        elif days:
            chosen = nth_weekdays(pool, days)
        elif monthdays:
            chosen = {d for d in pool if month_day_matches(d, monthdays)}
        else:
            chosen = {d for d in pool if d.day == start.day}
        candidates = sorted(chosen)
        days = []
        monthdays = []
    elif freq == "YEARLY":
        year = start.year + n * interval
        chosen = set()
        if days and not months and not monthdays:
            pool = [dt.date(year, 1, 1) + dt.timedelta(days=i) for i in range(366 if monthcal.isleap(year) else 365)]
            chosen = nth_weekdays(pool, days)
        else:
            for month in months or [start.month]:
                pool = month_days(year, month)
                if days and monthdays:
                    chosen |= nth_weekdays(pool, days) & {d for d in pool if month_day_matches(d, monthdays)}
                elif days:
                    chosen |= nth_weekdays(pool, days)
                elif monthdays:
                    chosen |= {d for d in pool if month_day_matches(d, monthdays)}
                else:
                    chosen |= {d for d in pool if d.day == start.day}
        candidates = sorted(chosen)
        days = []
        monthdays = []
        months = []
    else:
        return []
    out = []
    for day in candidates:
        if months and day.month not in months:
            continue
        if monthdays and not month_day_matches(day, monthdays):
            continue
        if days and day.weekday() not in [w for _, w in days]:
            continue
        out.append(day)
    positions = ints(rule.get("BYSETPOS"))
    if positions:
        picked = set()
        for p in positions:
            if 0 < p <= len(out):
                picked.add(out[p - 1])
            elif p < 0 and -p <= len(out):
                picked.add(out[p])
        out = sorted(picked)
    return out


def periods_to_skip(freq, rule, start, window_start):
    """How many whole periods lie before the window, for a rule without
    COUNT, so a daily rule from 1999 does not walk every day since."""
    interval = max(1, int(rule.get("INTERVAL", "1") or 1))
    gap = (window_start - start).days
    if gap <= 0:
        return 0
    if freq == "DAILY":
        return max(0, gap // interval - 1)
    if freq == "WEEKLY":
        return max(0, gap // (7 * interval) - 1)
    if freq == "MONTHLY":
        return max(0, gap // (31 * interval) - 1)
    if freq == "YEARLY":
        return max(0, gap // (366 * interval) - 1)
    return 0


def occurrence_starts(dtstart, rule_text, window_start, window_end):
    """The starts of a rule's occurrences up to window_end (dates)."""
    rule = parse_rule(rule_text)
    freq = rule.get("FREQ", "").upper()
    if freq not in ("DAILY", "WEEKLY", "MONTHLY", "YEARLY"):
        return [dtstart]
    count = int(rule["COUNT"]) if rule.get("COUNT", "").isdigit() else 0
    until = None
    if rule.get("UNTIL"):
        try:
            until = parse_when(rule["UNTIL"], {"TZID": getattr(dtstart, "tzinfo", None) and str(dtstart.tzinfo)})
        except ValueError:
            until = None
    start_day = as_date(dtstart)
    n = 0 if count else periods_to_skip(freq, rule, start_day, window_start)
    out = []
    seen = 0
    for _ in range(20000):
        try:
            days = period_dates(freq, rule, start_day, n)
        except (ValueError, OverflowError):
            # Past the year 9999: a rule that never matches again.
            return out
        n += 1
        if not days and freq == "DAILY":
            continue
        past_end = False
        for day in days:
            if day < start_day:
                continue
            if isinstance(dtstart, dt.datetime):
                moment = dt.datetime.combine(day, dtstart.timetz().replace(tzinfo=None)).replace(tzinfo=dtstart.tzinfo)
            else:
                moment = day
            if until is not None and not before_or_at(moment, until):
                return out
            seen += 1
            if count and seen > count:
                return out
            if day > window_end:
                past_end = True
                break
            out.append(moment)
        if past_end:
            return out
        if days and days[0] > window_end:
            return out
        if freq != "DAILY" and not days:
            # A month or year without such a day (the 31st, February 29th):
            # keep looking, but not forever.
            continue
    return out


def before_or_at(moment, until):
    if isinstance(moment, dt.datetime) and isinstance(until, dt.datetime):
        return moment <= until
    return as_date(moment) <= as_date(until)


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

MEETING = re.compile(r"https://(?:meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com|teams\.live\.com|"
                     r"[\w.-]*webex\.com|whereby\.com|meet\.jit\.si|app\.hey\.com/calendar/meetings)/[^\s<>\"'\\]+")


def meeting_link(props):
    for name in ("X-GOOGLE-CONFERENCE", "CONFERENCE", "URL", "LOCATION", "DESCRIPTION"):
        for prop in every(props, name):
            match = MEETING.search(unescape(prop[2]))
            if match:
                return match.group(0)
    return ""


def alarm_leads(alarms):
    leads = []
    for alarm in alarms:
        action = first(alarm, "ACTION")
        trigger = first(alarm, "TRIGGER")
        if not trigger or (action and action[2].strip().upper() not in ("DISPLAY", "AUDIO")):
            continue
        if trigger[1].get("RELATED", "START").upper() != "START" or trigger[1].get("VALUE", "").upper() == "DATE-TIME":
            continue
        lead = parse_duration(trigger[2])
        if lead is not None and lead <= dt.timedelta(0):
            leads.append(int(-lead.total_seconds()))
    return sorted(set(leads))[:8]


class Event:
    def __init__(self, component):
        props = component["props"]
        self.props = props
        start = first(props, "DTSTART")
        if not start:
            raise ValueError("no start")
        self.start = parse_when(start[2], start[1])
        end = first(props, "DTEND")
        duration = first(props, "DURATION")
        if end:
            self.end = parse_when(end[2], end[1])
        elif duration and parse_duration(duration[2]) is not None:
            self.end = self.start + parse_duration(duration[2])
        else:
            self.end = self.start + (dt.timedelta(days=1) if not isinstance(self.start, dt.datetime) else dt.timedelta(0))
        if type(self.end) is not type(self.start):
            self.end = self.start
        if self.end < self.start:
            self.end = self.start
        uid = first(props, "UID")
        self.uid = unescape(uid[2]).strip()[:120] if uid else hashlib.sha256(start[2].encode()).hexdigest()[:24]
        recurrence = first(props, "RECURRENCE-ID")
        self.recurrence_id = parse_when(recurrence[2], recurrence[1]) if recurrence else None
        rule = first(props, "RRULE")
        self.rule = rule[2] if rule else ""
        self.exdates = [d for prop in every(props, "EXDATE") for d in parse_list(prop[2], prop[1])]
        self.rdates = [d for prop in every(props, "RDATE") for d in parse_list(prop[2], prop[1])]
        status = first(props, "STATUS")
        self.cancelled = bool(status and status[2].strip().upper() == "CANCELLED")
        self.leads = alarm_leads(component["alarms"])

    def text(self, name, limit):
        prop = first(self.props, name)
        return unescape(prop[2]).strip()[:limit] if prop else ""


def project(event, start, feed, recurring):
    all_day = not isinstance(start, dt.datetime)
    length = event.end - event.start
    if all_day:
        last = start + max(dt.timedelta(0), length - dt.timedelta(days=1))
        starts_at, ends_at = start.isoformat() + "T00:00:00Z", last.isoformat() + "T00:00:00Z"
        begins = midnight(start)
    else:
        starts_at, ends_at = start.isoformat(), (start + length).isoformat()
        begins = start
    url = event.text("URL", 2048)
    return {
        "id": event.uid,
        "occurrence_id": event.uid + "_" + starts_at if recurring else "",
        "recurring": recurring,
        "title": event.text("SUMMARY", 256) or "(untitled)",
        "all_day": all_day, "starts_at": starts_at, "ends_at": ends_at,
        "calendar_id": feed["id"], "calendar": feed["name"], "color": feed["color"],
        "location": event.text("LOCATION", 256),
        "url": url if url.startswith("https://") else "",
        "join_url": meeting_link(event.props), "join_title": "",
        "reminders": [(begins - dt.timedelta(seconds=s)).astimezone(dt.timezone.utc).isoformat() for s in event.leads],
        "reminder_leads": event.leads,
        "editable": False,
    }


def bounds(start, length):
    if isinstance(start, dt.datetime):
        return start, start + length
    begins = midnight(start)
    return begins, midnight(start + max(length, dt.timedelta(days=1)))


def expand(text, feed, first_day, last_day):
    """Every occurrence touching first_day..last_day, as (begins, ends, event)."""
    parsed = []
    for component in components(text):
        try:
            parsed.append(Event(component))
        except (ValueError, OverflowError):
            continue
    masters = {}
    overrides = {}
    for event in parsed:
        if event.recurrence_id is not None:
            overrides.setdefault(event.uid, []).append(event)
        else:
            masters.setdefault(event.uid, []).append(event)
    lower = midnight(first_day)
    upper = midnight(last_day + dt.timedelta(days=1))
    out = []

    def keep(event, start, recurring):
        begins, ends = bounds(start, event.end - event.start)
        if begins < upper and (ends > lower or (ends == begins and begins >= lower)):
            out.append((begins, ends, project(event, start, feed, recurring)))

    for uid, events in masters.items():
        for event in events:
            moved = overrides.get(uid, [])
            if not event.rule and not event.rdates:
                if not event.cancelled:
                    keep(event, event.start, False)
                continue
            # How far back an occurrence can start and still reach the window.
            reach = max(1, (event.end - event.start).days + 1)
            starts = occurrence_starts(event.start, event.rule, first_day - dt.timedelta(days=reach), last_day) \
                if event.rule else [event.start]
            starts += [d for d in event.rdates if type(d) is type(event.start)]
            for start in starts:
                if event.cancelled or any(same_moment(start, x) for x in event.exdates):
                    continue
                if any(same_moment(start, o.recurrence_id) for o in moved):
                    continue
                keep(event, start, True)
            for override in moved:
                if not override.cancelled:
                    keep(override, override.start, True)
            if len(out) > EVENT_LIMIT:
                raise Failure("“%s” has more events there than Calendar for Omarchy will read." % feed["name"])
    # Days moved out of a series this feed does not list.
    for uid, moved in overrides.items():
        if uid not in masters:
            for override in moved:
                if not override.cancelled:
                    keep(override, override.start, True)
    return out


def decode(body):
    for encoding in ("utf-8-sig", "latin-1"):
        try:
            return body.decode(encoding)
        except UnicodeDecodeError:
            continue
    return body.decode("utf-8", "replace")


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


def read_weeks(feeds, keys):
    first_day = dt.date.fromisoformat(keys[0])
    last_day = dt.date.fromisoformat(keys[-1]) + dt.timedelta(days=6)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        bodies = list(pool.map(fetch, feeds))
    weeks = {key: [] for key in keys}
    for feed, body in zip(feeds, bodies):
        for begins, ends, event in expand(decode(body), feed, first_day, last_day):
            for key in keys:
                monday = dt.date.fromisoformat(key)
                lower = midnight(monday)
                upper = midnight(monday + dt.timedelta(days=7))
                if begins < upper and (ends > lower or (ends == begins and begins >= lower)):
                    weeks[key].append(event)
    return [{"week": key, "events": weeks[key][:EVENT_LIMIT]} for key in keys]


# ---------------------------------------------------------------------------
# Adding and removing feeds
# ---------------------------------------------------------------------------

def add(request):
    if not isinstance(request, dict):
        raise Failure("Calendar for Omarchy could not read that feed.")
    url = normalized_url(request.get("url"))
    feeds = load_feeds()
    if any(feed["url"] == url for feed in feeds):
        raise Failure("That feed is already there.")
    if len(feeds) >= MAX_FEEDS:
        raise Failure("Calendar for Omarchy reads up to %d feeds." % MAX_FEEDS)
    name = str(request.get("name") or "").strip()[:128]
    feed = {"url": url, "name": name or host_of(url), "color": ""}
    body = fetch(dict(feed, id=feed_id(url)), fresh_seconds=0)
    if not name:
        # The feed's own name, when it gives one.
        match = re.search(r"^X-WR-CALNAME:(.+)$", decode(body[:65536]), re.MULTILINE)
        if match:
            feed["name"] = unescape(match.group(1)).strip()[:128] or feed["name"]
    feeds.append(feed)
    save_feeds(feeds)
    return "Added “%s”." % feed["name"]


def remove(identifier):
    feeds = load_feeds()
    kept = [feed for feed in feeds if feed_id(feed["url"]) != identifier]
    if len(kept) == len(feeds):
        raise Failure("That feed is not there any more.")
    save_feeds(kept)
    folder = cache_dir()
    for suffix in (".ics", ".json"):
        try:
            os.unlink(os.path.join(folder, identifier + suffix))
        except OSError:
            pass
    return "Removed."


# ---------------------------------------------------------------------------

def emit(lines):
    output = "\n".join(json.dumps(line, separators=(",", ":"), ensure_ascii=False) for line in lines)
    if len(output.encode()) > OUTPUT_LIMIT:
        raise Failure("The feeds have more there than Calendar for Omarchy will read.")
    sys.stdout.write(output + "\n")


def main(argv):
    action = argv[1] if len(argv) > 1 else ""
    keys = week_keys(argv[2:]) if action == "weeks" else []
    try:
        if action == "add":
            raw = sys.stdin.buffer.read(INPUT_LIMIT + 1)
            if len(raw) > INPUT_LIMIT:
                raise Failure("That address is too long.")
            try:
                request = json.loads(raw)
            except ValueError:
                raise Failure("Calendar for Omarchy could not read that feed.") from None
            emit([{"ok": True, "message": add(request)}])
            return 0
        if action == "remove":
            emit([{"ok": True, "message": remove(argv[2] if len(argv) > 2 else "")}])
            return 0
        feeds = colored(load_feeds())
        if action == "probe":
            if not feeds:
                emit([{"ok": False, "quiet": True, "error": "No calendar feeds yet."}])
                return 1
            emit([{"ok": True, "feeds": len(feeds)}])
        elif action == "list":
            emit([[{"id": f["id"], "name": f["name"], "color": f["color"], "host": host_of(f["url"])} for f in feeds]])
        elif action == "calendars":
            emit([[{"id": f["id"], "name": f["name"], "color": f["color"], "kind": "feed", "owned": False} for f in feeds]])
        elif action == "weeks":
            if not keys:
                raise Failure("No weeks to read.")
            emit(read_weeks(feeds, keys))
        else:
            raise Failure("Calendar for Omarchy does not know that feed action.")
        return 0
    except Failure as error:
        if action == "weeks":
            emit([{"week": key, "error": True} for key in keys] + [{"ok": False, "error": str(error)}])
        else:
            emit([{"ok": False, "error": str(error)}])
        return 1
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        # Never a traceback: it could carry an event's text.
        if action == "weeks":
            emit([{"week": key, "error": True} for key in keys])
        else:
            emit([{"ok": False, "error": "A feed served something Calendar for Omarchy cannot read."}])
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
