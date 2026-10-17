"""The Google helper's reading and writing, against a pretend Google: run by
tests/run in several zones.

/usr/bin/python3 -I tests/test_google.py
"""
import datetime as dt
import importlib.util
import io
import os
import sys
import unittest

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("google", os.path.join(here, "..", "backends", "google.py"))
google = importlib.util.module_from_spec(spec)
spec.loader.exec_module(google)

CALENDAR = {"id": "me@example.com", "summary": "Work", "accessRole": "owner", "backgroundColor": "#9fc6e7",
            "defaultReminders": [{"method": "popup", "minutes": 30}, {"method": "email", "minutes": 60}]}


class Pretend:
    """Answers the helper's calls from a table, and keeps what it sent."""

    def __init__(self, answers=None):
        self.answers = answers or {}
        self.sent = []

    def call(self, method, path, params=None, body=None):
        self.sent.append((method, path, params, body))
        answer = self.answers.get((method, path), {})
        if isinstance(answer, Exception):
            raise answer
        return answer


class Projection(unittest.TestCase):
    def test_an_all_day_event_ends_on_its_last_day(self):
        event = google.project_event({"id": "t", "summary": "Lisbon", "start": {"date": "2026-10-13"},
                                      "end": {"date": "2026-10-17"}}, CALENDAR, {})
        self.assertEqual((event["starts_at"], event["ends_at"]), ("2026-10-13T00:00:00Z", "2026-10-16T00:00:00Z"))
        self.assertTrue(event["all_day"])

    def test_default_reminders_are_the_calendars_popups(self):
        event = google.project_event({"id": "m", "summary": "Call", "start": {"dateTime": "2026-10-19T09:00:00+02:00"},
                                      "end": {"dateTime": "2026-10-19T10:00:00+02:00"}, "reminders": {"useDefault": True}},
                                     CALENDAR, {})
        self.assertEqual(event["reminder_leads"], [1800])
        self.assertEqual(event["reminders"], ["2026-10-19T06:30:00+00:00"])

    def test_meetings_colors_and_answers(self):
        event = google.project_event({
            "id": "abc_20261019T070000Z", "recurringEventId": "abc", "summary": "Standup", "colorId": "11",
            "start": {"dateTime": "2026-10-19T09:00:00+02:00"}, "end": {"dateTime": "2026-10-19T09:15:00+02:00"},
            "conferenceData": {"conferenceSolution": {"name": "Zoom Meeting"},
                               "entryPoints": [{"entryPointType": "video", "uri": "https://zoom.us/j/1"}]},
            "attendees": [{"email": "me@example.com", "self": True, "responseStatus": "declined"}],
            "organizer": {"self": True}}, CALENDAR, {"11": "#dc2127"})
        self.assertEqual(event["color"], "#dc2127")
        self.assertEqual((event["join_url"], event["join_title"]), ("https://zoom.us/j/1", "Zoom Meeting"))
        self.assertEqual(event["status"], "declined")
        self.assertTrue(event["recurring"])
        self.assertEqual((event["parent_id"], event["occurrence_id"]), ("abc", "abc_20261019T070000Z"))

    def test_what_you_cannot_change_says_so(self):
        invitation = {"id": "i", "start": {"dateTime": "2026-10-19T09:00:00Z"}, "end": {"dateTime": "2026-10-19T10:00:00Z"},
                      "organizer": {"email": "boss@example.com"},
                      "attendees": [{"email": "boss@example.com"}, {"email": "me@example.com", "self": True}]}
        self.assertFalse(google.project_event(invitation, CALENDAR, {})["editable"])
        shared = dict(CALENDAR, accessRole="reader")
        self.assertFalse(google.project_event(dict(invitation, attendees=[]), shared, {})["editable"])
        self.assertTrue(google.project_event(dict(invitation, attendees=[]), CALENDAR, {})["editable"])

    def test_cancelled_days_and_working_locations_are_left_out(self):
        base = {"id": "x", "start": {"dateTime": "2026-10-19T09:00:00Z"}, "end": {"dateTime": "2026-10-19T10:00:00Z"}}
        self.assertIsNone(google.project_event(dict(base, status="cancelled"), CALENDAR, {}))
        self.assertIsNone(google.project_event(dict(base, eventType="workingLocation"), CALENDAR, {}))

    def test_only_the_calendars_shown_in_google_are_read(self):
        pretend = Pretend({("GET", "/users/me/calendarList"): {"items": [
            dict(CALENDAR, selected=True), {"id": "off@example.com", "accessRole": "owner"},
            {"id": "gone@example.com", "accessRole": "owner", "selected": True, "deleted": True}]}})
        pretend.pages = lambda path, params, limit: google.Google.pages(pretend, path, params, limit)
        self.assertEqual([c["id"] for c in google.listed_calendars(pretend)], ["me@example.com"])


class Weeks(unittest.TestCase):
    def test_events_are_filed_under_each_week_they_touch(self):
        pretend = Pretend({("GET", "/users/me/calendarList"): {"items": [dict(CALENDAR, selected=True)]},
                           ("GET", "/calendars/me%40example.com/events"): {"items": [
                               {"id": "trip", "summary": "Trip", "start": {"date": "2026-10-24"}, "end": {"date": "2026-10-28"}},
                               {"id": "zero", "summary": "Deadline", "start": {"dateTime": "2026-10-20T12:00:00Z"},
                                "end": {"dateTime": "2026-10-20T12:00:00Z"}}]}})
        pretend.pages = lambda path, params, limit: google.Google.pages(pretend, path, params, limit)
        weeks = google.read_weeks(pretend, ["2026-10-19", "2026-10-26"])
        self.assertEqual([sorted(e["id"] for e in w["events"]) for w in weeks], [["trip", "zero"], ["trip"]])
        query = [s for s in pretend.sent if s[1].endswith("/events")][0][2]
        self.assertEqual(query["singleEvents"], "true")

    def test_only_mondays_are_weeks(self):
        self.assertEqual(google.week_keys(["2026-10-20", "2026-10-26", "x", "2026-10-19", "2026-10-19"]),
                         ["2026-10-19", "2026-10-26"])


class Writing(unittest.TestCase):
    def owner(self, extra=None):
        answers = {("GET", "/users/me/calendarList/me%40example.com"): CALENDAR,
                   ("GET", "/users/me/calendarList/other%40example.com"): dict(CALENDAR, id="other@example.com")}
        answers.update(extra or {})
        return Pretend(answers)

    def test_a_new_event_is_sent_in_its_zone_and_quietly(self):
        pretend = self.owner({("POST", "/calendars/me%40example.com/events"): {"id": "new"}})
        google.create(pretend, {"title": "Dinner; rm -rf ~", "date": "2026-10-19", "startTime": "19:00", "endTime": "21:30",
                                "endDate": "2026-10-19", "timeZone": "Europe/Berlin", "calendarId": "me@example.com",
                                "location": "Café Luna", "remind": "30m"})
        method, path, params, body = pretend.sent[-1]
        self.assertEqual(params, {"sendUpdates": "none"})
        self.assertEqual(body["summary"], "Dinner; rm -rf ~")
        self.assertEqual(body["start"], {"dateTime": "2026-10-19T19:00:00", "timeZone": "Europe/Berlin"})
        self.assertEqual(body["end"], {"dateTime": "2026-10-19T21:30:00", "timeZone": "Europe/Berlin"})
        self.assertEqual(body["reminders"], {"useDefault": False, "overrides": [{"method": "popup", "minutes": 30}]})

    def test_all_day_ends_the_day_after_its_last_and_an_hour_is_the_default(self):
        start, end = google.schedule_body({"allDay": True}, "2026-10-13", "2026-10-16")
        self.assertEqual((start["date"], end["date"]), ("2026-10-13", "2026-10-17"))
        start, end = google.schedule_body({"startTime": "01:30", "timeZone": "Europe/Berlin"}, "2026-10-25", "2026-10-25")
        self.assertEqual(end["dateTime"], "2026-10-25T02:30:00")
        # The night the clocks go back has two 02:30s; an hour of real time
        # after 01:30 is the first.

    def test_a_red_eye_lands_the_next_day_and_a_skipped_hour_is_refused(self):
        start, end = google.schedule_body({"startTime": "22:00", "endTime": "07:00", "timeZone": "America/New_York",
                                           "endTimeZone": "Europe/Berlin"}, "2026-10-19", "2026-10-19")
        self.assertEqual(end, {"dateTime": "2026-10-20T07:00:00", "timeZone": "Europe/Berlin", "date": None})
        with self.assertRaises(google.Failure):
            google.schedule_body({"startTime": "02:30", "timeZone": "Europe/Berlin"}, "2026-03-29", "2026-03-29")

    def test_an_edit_sends_only_what_changed(self):
        path = "/calendars/me%40example.com/events/g1"
        pretend = self.owner({("GET", path): {"id": "g1", "organizer": {"self": True},
                                              "start": {"dateTime": "2026-10-19T09:00:00Z"}}})
        google.edit(pretend, {"event": {"seriesId": "g1", "calendarId": "me@example.com"}, "scope": "all",
                              "changes": {"title": "Gym", "remind": ""}})
        self.assertEqual(pretend.sent[-1], ("PATCH", path, {"sendUpdates": "none"},
                                            {"summary": "Gym", "reminders": {"useDefault": False, "overrides": []}}))

    def test_new_times_for_a_whole_series_keep_it_on_its_first_day(self):
        path = "/calendars/me%40example.com/events/abc"
        pretend = self.owner({("GET", path): {"id": "abc", "organizer": {"self": True}, "recurrence": ["RRULE:FREQ=DAILY"],
                                              "start": {"dateTime": "2026-09-01T07:00:00Z"}, "end": {"dateTime": "2026-09-01T07:15:00Z"}}})
        google.edit(pretend, {"event": {"seriesId": "abc_20261019T070000Z", "parentId": "abc", "recurring": True,
                                        "calendarId": "me@example.com"}, "scope": "all",
                              "changes": {"schedule": {"allDay": False, "date": "2026-10-19", "endDate": "2026-10-19",
                                                       "startTime": "10:00", "endTime": "10:30", "timeZone": "Europe/Berlin",
                                                       "endTimeZone": "", "dates": False}}})
        body = pretend.sent[-1][3]
        self.assertEqual(body["start"]["dateTime"], "2026-09-01T10:00:00")
        self.assertEqual(body["end"]["dateTime"], "2026-09-01T10:30:00")

    def test_guests_are_never_told_or_left_untold_behind_your_back(self):
        path = "/calendars/me%40example.com/events/g2"
        meeting = {"id": "g2", "organizer": {"self": True}, "start": {"dateTime": "2026-10-19T09:00:00Z"},
                   "attendees": [{"email": "me@example.com", "self": True}, {"email": "guest@example.com"}]}
        pretend = self.owner({("GET", path): meeting})
        with self.assertRaises(google.Failure):
            google.edit(pretend, {"event": {"seriesId": "g2", "calendarId": "me@example.com"}, "scope": "all",
                                  "changes": {"title": "Moved"}})
        google.edit(pretend, {"event": {"seriesId": "g2", "calendarId": "me@example.com"}, "scope": "all",
                              "changes": {"remind": "10m"}})
        self.assertEqual(pretend.sent[-1][0], "PATCH")
        with self.assertRaises(google.Failure):
            google.delete(pretend, {"event": {"seriesId": "g2", "calendarId": "me@example.com"}})
        self.assertNotIn("DELETE", [s[0] for s in pretend.sent])

    def test_moving_an_event_to_another_calendar(self):
        path = "/calendars/me%40example.com/events/g3"
        pretend = self.owner({("GET", path): {"id": "g3", "organizer": {"self": True}, "start": {"dateTime": "2026-10-19T09:00:00Z"}}})
        google.edit(pretend, {"event": {"seriesId": "g3", "calendarId": "me@example.com"}, "scope": "all",
                              "changes": {"calendarId": "other@example.com"}})
        self.assertEqual(pretend.sent[-1], ("POST", path + "/move", {"destination": "other@example.com", "sendUpdates": "none"}, None))

    def test_repeating_events_are_not_deleted_and_read_only_calendars_not_written(self):
        path = "/calendars/me%40example.com/events/g4"
        pretend = self.owner({("GET", path): {"id": "g4", "recurringEventId": "s", "organizer": {"self": True}}})
        with self.assertRaises(google.Failure):
            google.delete(pretend, {"event": {"seriesId": "g4", "calendarId": "me@example.com"}})
        reader = Pretend({("GET", "/users/me/calendarList/holidays%40example.com"): dict(CALENDAR, accessRole="reader")})
        with self.assertRaises(google.Failure):
            google.create(reader, {"title": "x", "date": "2026-10-19", "allDay": True, "calendarId": "holidays@example.com"})


class Failures(unittest.TestCase):
    def test_nothing_google_said_reaches_the_panel_but_a_sentence(self):
        class Error:
            def __init__(self, code, body):
                self.code, self.body = code, body

            def read(self, limit):
                return self.body
        self.assertIn("gws auth login", google.failure(Error(401, b"{}")))
        self.assertIn("Calendar access", google.failure(Error(403, b'{"error":{"errors":[{"reason":"insufficientPermissions"}]}}')))
        self.assertIn("slow down", google.failure(Error(429, b"secret event text")))
        self.assertNotIn("secret", google.failure(Error(400, b'{"error":{"message":"secret event text"}}')))

    def test_test_servers_are_only_ever_on_this_machine(self):
        os.environ["OMACAL_X"] = "https://evil.example.com"
        self.assertEqual(google.local_test_url("OMACAL_X", "https://www.googleapis.com"), "https://www.googleapis.com")
        os.environ["OMACAL_X"] = "http://127.0.0.1:8080/"
        self.assertEqual(google.local_test_url("OMACAL_X", "x"), "http://127.0.0.1:8080")


if __name__ == "__main__":
    report = io.StringIO()
    result = unittest.TextTestRunner(stream=report).run(unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    if not result.wasSuccessful():
        sys.stderr.write(report.getvalue())
        sys.exit(1)
    print("ok google [%s]: %d cases" % (os.environ.get("TZ", "local"), result.testsRun))
