import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("google_backend", Path(__file__).parents[1] / "backends/google.py")
google = importlib.util.module_from_spec(spec)
spec.loader.exec_module(google)

CALENDAR = {"id": "team@example.test", "summary": "Team", "selected": True,
            "accessRole": "writer", "timeZone": "America/Chicago", "backgroundColor": "#abcdef",
            "defaultReminders": [{"method": "popup", "minutes": 30}, {"method": "email", "minutes": 60}]}
EVENT = {"id": "abcd" * 40, "summary": "Meeting", "start": {"dateTime": "2026-09-28T09:00:00-05:00"},
         "end": {"dateTime": "2026-09-28T10:00:00-05:00"}, "reminders": {"useDefault": True}}


class GoogleTests(unittest.TestCase):
    def test_event_projection(self):
        result = google.project_event({**EVENT, "recurringEventId": "series", "attendees": [
            {"self": True, "responseStatus": "declined"}], "conferenceData": {"entryPoints": [
            {"entryPointType": "phone", "uri": "tel:123"},
            {"entryPointType": "video", "uri": "https://meet.example.test/room"}]}}, CALENDAR)
        self.assertEqual(result["id"], EVENT["id"])
        self.assertEqual(result["calendar_id"], CALENDAR["id"])
        self.assertTrue(result["recurring"])
        self.assertTrue(result["writable"])
        self.assertEqual(result["reminders"], ["2026-09-28T13:30:00+00:00"])
        self.assertEqual(result["status"], "declined")
        self.assertEqual(result["join_url"], "https://meet.example.test/room")

    def test_all_day_zone_and_exclusive_end(self):
        event = {**EVENT, "start": {"date": "2026-09-28"}, "end": {"date": "2026-09-30"}}
        result = google.project_event(event, CALENDAR)
        self.assertEqual(result["starts_at"], "2026-09-28")
        self.assertEqual(result["ends_at"], "2026-09-30")
        self.assertEqual(result["reminders"], ["2026-09-28T04:30:00+00:00"])

    def test_overrides_replace_defaults_and_email_does_not_fire(self):
        event = {**EVENT, "reminders": {"useDefault": False, "overrides": [{"method": "email", "minutes": 10}]}}
        self.assertEqual(google.project_event(event, CALENDAR)["reminders"], [])
        event["reminders"]["overrides"].append({"method": "popup", "minutes": 10})
        self.assertEqual(google.project_event(event, CALENDAR)["reminders"], ["2026-09-28T13:50:00+00:00"])
        self.assertIsNone(google.project_event({"id": "cancelled", "status": "cancelled"}, CALENDAR))

    def test_pagination(self):
        with patch.object(google, "api", side_effect=[{"items": [1], "nextPageToken": "two"}, {"items": [2]}]) as api:
            self.assertEqual(google.pages("events", {"calendarId": "primary"}, 10), [1, 2])
            self.assertEqual(api.call_args.args[2]["pageToken"], "two")
        with patch.object(google, "api", return_value={"items": [1], "nextPageToken": "loop"}):
            with self.assertRaises(google.BackendError):
                google.pages("events", {}, 10)
        with patch.object(google, "api", return_value={"items": [1, 2]}):
            with self.assertRaises(google.BackendError):
                google.pages("events", {}, 1)

    def test_calendar_visibility_and_permission(self):
        with patch.object(google, "pages", return_value=[CALENDAR,
                {**CALENDAR, "id": "hidden", "selected": False},
                {**CALENDAR, "id": "deleted", "deleted": True},
                {**CALENDAR, "id": "freebusy", "accessRole": "freeBusyReader"},
                {**CALENDAR, "id": "reader", "accessRole": "reader"}]):
            selected = google.calendars()
            self.assertEqual([c["id"] for c in selected], [CALENDAR["id"], "reader"])
            self.assertFalse(google.project_calendar(selected[1])["owned"])

    def test_account_guard(self):
        with patch.object(google, "cli", return_value={"user": "other@example.test", "token_valid": True}):
            with self.assertRaises(google.BackendError):
                google.verify_account("calendar@example.test")
        with self.assertRaises(google.BackendError):
            google.verify_account("")
        with patch.object(google, "cli", return_value={"user": "calendar@example.test", "has_refresh_token": True}):
            google.verify_account("calendar@example.test")

    def test_fetch_week_expands_recurrence_and_uses_dst_boundaries(self):
        old = os.environ.get("TZ")
        os.environ["TZ"] = "America/Chicago"
        time.tzset()
        try:
            with patch.object(google, "pages", return_value=[EVENT]) as pages:
                result = google.fetch_week("2026-03-02", [CALENDAR])
                params = pages.call_args.args[1]
                self.assertEqual(params["timeMin"], "2026-03-02T00:00:00-06:00")
                self.assertEqual(params["timeMax"], "2026-03-09T00:00:00-05:00")
                self.assertTrue(params["singleEvents"])
                self.assertFalse(params["showDeleted"])
                self.assertEqual(len(result["events"]), 1)
        finally:
            if old is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old
            time.tzset()

    def test_create_body(self):
        request = {"title": "Meeting", "date": "2026-09-28", "endDate": "2026-09-28", "allDay": True}
        body = google.create_body(request)
        self.assertEqual(body["start"], {"date": "2026-09-28"})
        self.assertEqual(body["end"], {"date": "2026-09-29"})
        self.assertEqual(body["reminders"], {"useDefault": False, "overrides": []})
        body = google.create_body({**request, "allDay": False, "startTime": "23:30", "remind": "30m"})
        start = dt.datetime.fromisoformat(body["start"]["dateTime"])
        end = dt.datetime.fromisoformat(body["end"]["dateTime"])
        self.assertEqual(end - start, dt.timedelta(hours=1))
        self.assertEqual(end.day, 29)
        self.assertEqual(body["reminders"]["overrides"], [{"method": "popup", "minutes": 30}])

    def test_write_permissions_and_notification_policy(self):
        request = {"calendarId": CALENDAR["id"], "title": "Meeting", "date": "2026-09-28", "allDay": True}
        with patch.object(google, "api", side_effect=[CALENDAR, {"id": "new"}]) as api:
            self.assertTrue(google.create(request)["ok"])
            self.assertEqual(api.call_args.args[2]["sendUpdates"], "none")
            self.assertNotIn("attendees", api.call_args.args[3])
        with patch.object(google, "api", return_value={**CALENDAR, "accessRole": "reader"}) as api:
            with self.assertRaises(google.BackendError):
                google.create(request)
            self.assertEqual(api.call_count, 1)
        for event in [{"recurrence": ["RRULE:FREQ=DAILY"]}, {"recurringEventId": "series"}, {"attendees": [{"email": "guest@example.test"}]}]:
            with patch.object(google, "api", side_effect=[CALENDAR, event]) as api:
                with self.assertRaises(google.BackendError):
                    google.delete({"calendarId": CALENDAR["id"], "id": "event"})
                self.assertEqual(api.call_count, 2)
        with patch.object(google, "api", side_effect=[CALENDAR, EVENT, {}]) as api:
            self.assertTrue(google.delete({"calendarId": CALENDAR["id"], "id": "event"})["ok"])
            self.assertEqual(api.call_args.args[1], "delete")

    def test_errors_never_become_an_empty_successful_calendar(self):
        output = io.StringIO()
        with patch.object(google, "verify_account"), patch.object(google, "calendars", side_effect=google.BackendError("Offline")), contextlib.redirect_stdout(output):
            code = google.main(["google.py", "events", "calendar@example.test", '["2026-09-28"]'])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue()), {"ok": False, "error": "Offline"})

    def test_real_subprocess_boundary_uses_json_argv_not_shell(self):
        # A disposable gws executable exercises Python -> CLI -> JSON without Google access.
        with tempfile.TemporaryDirectory() as folder:
            fake = Path(folder) / "gws"
            fake.write_text('''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
if args == ["auth", "status"]:
    print(json.dumps({"user": "calendar@example.test", "token_valid": True}))
elif args[:3] == ["calendar", "calendarList", "get"]:
    print(json.dumps({"accessRole": "writer"}))
elif args[:3] == ["calendar", "events", "insert"]:
    body = json.loads(args[args.index("--json") + 1])
    assert body["summary"] == '"; touch /tmp/omacal-should-not-exist; #'
    print(json.dumps({"id": "created"}))
else:
    sys.exit(2)
''')
            fake.chmod(0o755)
            output = io.StringIO()
            request = {"calendarId": CALENDAR["id"], "title": '"; touch /tmp/omacal-should-not-exist; #',
                       "date": "2026-09-28", "allDay": True}
            with patch.dict(os.environ, {"PATH": folder + os.pathsep + os.environ["PATH"]}), contextlib.redirect_stdout(output):
                code = google.main(["google.py", "create", "calendar@example.test", json.dumps(request)])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(output.getvalue()), {"ok": True})


if __name__ == "__main__":
    unittest.main()
