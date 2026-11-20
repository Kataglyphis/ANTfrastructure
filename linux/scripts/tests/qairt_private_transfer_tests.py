#!/usr/bin/env python3
"""Local HTTP fixtures prove transfer guards, not the Windows service, peer identity or a real SDK receipt."""

from __future__ import annotations

import hashlib
import http.server
import importlib
import io
import json
import os
import socket
import subprocess
import sys
import threading
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import cast
from unittest.mock import patch

from qairt_key_fixture import QairtKeyFixture

SCRIPT = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(SCRIPT.parent))
TRANSFER = importlib.import_module(SCRIPT.stem)
HANDOFF = importlib.import_module("qairt-key-handoff")
PAYLOAD = b"private-sdk-fixture\x00" * 1024
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()
OBJECT = "/preseed/qairt-test-fixture.zip"


class FixtureServer(http.server.HTTPServer):
    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.payload: bytes | None = None
        self.puts = 0
        self.heads = 0
        self.gets = 0
        self.paths: list[str] = []
        self.redirect = False
        self.corrupt = False
        self.put_error = False
        self.trickle = False
        self.preconditions: list[str | None] = []
        self.race_payload: bytes | None = None

    def get_request(self) -> tuple[socket.socket, tuple[str, int]]:
        connection, address = super().get_request()
        connection.settimeout(2)
        return connection, cast("tuple[str, int]", address)


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    @property
    def fixture(self) -> FixtureServer:
        return cast("FixtureServer", self.server)

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def reply(self, status: int, body: bytes = b"") -> None:
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            try:
                if self.command == "GET" and self.fixture.trickle:
                    for offset in range(0, len(body), len(body) // 20):
                        time.sleep(0.2)
                        self.wfile.write(body[offset:offset + len(body) // 20])
                        self.wfile.flush()
                else:
                    self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                return

    def do_HEAD(self) -> None:
        server = self.fixture
        server.heads += 1
        server.paths.append(self.path)
        if server.redirect:
            self.send_response(302)
            self.send_header("Location", "http://8.8.8.8/forbidden")
            self.end_headers()
        else:
            self.reply(404 if server.payload is None else 200)

    def do_GET(self) -> None:
        server = self.fixture
        server.gets += 1
        server.paths.append(self.path)
        self.reply(404 if server.payload is None else 200, server.payload or b"")

    def do_PUT(self) -> None:
        server = self.fixture
        server.puts += 1
        server.paths.append(self.path)
        server.preconditions.append(self.headers.get("If-None-Match"))
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if server.race_payload is not None:
            server.payload = server.race_payload
        if server.put_error:
            self.send_error(500, "private-endpoint-marker-must-not-escape")
        elif server.payload is not None or self.headers.get("If-None-Match") != "*":
            self.reply(412)
        else:
            server.payload = body + b"corrupt" if server.corrupt else body
            self.reply(201)


class TransferTests(QairtKeyFixture):
    handoff = HANDOFF
    def setUp(self) -> None:
        super().setUp()
        self.work = Path(self.working.name)
        self.server = FixtureServer()
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()
        self.addCleanup(self.close_server)
        self.url = f"http://127.0.0.1:{self.server.server_port}/prefix"
        HANDOFF.write_private(self.directory / "endpoint.txt", self.url.encode())
        self.archive = self.work / "source with spaces.zip"
        self.archive.write_bytes(PAYLOAD)

    def close_server(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.assertFalse(self.thread.is_alive())

    def deliver(self, **changes: object) -> dict[str, str | int]:
        arguments = {"directory": self.directory, "archive": self.archive,
                     "fingerprint": self.record["sha256_spki"], "object_path": OBJECT,
                     "size": len(PAYLOAD), "digest": DIGEST, "timeout": 10}
        arguments.update(changes)
        return TRANSFER.deliver(**arguments)

    def cli(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(SCRIPT), "--directory", str(self.directory),
                               "--archive", str(self.archive), "--fingerprint", self.record["sha256_spki"],
                               "--object-path", OBJECT, "--bytes", str(len(PAYLOAD)), "--sha256", DIGEST,
                               "--receipt", str(self.work / "receipt.json"), *extra],
                              capture_output=True, text=True, check=False, timeout=10)

    def test_absent_object_is_conditionally_uploaded_and_fully_read_back(self) -> None:
        result = self.deliver()
        self.assertEqual(result["status"], "uploaded-verified")
        self.assertEqual(self.server.payload, PAYLOAD)
        self.assertEqual(self.server.preconditions, ["*"])
        self.assertEqual(self.server.gets, 1)
        self.assertEqual(self.server.paths, ["/prefix" + OBJECT] * 3)

    def test_matching_existing_object_is_verified_without_put(self) -> None:
        self.server.payload = PAYLOAD
        result = self.deliver()
        self.assertEqual(result["status"], "already-present-verified")
        self.assertEqual(self.server.puts, 0)
        self.assertEqual(self.server.gets, 1)

    def test_matching_object_created_during_put_is_fully_verified(self) -> None:
        self.server.race_payload = PAYLOAD
        result = self.deliver()
        self.assertEqual(result["status"], "already-present-verified")
        self.assertEqual(result["put_or_head_status"], 412)
        self.assertEqual(self.server.gets, 1)

    def test_wrong_object_created_during_put_cannot_pass(self) -> None:
        self.server.race_payload = b"keep-racing-writer"
        with self.assertRaises(ValueError):
            self.deliver()
        self.assertEqual(self.server.payload, b"keep-racing-writer")
        self.assertEqual(self.server.gets, 1)

    def test_mismatched_existing_object_is_not_overwritten(self) -> None:
        self.server.payload = b"keep-existing-bytes"
        with self.assertRaises(ValueError):
            self.deliver()
        self.assertEqual(self.server.puts, 0)
        self.assertEqual(self.server.payload, b"keep-existing-bytes")

    def test_matching_length_is_insufficient_without_exact_hash(self) -> None:
        self.server.payload = b"x" * len(PAYLOAD)
        with self.assertRaises(ValueError):
            self.deliver()
        self.assertEqual(self.server.puts, 0)

    def test_wrong_source_hash_and_size_fail_before_any_request(self) -> None:
        for changes in ({"digest": "0" * 64}, {"size": len(PAYLOAD) + 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.deliver(**changes)
        self.assertEqual(self.server.heads, 0)
        self.assertEqual(self.server.puts, 0)

    def test_source_symlink_is_refused(self) -> None:
        alias = self.work / "alias.zip"
        alias.symlink_to(self.archive)
        with self.assertRaises(OSError):
            self.deliver(archive=alias)
        self.assertEqual(self.server.heads, 0)

    def test_public_or_symlinked_endpoint_is_refused(self) -> None:
        endpoint = self.directory / "endpoint.txt"
        endpoint.chmod(0o644)
        with self.assertRaises(ValueError):
            self.deliver()
        endpoint.unlink()
        target = self.directory / "other-private-route.txt"
        HANDOFF.write_private(target, self.url.encode())
        endpoint.symlink_to(target)
        with self.assertRaises(OSError):
            self.deliver()
        self.assertEqual(self.server.heads, 0)

    def test_fingerprint_mismatch_fails_before_any_request(self) -> None:
        with self.assertRaises(ValueError):
            self.deliver(fingerprint="0" * 64)
        self.assertEqual(self.server.heads, 0)

    def test_public_and_dns_routes_are_refused_without_resolution(self) -> None:
        endpoint = self.directory / "endpoint.txt"
        for value in ("http://8.8.8.8", "http://private.invalid", "http://0.0.0.0", "http://224.0.0.1"):
            endpoint.write_text(value)
            with self.subTest(value=value), patch.object(socket, "getaddrinfo", side_effect=AssertionError("route resolved")), self.assertRaises(ValueError):
                self.deliver()
        self.assertEqual(self.server.heads, 0)

    def test_object_path_is_confined_to_one_preseed_zip(self) -> None:
        for value in ("/other/file.zip", "/preseed/../file.zip", "/preseed/a.zip?token=secret", "/preseed/a/b.zip"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.deliver(object_path=value)
        self.assertEqual(self.server.heads, 0)

    def test_redirects_are_not_followed(self) -> None:
        self.server.redirect = True
        with self.assertRaises(ValueError):
            self.deliver()
        self.assertEqual(self.server.puts, 0)
        self.assertEqual(self.server.gets, 0)

    def test_corrupt_post_upload_bytes_cannot_pass(self) -> None:
        self.server.corrupt = True
        with self.assertRaises(ValueError):
            self.deliver()
        self.assertEqual(self.server.puts, 1)
        self.assertEqual(self.server.gets, 1)

    def test_failed_put_cannot_pass(self) -> None:
        self.server.put_error = True
        with self.assertRaises(ValueError):
            self.deliver()
        self.assertEqual(self.server.gets, 0)

    def test_upload_stream_hash_is_checked_independently(self) -> None:
        route = TRANSFER.endpoint(self.directory, self.record["sha256_spki"], OBJECT)
        remote = TRANSFER.PrivateObject(route, time.monotonic() + 5)
        with self.assertRaises(ValueError):
            remote.put(io.BytesIO(b"x" * len(PAYLOAD)), len(PAYLOAD), DIGEST)

    def test_source_change_after_send_cannot_pass(self) -> None:
        original = TRANSFER.PrivateObject.put
        def changed(remote: object, source: object, size: int, digest: str) -> int:
            result = original(remote, source, size, digest)
            self.archive.write_bytes(PAYLOAD)
            return result
        with patch.object(TRANSFER.PrivateObject, "put", changed), self.assertRaises(ValueError):
            self.deliver()

    def test_overlapping_local_transfer_is_refused(self) -> None:
        with TRANSFER.transfer_lock(self.directory), self.assertRaises(BlockingIOError):
            self.deliver()
        self.assertEqual(self.server.heads, 0)

    def test_invalid_deadlines_and_bindings_are_refused(self) -> None:
        for changes in ({"timeout": 0}, {"timeout": float("nan")}, {"timeout": float("inf")},
                        {"timeout": 3601}, {"size": 0}, {"digest": "bad"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.deliver(**changes)
        self.assertEqual(self.server.heads, 0)

    def test_proxy_environment_does_not_redirect_sdk_bytes(self) -> None:
        with patch.dict(os.environ, {"HTTP_PROXY": "http://127.0.0.1:1", "ALL_PROXY": "http://127.0.0.1:1"}):
            result = self.deliver()
        self.assertEqual(result["status"], "uploaded-verified")
        self.assertEqual(self.server.payload, PAYLOAD)

    def test_cli_receipt_binds_exact_bytes_without_endpoint(self) -> None:
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = self.work / "receipt.json"
        record = json.loads(receipt.read_text())
        self.assertEqual(record["status"], "uploaded-verified")
        self.assertEqual(record["bytes"], len(PAYLOAD))
        self.assertEqual(record["sha256"], DIGEST)
        self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.url, receipt.read_text() + result.stdout + result.stderr)

    def test_existing_receipt_refuses_before_any_request(self) -> None:
        receipt = self.work / "receipt.json"
        receipt.write_text("keep-existing-receipt")
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt.read_text(), "keep-existing-receipt")
        self.assertEqual(self.server.heads, 0)

    def test_cli_deadline_interrupts_a_stalled_response(self) -> None:
        self.server.payload = PAYLOAD
        self.server.trickle = True
        started = time.monotonic()
        result = self.cli("--timeout", "0.5")
        self.assertLess(time.monotonic() - started, 3)
        self.assertNotEqual(result.returncode, 0)
        record = json.loads((self.work / "receipt.json").read_text())
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["error_type"], "TimeoutError")
        self.assertNotIn(self.url, result.stdout + result.stderr)

    def test_raw_exception_text_never_enters_cli_output_or_receipt(self) -> None:
        arguments = [str(SCRIPT), "--directory", str(self.directory), "--archive", str(self.archive),
                     "--fingerprint", self.record["sha256_spki"], "--object-path", OBJECT,
                     "--bytes", str(len(PAYLOAD)), "--sha256", DIGEST, "--receipt", str(self.work / "redacted.json")]
        output = io.StringIO()
        with (patch.object(sys, "argv", arguments), patch.object(TRANSFER, "deliver", side_effect=OSError(self.url)),
              patch.object(TRANSFER.signal, "signal"), patch.object(TRANSFER.signal, "setitimer"),
              redirect_stdout(output), redirect_stderr(output)):
            self.assertEqual(TRANSFER.main(), 1)
        self.assertNotIn(self.url, output.getvalue() + (self.work / "redacted.json").read_text())

    def test_http_error_and_endpoint_are_redacted(self) -> None:
        self.server.put_error = True
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        record = json.loads((self.work / "receipt.json").read_text())
        self.assertEqual(record["status"], "failed")
        self.assertNotIn(self.url, result.stdout + result.stderr)
        self.assertNotIn("private-endpoint-marker-must-not-escape", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
