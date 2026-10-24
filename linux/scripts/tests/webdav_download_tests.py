#!/usr/bin/env python3
"""Prove CLI delegation and error status; the client's tests own HTTP and filesystem behavior."""

import contextlib
import importlib.util
import io
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "01-core/download-webdav-files.py"


class Client:
    def __init__(self, *args):
        self.calls = []
        self.failure = None

    def download_all_files_iterative(self, remote, local, **options):
        self.calls.append((remote, local, options))
        if self.failure:
            raise self.failure
        return 2


class StubWebDavApi(types.ModuleType):
    def __init__(self, client: Client):
        super().__init__("kataglyphis_webdavclient.webdavclient")
        self.WebDavClient = lambda *args: client


class WebDavCliTests(unittest.TestCase):
    def setUp(self):
        self.client = Client()
        package = types.ModuleType("kataglyphis_webdavclient")
        api = StubWebDavApi(self.client)
        with patch.dict(sys.modules, {
            "kataglyphis_webdavclient": package,
            "kataglyphis_webdavclient.webdavclient": api,
        }):
            spec = importlib.util.spec_from_file_location("webdav_download_cli", SCRIPT)
            if spec is None or spec.loader is None:
                raise RuntimeError("Cannot load the WebDAV CLI fixture")
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)

    def test_filtered_cli_calls_the_public_download_api(self):
        with tempfile.TemporaryDirectory() as directory:
            args = ["https://host.test", "user", "secret", "data", directory, "--extension", "MD"]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(self.module.main(args), 0)
            self.assertEqual(self.client.calls, [("data", directory, {"extension": ".md"})])

    def test_unfiltered_cli_preserves_the_existing_api(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.module.main(["https://host.test", "u", "p", "data", directory]), 0)
            self.assertEqual(self.client.calls, [("data", directory, {})])

    def test_listing_http_and_path_errors_fail_the_cli(self):
        for error in (OSError("HTTP 503"), ValueError("unsafe WebDAV href"), TypeError("old client")):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                self.client.failure = error
                stderr = io.StringIO()
                with contextlib.redirect_stderr(stderr):
                    result = self.module.main(["https://host.test", "u", "p", "data", directory,
                                               "--extension", "md"])
                self.assertEqual(result, 1)
                self.assertIn(str(error), stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
