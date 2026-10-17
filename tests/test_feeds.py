"""The feed helper's iCalendar reading: run by tests/run in several zones.

/usr/bin/python3 -I tests/test_feeds.py
"""
import datetime as dt
import importlib.util
import io
import os
import sys
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("feeds", os.path.join(here, "..", "backends", "feeds.py"))
feeds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feeds)

FEED = {"id": "f0123456789abcdef", "name": "Synthetic", "color": "teal"}


def calendar(*events):
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0"]
    for event in events:
        lines += ["BEGIN:VEVENT"] + list(event) + ["END:VEVENT"]
    return "\r\n".join(lines + ["END:VCALENDAR", ""])


def read(text, first, last):
    return [e for _, _, e in feeds.expand(text, FEED, dt.date.fromisoformat(first), dt.date.fromisoformat(last))]


def starts(text, first, last):
    return sorted(e["starts_at"] for e in read(text, first, last))


class Reading(unittest.TestCase):
    def test_folded_and_escaped_text_reads_as_written(self):
        events = read(calendar(["UID:a", "DTSTART:20261019T090000Z", "DTEND:20261019T100000Z",
                                "SUMMARY:Dinner\\, then a long", " er title", "LOCATION:Café Luna\\; upstairs",
                                "DESCRIPTION:Join https://meet.google.com/abc-defg-hij"]), "2026-10-19", "2026-10-19")
        self.assertEqual(events[0]["title"], "Dinner, then a longer title")
        self.assertEqual(events[0]["location"], "Café Luna; upstairs")
        self.assertEqual(events[0]["join_url"], "https://meet.google.com/abc-defg-hij")
        self.assertFalse(events[0]["editable"])
        self.assertFalse(events[0]["recurring"])

    def test_all_day_events_end_on_their_last_day(self):
        events = read(calendar(["UID:trip", "DTSTART;VALUE=DATE:20261013", "DTEND;VALUE=DATE:20261017", "SUMMARY:Lisbon"]),
                      "2026-10-12", "2026-10-18")
        self.assertEqual(events[0]["starts_at"], "2026-10-13T00:00:00Z")
        self.assertEqual(events[0]["ends_at"], "2026-10-16T00:00:00Z")
        self.assertTrue(events[0]["all_day"])

    def test_a_zone_keeps_its_clock_across_the_change(self):
        text = calendar(["UID:w", "DTSTART;TZID=Europe/Berlin:20261019T090000", "DTEND;TZID=Europe/Berlin:20261019T093000",
                         "RRULE:FREQ=WEEKLY", "SUMMARY:Standup"])
        got = starts(text, "2026-10-19", "2026-11-01")
        self.assertEqual(got, ["2026-10-19T09:00:00+02:00", "2026-10-26T09:00:00+01:00"])

    def test_windows_and_prefixed_zone_names_are_understood(self):
        for tzid in ("W. Europe Standard Time", "/mozilla.org/20070129_1/Europe/Berlin"):
            got = starts(calendar(["UID:z", "DTSTART;TZID=%s:20261019T090000" % tzid, "SUMMARY:x"]), "2026-10-19", "2026-10-19")
            self.assertEqual(got, ["2026-10-19T09:00:00+02:00"], tzid)

    def test_cancelled_events_are_left_out(self):
        self.assertEqual(read(calendar(["UID:c", "DTSTART:20261019T090000Z", "STATUS:CANCELLED", "SUMMARY:x"]),
                              "2026-10-19", "2026-10-19"), [])

    def test_alarms_become_reminders(self):
        text = "\r\n".join(["BEGIN:VCALENDAR", "BEGIN:VEVENT", "UID:r", "DTSTART:20261019T090000Z", "SUMMARY:x",
                            "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM",
                            "BEGIN:VALARM", "ACTION:EMAIL", "TRIGGER:-P1D", "END:VALARM", "END:VEVENT", "END:VCALENDAR"])
        event = read(text, "2026-10-19", "2026-10-19")[0]
        self.assertEqual(event["reminder_leads"], [900])
        self.assertEqual(event["reminders"], ["2026-10-19T08:45:00+00:00"])


class Repeats(unittest.TestCase):
    def rule(self, rule, first, last, start="20260105T090000Z", extra=()):
        return starts(calendar(["UID:r", "DTSTART:" + start, "DTEND:" + start[:9] + "100000Z", "RRULE:" + rule,
                                "SUMMARY:x"] + list(extra)), first, last)

    def test_weekdays_and_intervals(self):
        got = self.rule("FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE", "2026-01-05", "2026-01-25")
        self.assertEqual([g[:10] for g in got], ["2026-01-05", "2026-01-07", "2026-01-19", "2026-01-21"])

    def test_count_counts_from_the_first(self):
        got = self.rule("FREQ=DAILY;COUNT=3", "2026-01-01", "2026-12-31")
        self.assertEqual(len(got), 3)

    def test_until_is_the_last(self):
        got = self.rule("FREQ=DAILY;UNTIL=20260107T090000Z", "2026-01-01", "2026-12-31")
        self.assertEqual([g[:10] for g in got], ["2026-01-05", "2026-01-06", "2026-01-07"])

    def test_the_last_friday_and_the_second_tuesday(self):
        got = self.rule("FREQ=MONTHLY;BYDAY=-1FR", "2026-01-01", "2026-04-30", start="20260130T090000Z")
        self.assertEqual([g[:10] for g in got], ["2026-01-30", "2026-02-27", "2026-03-27", "2026-04-24"])
        got = self.rule("FREQ=MONTHLY;BYDAY=TU;BYSETPOS=2", "2026-02-01", "2026-03-31", start="20260113T090000Z")
        self.assertEqual([g[:10] for g in got], ["2026-02-10", "2026-03-10"])

    def test_the_31st_skips_short_months(self):
        got = self.rule("FREQ=MONTHLY", "2026-01-01", "2026-05-31", start="20260131T090000Z")
        self.assertEqual([g[:10] for g in got], ["2026-01-31", "2026-03-31", "2026-05-31"])

    def test_yearly_thanksgiving_and_birthdays(self):
        got = self.rule("FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", "2026-01-01", "2028-12-31", start="20261126T170000Z")
        self.assertEqual([g[:10] for g in got], ["2026-11-26", "2027-11-25", "2028-11-23"])
        birthday = starts(calendar(["UID:b", "DTSTART;VALUE=DATE:19870301", "RRULE:FREQ=YEARLY", "SUMMARY:x"]),
                          "2026-01-01", "2026-12-31")
        self.assertEqual(birthday, ["2026-03-01T00:00:00Z"])

    def test_a_series_from_long_ago_is_read_quickly_and_right(self):
        got = self.rule("FREQ=DAILY", "2026-10-19", "2026-10-20", start="19990101T090000Z")
        self.assertEqual([g[:10] for g in got], ["2026-10-19", "2026-10-20"])

    def test_removed_and_moved_days(self):
        text = calendar(
            ["UID:s", "DTSTART;TZID=Europe/Berlin:20261019T090000", "DTEND;TZID=Europe/Berlin:20261019T091500",
             "RRULE:FREQ=DAILY;COUNT=5", "EXDATE;TZID=Europe/Berlin:20261020T090000", "SUMMARY:Standup"],
            ["UID:s", "RECURRENCE-ID;TZID=Europe/Berlin:20261021T090000", "DTSTART;TZID=Europe/Berlin:20261021T110000",
             "DTEND;TZID=Europe/Berlin:20261021T111500", "SUMMARY:Standup, later"],
            ["UID:s", "RECURRENCE-ID;TZID=Europe/Berlin:20261022T090000", "DTSTART;TZID=Europe/Berlin:20261022T090000",
             "STATUS:CANCELLED", "SUMMARY:Standup"])
        events = sorted(read(text, "2026-10-19", "2026-10-25"), key=lambda e: e["starts_at"])
        self.assertEqual([(e["starts_at"], e["title"]) for e in events], [
            ("2026-10-19T09:00:00+02:00", "Standup"),
            ("2026-10-21T11:00:00+02:00", "Standup, later"),
            ("2026-10-23T09:00:00+02:00", "Standup")])
        self.assertTrue(all(e["recurring"] for e in events))
        self.assertEqual(len({e["occurrence_id"] for e in events}), 3)

    def test_a_long_event_from_before_the_window_reaches_into_it(self):
        text = calendar(["UID:l", "DTSTART;VALUE=DATE:20261015", "DTEND;VALUE=DATE:20261022", "RRULE:FREQ=MONTHLY", "SUMMARY:x"])
        self.assertEqual(starts(text, "2026-10-19", "2026-10-19"), ["2026-10-15T00:00:00Z"])


class Weeks(unittest.TestCase):
    def test_an_event_is_filed_under_every_week_it_touches(self):
        text = calendar(["UID:t", "DTSTART;VALUE=DATE:20261024", "DTEND;VALUE=DATE:20261028", "SUMMARY:Trip"])
        original = feeds.fetch
        feeds.fetch = lambda feed: text.encode()
        try:
            weeks = feeds.read_weeks([FEED], ["2026-10-19", "2026-10-26", "2026-11-02"])
        finally:
            feeds.fetch = original
        self.assertEqual([len(w["events"]) for w in weeks], [1, 1, 0])


class FeedList(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        os.environ["XDG_CONFIG_HOME"] = self.home.name

    def tearDown(self):
        self.home.cleanup()

    def test_the_list_is_private_and_holds_only_https(self):
        feeds.save_feeds([{"url": "https://example.com/a.ics", "name": "A", "color": ""},
                          {"url": "file:///etc/passwd", "name": "B", "color": ""}])
        self.assertEqual(os.stat(feeds.config_path()).st_mode & 0o777, 0o600)
        self.assertEqual([f["name"] for f in feeds.load_feeds()], ["A"])

    def test_addresses_are_checked_before_anything_is_fetched(self):
        self.assertEqual(feeds.normalized_url("webcal://example.com/x.ics"), "https://example.com/x.ics")
        for bad in ("http://example.com/x.ics", "https://user:pass@example.com/x.ics", "https://exa mple.com", "javascript:x"):
            with self.assertRaises(feeds.Failure):
                feeds.normalized_url(bad)

    def test_a_new_feed_is_read_once_and_takes_its_own_name(self):
        original = feeds.fetch
        feeds.fetch = lambda feed, fresh_seconds=0: b"BEGIN:VCALENDAR\r\nX-WR-CALNAME:Holidays in Italy\r\nEND:VCALENDAR\r\n"
        try:
            feeds.add({"name": "", "url": "webcal://example.com/it.ics"})
            with self.assertRaises(feeds.Failure):
                feeds.add({"name": "Again", "url": "https://example.com/it.ics"})
            feeds.fetch = lambda feed, fresh_seconds=0: (_ for _ in ()).throw(feeds.Failure("unreachable"))
            with self.assertRaises(feeds.Failure):
                feeds.add({"name": "Broken", "url": "https://example.com/broken.ics"})
        finally:
            feeds.fetch = original
        self.assertEqual([(f["name"], f["url"]) for f in feeds.load_feeds()], [("Holidays in Italy", "https://example.com/it.ics")])
        feeds.remove(feeds.feed_id("https://example.com/it.ics"))
        self.assertEqual(feeds.load_feeds(), [])

    def test_a_feed_is_named_by_an_id_that_does_not_give_away_its_address(self):
        identifier = feeds.feed_id("https://calendar.google.com/calendar/ical/secret/basic.ics")
        self.assertRegex(identifier, r"^f[0-9a-f]{16}$")
        self.assertNotIn("secret", identifier)


if __name__ == "__main__":
    report = io.StringIO()
    result = unittest.TextTestRunner(stream=report).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    if not result.wasSuccessful():
        sys.stderr.write(report.getvalue())
        sys.exit(1)
    print("ok feeds [%s]: %d cases" % (os.environ.get("TZ", "local"), result.testsRun))
