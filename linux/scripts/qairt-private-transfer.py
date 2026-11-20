#!/usr/bin/env python3
"""Deliver a verified SDK over an existing private route; no service setup or peer authentication is provided."""

import argparse
import contextlib
import datetime
import fcntl
import hashlib
import http.client
import importlib
import ipaddress
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import time
from collections.abc import Generator
from pathlib import Path
from typing import BinaryIO
from urllib.parse import urlsplit

HANDOFF = importlib.import_module("qairt-key-handoff")
CHUNK = 1024 * 1024


def check_private_descriptor(descriptor: int) -> None:
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("private file permissions are unsafe")


@contextlib.contextmanager
def private_file(path: Path) -> Generator[BinaryIO, None, None]:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        check_private_descriptor(source.fileno())
        yield source


def endpoint(directory: Path, fingerprint: str, object_path: str) -> tuple[str, str, int | None, str]:
    record = HANDOFF.inspect(directory)
    if fingerprint != record["sha256_spki"]:
        raise ValueError("recipient fingerprint mismatch")
    with private_file(directory / "endpoint.txt") as source:
        parsed = urlsplit(HANDOFF.endpoint_payload(source.read(319)).decode("utf-8"))
    address = ipaddress.ip_address(parsed.hostname or "")
    if not address.is_private or address.is_unspecified or address.is_multicast:
        raise ValueError("the existing route must use a literal private address")
    if not re.fullmatch(r"/preseed/[A-Za-z0-9][A-Za-z0-9_.-]*\.zip", object_path):
        raise ValueError("the target must be one preseed ZIP object")
    return parsed.scheme, str(address), parsed.port, parsed.path.rstrip("/") + object_path


@contextlib.contextmanager
def transfer_lock(directory: Path) -> Generator[None, None, None]:
    descriptor = os.open(directory / "transfer.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a+") as lock:
        check_private_descriptor(lock.fileno())
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def remaining(deadline: float) -> float:
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("private transfer deadline exceeded")
    return min(15, value)


def hash_stream(source: BinaryIO | http.client.HTTPResponse, size: int, deadline: float) -> tuple[int, str]:
    digest = hashlib.sha256()
    count = 0
    while True:
        remaining(deadline)
        block = source.read(min(CHUNK, size - count + 1))
        if not block:
            break
        count += len(block)
        if count > size:
            raise ValueError("object exceeds the expected size")
        digest.update(block)
    return count, digest.hexdigest()


class PrivateObject:
    def __init__(self, route: tuple[str, str, int | None, str], deadline: float) -> None:
        self.scheme, self.host, self.port, self.path = route
        self.deadline = deadline
        self.last_status: int | None = None

    def connect(self) -> http.client.HTTPConnection:
        constructor = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return constructor(self.host, self.port, timeout=remaining(self.deadline))

    def head(self) -> int:
        with contextlib.closing(self.connect()) as connection:
            connection.request("HEAD", self.path)
            with connection.getresponse() as response:
                self.last_status = response.status
                return response.status

    def verify(self, size: int, digest: str) -> None:
        with contextlib.closing(self.connect()) as connection:
            connection.request("GET", self.path)
            with connection.getresponse() as response:
                self.last_status = response.status
                if response.status != 200 or hash_stream(response, size, self.deadline) != (size, digest):
                    raise ValueError("remote object bytes do not match")

    def put(self, source: BinaryIO, size: int, digest: str) -> int:
        with contextlib.closing(self.connect()) as connection:
            connection.putrequest("PUT", self.path)
            connection.putheader("Content-Length", str(size))
            connection.putheader("Content-Type", "application/octet-stream")
            connection.putheader("If-None-Match", "*")
            connection.endheaders()
            sent = 0
            actual = hashlib.sha256()
            while block := source.read(CHUNK):
                remaining(self.deadline)
                sent += len(block)
                if sent > size:
                    raise ValueError("source grew during transfer")
                actual.update(block)
                connection.send(block)
            if sent != size or actual.hexdigest() != digest:
                raise ValueError("source changed during transfer")
            with connection.getresponse() as response:
                self.last_status = response.status
                if response.status not in (200, 201, 204, 412):
                    raise ValueError("conditional private PUT failed")
                return response.status


def file_identity(source: BinaryIO) -> tuple[int, int, int, int, int]:
    info = os.fstat(source.fileno())
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("the SDK source must be a regular file")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def deliver(directory: Path, archive: Path, fingerprint: str, object_path: str, size: int,
            digest: str, timeout: float) -> dict[str, str | int]:
    if size <= 0 or not re.fullmatch(r"[0-9a-f]{64}", digest) or not math.isfinite(timeout) or not 0 < timeout <= 3600:
        raise ValueError("invalid transfer binding or timeout")
    deadline = time.monotonic() + timeout
    route = endpoint(directory, fingerprint, object_path)
    with transfer_lock(directory), os.fdopen(os.open(archive, os.O_RDONLY | os.O_NOFOLLOW), "rb") as source:
        identity = file_identity(source)
        if identity[2] != size or hash_stream(source, size, deadline) != (size, digest):
            raise ValueError("source SDK bytes do not match")
        if file_identity(source) != identity:
            raise ValueError("source changed during verification")
        remote = PrivateObject(route, deadline)
        status = remote.head()
        verdict = "already-present-verified"
        if status == 404:
            source.seek(0)
            status = remote.put(source, size, digest)
            verdict = "already-present-verified" if status == 412 else "uploaded-verified"
        elif status != 200:
            raise ValueError("private object HEAD failed")
        remote.verify(size, digest)
        if file_identity(source) != identity:
            raise ValueError("source changed before completion")
    return {"status": verdict, "bytes": size, "sha256": digest, "put_or_head_status": status}


def deadline_signal(_signal: int, _frame: object) -> None:
    raise TimeoutError("private transfer deadline exceeded")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--object-path", required=True)
    parser.add_argument("--bytes", required=True, type=int, dest="size")
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    record: dict[str, object] = {"status": "running", "started_at": datetime.datetime.now(datetime.UTC).isoformat()}
    try:
        if not math.isfinite(args.timeout) or not 0 < args.timeout <= 3600:
            raise ValueError("invalid deadline")
        descriptor = os.open(args.receipt, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w+") as receipt:
            receipt.write(json.dumps(record) + "\n")
            receipt.flush()
            try:
                signal.signal(signal.SIGALRM, deadline_signal)
                signal.setitimer(signal.ITIMER_REAL, args.timeout)
                record.update(deliver(args.directory, args.archive, args.fingerprint, args.object_path,
                                      args.size, args.sha256, args.timeout))
            except (OSError, ValueError, http.client.HTTPException, subprocess.TimeoutExpired) as error:
                record.update(status="failed", error_type=type(error).__name__)
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                record["finished_at"] = datetime.datetime.now(datetime.UTC).isoformat()
                receipt.seek(0)
                receipt.write(json.dumps(record, indent=2) + "\n")
                receipt.truncate()
                receipt.flush()
                os.fsync(receipt.fileno())
    except (OSError, ValueError):
        print("qairt-private-transfer: operation failed; private details withheld", file=sys.stderr)
        return 1
    print(json.dumps(record, indent=2))
    return 0 if record["status"] in ("uploaded-verified", "already-present-verified") else 1


if __name__ == "__main__":
    sys.exit(main())
