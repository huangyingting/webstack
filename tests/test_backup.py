import argparse
import datetime as dt
from email.message import Message
import gzip
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backup
import importlib.util

spec = importlib.util.spec_from_file_location(
    "create_app", Path(__file__).resolve().parents[1] / "create-app.py",
)
create_app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(create_app)


class FakeBlobs:
    def __init__(self, names=(), fail_upload=None):
        self.names = set(names)
        self.uploaded = []
        self.deleted = []
        self.fail_upload = fail_upload

    def wait_for_access(self, seconds):
        return list(self.names)

    def list_names(self, prefix):
        return sorted(name for name in self.names if name.startswith(prefix))

    def upload(self, name, path, digest):
        if name == self.fail_upload:
            raise RuntimeError("Simulated upload failure")
        self.uploaded.append(name)
        self.names.add(name)

    def delete(self, name):
        self.deleted.append(name)
        self.names.remove(name)


class RetentionTests(unittest.TestCase):
    def test_exactly_seven_days_and_sixteen_weeks_remain(self):
        today = dt.date(2026, 10, 9)
        daily = [f"daily/{(today - dt.timedelta(days=i)).isoformat()}.sql.gz" for i in range(30)]
        monday = today - dt.timedelta(days=today.weekday())
        weekly = []
        for i in range(30):
            year, week, _ = (monday - dt.timedelta(weeks=i)).isocalendar()
            weekly.append(f"weekly/{year}-W{week:02d}.sql.gz")
        names = daily + weekly
        remaining = set(names) - set(backup.expired_blobs(names, today))
        self.assertEqual(len([n for n in remaining if n.startswith("daily/")]), 7)
        self.assertEqual(len([n for n in remaining if n.startswith("weekly/")]), 16)
        self.assertIn(daily[6], remaining)
        self.assertNotIn(daily[7], remaining)
        self.assertIn(weekly[15], remaining)
        self.assertNotIn(weekly[16], remaining)

    def test_iso_year_boundary(self):
        today = dt.date(2027, 1, 1)
        self.assertEqual(today.isocalendar()[:2], (2026, 53))
        names = ["weekly/2026-W53.sql.gz", "weekly/2026-W38.sql.gz", "weekly/2026-W37.sql.gz"]
        self.assertEqual(list(backup.expired_blobs(names, today)), [names[2]])

    def test_unrelated_and_future_blobs_are_not_deleted(self):
        names = ["other/2020-01-01.sql.gz", "daily/readme.txt", "daily/2027-01-01.sql.gz"]
        self.assertEqual(list(backup.expired_blobs(names, dt.date(2026, 10, 9))), [])


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.config = {"time_zone": "Asia/Shanghai"}
        self.now = dt.datetime(2026, 10, 8, 19, tzinfo=dt.timezone.utc)
        self.disk = mock.patch.object(
            backup.shutil, "disk_usage", return_value=mock.Mock(free=10 * 1024 ** 3),
        )
        self.disk.start()
        self.addCleanup(self.disk.stop)
        self.dump = mock.patch.object(backup, "dump_cluster", side_effect=self.make_dump)
        self.dump.start()
        self.addCleanup(self.dump.stop)

    def make_dump(self, path):
        with gzip.open(path, "wb") as file:
            file.write(b"-- test SQL\n")
        return backup.file_hash(path)

    def run_backup(self, client, now=None):
        return backup.run_backup(
            self.config, client, now or self.now, self.temporary.name,
        )

    def test_initial_run_creates_daily_and_weekly(self):
        blobs = FakeBlobs()
        result = self.run_backup(blobs)
        self.assertEqual(blobs.uploaded, [
            "daily/2026-10-09.sql.gz", "weekly/2026-W41.sql.gz",
        ])
        self.assertEqual(result["daily"], blobs.uploaded[0])

    def test_weekday_does_not_overwrite_existing_weekly(self):
        blobs = FakeBlobs(["weekly/2026-W41.sql.gz"])
        self.run_backup(blobs)
        self.assertEqual(blobs.uploaded, ["daily/2026-10-09.sql.gz"])

    def test_sunday_does_not_create_a_second_weekly_backup(self):
        blobs = FakeBlobs(["weekly/2026-W41.sql.gz"])
        sunday = dt.datetime(2026, 10, 10, 19, tzinfo=dt.timezone.utc)
        self.run_backup(blobs, sunday)
        self.assertEqual(blobs.uploaded, ["daily/2026-10-11.sql.gz"])
        self.assertEqual(len([n for n in blobs.names if n.startswith("weekly/")]), 1)

    def test_monday_creates_the_next_weekly_backup(self):
        blobs = FakeBlobs(["weekly/2026-W41.sql.gz"])
        monday = dt.datetime(2026, 10, 11, 19, tzinfo=dt.timezone.utc)
        self.run_backup(blobs, monday)
        self.assertEqual(blobs.uploaded, [
            "daily/2026-10-12.sql.gz", "weekly/2026-W42.sql.gz",
        ])

    def test_repeated_run_does_not_create_extra_daily_slots(self):
        blobs = FakeBlobs()
        self.run_backup(blobs)
        self.run_backup(blobs)
        self.assertEqual(len(blobs.names), 2)

    def test_success_prunes_expired_only(self):
        blobs = FakeBlobs(["daily/2026-10-02.sql.gz", "daily/2026-10-03.sql.gz"])
        self.run_backup(blobs)
        self.assertEqual(blobs.deleted, ["daily/2026-10-02.sql.gz"])

    def test_weekly_failure_never_deletes_old_backups(self):
        blobs = FakeBlobs(["daily/2026-01-01.sql.gz"], fail_upload="weekly/2026-W41.sql.gz")
        with self.assertRaisesRegex(RuntimeError, "upload failure"):
            self.run_backup(blobs)
        self.assertEqual(blobs.deleted, [])
        self.assertIn("daily/2026-01-01.sql.gz", blobs.names)

    def test_daily_failure_never_deletes_old_backups(self):
        blobs = FakeBlobs(["daily/2026-01-01.sql.gz"], fail_upload="daily/2026-10-09.sql.gz")
        with self.assertRaises(RuntimeError):
            self.run_backup(blobs)
        self.assertEqual(blobs.uploaded, [])
        self.assertEqual(blobs.deleted, [])

    def test_dump_failure_is_not_success(self):
        with mock.patch.object(backup, "dump_cluster", side_effect=RuntimeError("dump failed")):
            blobs = FakeBlobs()
            with self.assertRaisesRegex(RuntimeError, "dump failed"):
                self.run_backup(blobs)
            self.assertEqual(blobs.uploaded, [])

    def test_low_disk_space_fails_before_dump(self):
        with mock.patch.object(backup.shutil, "disk_usage", return_value=mock.Mock(free=1)):
            with self.assertRaisesRegex(RuntimeError, "free space"):
                self.run_backup(FakeBlobs())

    def test_timezone_controls_date_not_utc(self):
        blobs = FakeBlobs()
        self.run_backup(blobs)
        self.assertIn("daily/2026-10-09.sql.gz", blobs.names)


class BlobTransportTests(unittest.TestCase):
    def setUp(self):
        self.client = backup.BlobClient("testaccount", "pg-backups", "test-client-id")

    def test_paginated_listing(self):
        self.client.request = mock.Mock(side_effect=[
            (b"<EnumerationResults><Blobs><Blob><Name>daily/a</Name></Blob></Blobs>"
             b"<NextMarker>next page</NextMarker></EnumerationResults>", {}),
            (b"<EnumerationResults><Blobs><Blob><Name>daily/b</Name></Blob></Blobs>"
             b"<NextMarker /></EnumerationResults>", {}),
        ])
        self.assertEqual(self.client.list_names("daily/"), ["daily/a", "daily/b"])
        self.assertEqual(self.client.request.call_args_list[1].kwargs["query"]["marker"], "next page")

    def test_block_upload_commit_and_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.gz"
            path.write_bytes(b"0123456789")
            digest = backup.file_hash(path)
            calls = []

            def request(method, name, query=None, data=None, headers=None):
                calls.append((method, query, data))
                if method == "HEAD":
                    return b"", {"x-ms-meta-sha256": digest, "Content-Length": "10"}
                return b"", {}

            self.client.request = request
            with mock.patch.object(backup, "CHUNK_SIZE", 4):
                self.client.upload("daily/test.sql.gz", path, digest)
            self.assertEqual([entry[2] for entry in calls[:3]], [b"0123", b"4567", b"89"])
            committed = ET.fromstring(calls[3][2])
            self.assertEqual(len(committed.findall("Latest")), 3)
            self.assertEqual(calls[4][0], "HEAD")

    def test_verification_mismatch_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.gz"
            path.write_bytes(b"not empty")
            self.client.request = mock.Mock(side_effect=[
                (b"", {}), (b"", {}),
                (b"", {"x-ms-meta-sha256": "wrong", "Content-Length": "9"}),
            ])
            with self.assertRaisesRegex(RuntimeError, "verification failed"):
                self.client.upload("daily/test.sql.gz", path, backup.file_hash(path))

    def test_transient_storage_error_is_retried(self):
        self.client.access_token = mock.Mock(return_value="token")
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"success"
        response.headers = Message()
        error = urllib.error.HTTPError("url", 503, "busy", {}, None)
        self.client.http.open = mock.Mock(side_effect=[error, response])
        with mock.patch.object(backup.time, "sleep"):
            self.assertEqual(self.client.request("GET")[0], b"success")
        self.assertEqual(self.client.http.open.call_count, 2)

    def test_permission_error_is_not_silently_retried(self):
        self.client.access_token = mock.Mock(return_value="token")
        error = urllib.error.HTTPError("url", 403, "denied", {}, None)
        self.client.http.open = mock.Mock(side_effect=error)
        with self.assertRaises(urllib.error.HTTPError):
            self.client.request("GET")
        self.assertEqual(self.client.http.open.call_count, 1)

    def test_identity_request_selects_expected_client(self):
        response = mock.MagicMock()
        response.__enter__.return_value = io.StringIO(json.dumps({
            "access_token": "test-token", "expires_on": "9999999999",
        }))
        self.client.http.open = mock.Mock(return_value=response)
        self.assertEqual(self.client.access_token(), "test-token")
        request = self.client.http.open.call_args.args[0]
        self.assertIn("client_id=test-client-id", request.full_url)
        self.assertEqual(request.get_header("Metadata"), "true")


class DumpFailureTests(unittest.TestCase):
    def test_failed_pg_dumpall_is_not_accepted_as_a_valid_gzip(self):
        process = mock.Mock(
            stdout=io.BytesIO(b"-- partial but gzip-compressible SQL\n"), returncode=1,
        )
        process.poll.return_value = 1
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(backup.subprocess, "Popen", return_value=process):
                with self.assertRaisesRegex(RuntimeError, "pg_dumpall failed"):
                    backup.dump_cluster(Path(directory) / "cluster.sql.gz")


class AppValidationTests(unittest.TestCase):
    def test_identifiers_and_domains(self):
        self.assertEqual(create_app.identifier("app_a"), "app_a")
        self.assertEqual(create_app.domain_name("app.example.com"), "app.example.com")
        for value in ("../etc", "App", "app;echo", "a" * 41):
            with self.assertRaises(argparse.ArgumentTypeError):
                create_app.identifier(value)
        for value in ("localhost", "example.com\n}", "a..example.com"):
            with self.assertRaises(argparse.ArgumentTypeError):
                create_app.domain_name(value)


if __name__ == "__main__":
    unittest.main()
