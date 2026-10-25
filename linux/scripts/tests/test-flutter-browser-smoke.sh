#!/usr/bin/env bash
# The browser smoke must report browser failures and let implementation bugs fail loud.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
WEB_SCRIPTS="$(cd "${TESTS_DIR}/../../webserver/scripts" && pwd)"

t_case "only Playwright errors become recorded browser failures"
_out="$(
  PYTHONPATH="${WEB_SCRIPTS}${PYTHONPATH:+:${PYTHONPATH}}" "${PY}" - 2>&1 <<'PY'
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import types
import unittest
from pathlib import Path
from typing import Self
from unittest.mock import patch


class PlaywrightError(Exception):
    pass


playwright = types.ModuleType("playwright")
sync_api = types.ModuleType("playwright.sync_api")
sync_api.Error = PlaywrightError
sync_api.sync_playwright = None
sync_api.Page = object
sync_api.Request = object
sync_api.Response = object
playwright.sync_api = sync_api
sys.modules["playwright"] = playwright
sys.modules["playwright.sync_api"] = sync_api

import flutter_capture_console_errors as smoke


class FakeChromium:
    def __init__(self, error: Exception) -> None:
        self.error = error

    def launch(self, **_kwargs: object) -> object:
        raise self.error


class FakePlaywright:
    def __init__(self, error: Exception) -> None:
        self.chromium = FakeChromium(error)

    def __enter__(self) -> Self:
        return self

    def __exit__(self, _kind: object, _value: object, _traceback: object) -> bool:
        return False


class BrowserSmokeTests(unittest.TestCase):
    def make_suite(self) -> smoke.E2ETestSuite:
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        return smoke.E2ETestSuite(
            build_dir=Path(self.tempdir.name),
            port=0,
            chromium_bin="unused",
            screenshot_path="unused",
        )

    def run_with_error(self, error: Exception) -> tuple[smoke.E2ETestSuite, int]:
        suite = self.make_suite()
        with (
            patch.object(smoke, "sync_playwright", return_value=FakePlaywright(error)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            result = suite.run_all()
        return suite, result

    def test_playwright_failure_is_reported(self) -> None:
        suite, result = self.run_with_error(PlaywrightError("launch failed"))
        self.assertEqual(1, result)
        self.assertEqual(1, suite.results["failed"])
        self.assertTrue(suite.failures[0].startswith("Browser run:"))

    def test_unexpected_error_escapes_the_smoke(self) -> None:
        with self.assertRaisesRegex(AssertionError, "bug"):
            self.run_with_error(AssertionError("bug"))

    def test_http_error_responses_are_recorded(self) -> None:
        suite = self.make_suite()
        suite.record_response(types.SimpleNamespace(status=404, url="https://example.test/missing"))
        suite.record_response(types.SimpleNamespace(status=200, url="https://example.test/ok"))
        self.assertEqual({"404 https://example.test/missing"}, suite.http_errors)


unittest.main(verbosity=2)
PY
)"
_rc=$?
t_assert_eq 0 "${_rc}" "${_out}"

t_summary
