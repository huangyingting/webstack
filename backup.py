#!/usr/bin/env python3
"""Logical PostgreSQL cluster backups using Azure VM identity and Blob REST."""

import argparse
import base64
import datetime as dt
import email.utils
import gzip
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo


LOG = logging.getLogger("webstack-backup")
CHUNK_SIZE = 8 * 1024 * 1024
DAILY_NAME = re.compile(r"^daily/(\d{4}-\d{2}-\d{2})\.sql\.gz$")
WEEKLY_NAME = re.compile(r"^weekly/(\d{4}-W\d{2})\.sql\.gz$")


def expired_blobs(names, today):
    daily_cutoff = today - dt.timedelta(days=6)
    monday = today - dt.timedelta(days=today.weekday())
    weekly_cutoff = monday - dt.timedelta(weeks=15)
    for name in names:
        daily = DAILY_NAME.fullmatch(name)
        weekly = WEEKLY_NAME.fullmatch(name)
        if daily:
            if dt.date.fromisoformat(daily[1]) < daily_cutoff:
                yield name
        elif weekly:
            year, week = weekly[1].split("-W")
            if dt.date.fromisocalendar(int(year), int(week), 1) < weekly_cutoff:
                yield name


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK_SIZE), b""):
            digest.update(block)
    return digest.hexdigest()


class BlobClient:
    def __init__(self, account, container, identity_client_id=None):
        if not re.fullmatch(r"[a-z0-9]{3,24}", account):
            raise ValueError("Invalid storage account name")
        if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])", container):
            raise ValueError("Invalid container name")
        self.base = f"https://{account}.blob.core.windows.net/{container}"
        self.token = None
        self.expires = 0
        self.identity_client_id = identity_client_id
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def access_token(self):
        if self.token and self.expires > time.time() + 120:
            return self.token
        parameters = {
            "api-version": "2018-02-01",
            "resource": "https://storage.azure.com/",
        }
        if self.identity_client_id:
            parameters["client_id"] = self.identity_client_id
        query = urllib.parse.urlencode(parameters)
        request = urllib.request.Request(
            "http://169.254.169.254/metadata/identity/oauth2/token?" + query,
            headers={"Metadata": "true"},
        )
        for attempt in range(6):
            try:
                with self.http.open(request, timeout=15) as response:
                    result = json.load(response)
                break
            except urllib.error.HTTPError as error:
                if error.code not in (404, 408, 429, 500, 502, 503, 504) or attempt == 5:
                    raise
                LOG.warning("Identity request retry after HTTP %s", error.code)
            except (urllib.error.URLError, TimeoutError) as error:
                if attempt == 5:
                    raise
                LOG.warning("Identity request retry after %s", error)
            time.sleep(min(2 ** attempt, 16))
        self.token = result["access_token"]
        self.expires = int(result["expires_on"])
        return self.token

    def request(self, method, name="", query=None, data=None, headers=None):
        url = self.base
        if name:
            url += "/" + urllib.parse.quote(name, safe="/")
        if query:
            url += "?" + urllib.parse.urlencode(query)
        for attempt in range(6):
            request_headers = {
                "Authorization": "Bearer " + self.access_token(),
                "x-ms-version": "2023-11-03",
                "x-ms-date": email.utils.formatdate(usegmt=True),
            }
            request_headers.update(headers or {})
            request = urllib.request.Request(
                url, data=data, headers=request_headers, method=method,
            )
            try:
                with self.http.open(request, timeout=120) as response:
                    return response.read(), response.headers
            except urllib.error.HTTPError as error:
                if error.code == 401:
                    self.token = None
                elif error.code not in (408, 429, 500, 502, 503, 504):
                    raise
                if attempt == 5:
                    raise
                LOG.warning("Blob %s retry after HTTP %s", method, error.code)
            except (urllib.error.URLError, TimeoutError) as error:
                if attempt == 5:
                    raise
                LOG.warning("Blob %s retry after %s", method, error)
            time.sleep(min(2 ** attempt, 16))
        raise RuntimeError("Unreachable retry state")

    def list_names(self, prefix):
        marker = ""
        names = []
        while True:
            body, _ = self.request("GET", query={
                "restype": "container", "comp": "list",
                "prefix": prefix, "marker": marker,
            })
            root = ET.fromstring(body)
            names.extend(element.text for element in root.findall("./Blobs/Blob/Name"))
            marker = root.findtext("NextMarker") or ""
            if not marker:
                return names

    def wait_for_access(self, seconds):
        deadline = time.monotonic() + seconds
        while True:
            try:
                return self.list_names("")
            except urllib.error.HTTPError as error:
                if error.code != 403 or time.monotonic() >= deadline:
                    raise
                LOG.warning("Waiting for managed-identity Blob RBAC propagation")
                time.sleep(min(15, max(0, deadline - time.monotonic())))

    def upload(self, name, path, sha256):
        block_ids = []
        upload_id = uuid.uuid4().hex
        with Path(path).open("rb") as stream:
            for index, block in enumerate(iter(lambda: stream.read(CHUNK_SIZE), b"")):
                if index >= 50000:
                    raise ValueError("Backup exceeds the supported block count")
                block_id = base64.b64encode(
                    f"{upload_id}-{index:08d}".encode("ascii"),
                ).decode("ascii")
                block_ids.append(block_id)
                self.request("PUT", name, {"comp": "block", "blockid": block_id},
                             data=block, headers={
                                 "Content-MD5": base64.b64encode(
                                     hashlib.md5(block, usedforsecurity=False).digest(),
                                 ).decode("ascii"),
                                 "Content-Type": "application/octet-stream",
                             })
        if not block_ids:
            raise ValueError("Refusing to upload an empty backup")
        root = ET.Element("BlockList")
        for block_id in block_ids:
            ET.SubElement(root, "Latest").text = block_id
        self.request("PUT", name, {"comp": "blocklist"},
                     data=ET.tostring(root, encoding="utf-8", xml_declaration=True),
                     headers={
                         "Content-Type": "application/xml",
                         "x-ms-blob-content-type": "application/gzip",
                         "x-ms-meta-sha256": sha256,
                     })
        _, metadata = self.request("HEAD", name)
        if (metadata.get("x-ms-meta-sha256") != sha256
                or int(metadata["Content-Length"]) != Path(path).stat().st_size):
            raise RuntimeError(f"Uploaded backup verification failed: {name}")
        LOG.info("Uploaded and checked %s (%s bytes)", name, Path(path).stat().st_size)

    def delete(self, name):
        self.request("DELETE", name)
        LOG.info("Deleted expired backup %s", name)


def dump_cluster(destination):
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(
            ["runuser", "-u", "postgres", "--", "pg_dumpall",
             "--quote-all-identifiers"],
            stdout=subprocess.PIPE, stderr=errors,
        )
        try:
            with gzip.open(destination, "wb", compresslevel=3) as output:
                shutil.copyfileobj(process.stdout, output, length=1024 * 1024)
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.wait()
        if process.returncode:
            errors.seek(0)
            detail = errors.read(4096).decode("utf-8", errors="replace")
            raise RuntimeError(f"pg_dumpall failed ({process.returncode}): {detail}")
    with gzip.open(destination, "rb") as stream:
        while stream.read(CHUNK_SIZE):
            pass
    return file_hash(destination)


def run_backup(config, client, now, work_dir, wait_seconds=0):
    today = now.astimezone(ZoneInfo(config["time_zone"])).date()
    iso_year, iso_week, _ = today.isocalendar()
    daily = f"daily/{today.isoformat()}.sql.gz"
    weekly = f"weekly/{iso_year}-W{iso_week:02d}.sql.gz"
    client.wait_for_access(wait_seconds)
    weekly_names = client.list_names("weekly/")
    if shutil.disk_usage(work_dir).free < 1024 ** 3:
        raise RuntimeError("Less than 1 GiB of free space for the local dump")
    with tempfile.TemporaryDirectory(prefix="dump-", dir=work_dir) as temporary:
        path = Path(temporary) / "cluster.sql.gz"
        sha256 = dump_cluster(path)
        client.upload(daily, path, sha256)
        if weekly not in weekly_names:
            client.upload(weekly, path, sha256)
        # Delete only after both required backup uploads have succeeded.
        names = client.list_names("daily/") + client.list_names("weekly/")
        for name in expired_blobs(names, today):
            client.delete(name)
    return {"last_success": now.isoformat(), "daily": daily, "weekly": weekly,
            "sha256": sha256}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="/etc/webstack/config.json")
    parser.add_argument("--wait-for-access", type=int, default=0)
    arguments = parser.parse_args()
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config = json.loads(Path(arguments.config).read_text())
    work_dir = Path("/var/lib/webstack-backup")
    work_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    client = BlobClient(
        config["storage_account"], config["container"], config["identity_client_id"],
    )
    result = run_backup(
        config, client, dt.datetime.now(dt.timezone.utc),
        work_dir, arguments.wait_for_access,
    )
    temporary = work_dir / "last-success.json.tmp"
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(work_dir / "last-success.json")
    LOG.info("Backup completed: %s", result["daily"])


if __name__ == "__main__":
    main()
