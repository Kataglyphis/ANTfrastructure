#!/usr/bin/env bash
# Grades uv exclusion semantics; it does not verify package resolution or installed versions.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PYTHONPATH="${root}/docs/scripts${PYTHONPATH:+:${PYTHONPATH}}" python3 - <<'PY'
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import consumer_pins

VERSIONS = {
    "RUFF_VERSION": "1.0.0",
    "PYTORCH_VERSION": "v2.14.1",
    "TORCHVISION_VERSION": "v0.29.1",
    "ONNXRUNTIME_GENAI_VERSION": "v0.17.0",
}


def grade(manifest: str) -> tuple[int, str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "pyproject.toml").write_text(manifest, encoding="utf-8")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            status = consumer_pins.check_consumer_pins(VERSIONS, [directory], Path("/unrelated"))
        return status, out.getvalue()


class ConsumerPinsTomlTest(unittest.TestCase):
    def test_declarations_and_exclusions(self) -> None:
        exclusion = '[tool.uv]\nexclude-dependencies = ["torch", "torchvision"]\n'
        cases = (
            ("exclusion only", exclusion, 0, "0 pins compared"),
            ("unpinned", '[project]\ndependencies = ["torch"]\n' + exclusion, 1, "no readable version"),
            ("wrong pin", '[project]\ndependencies = ["torch==0.0.0"]\n' + exclusion, 1, "is 0.0.0"),
            ("correct pin", '[project]\ndependencies = ["torch==2.14.1"]\n' + exclusion, 0, "1 compared"),
            ("override", '[tool.uv]\noverride-dependencies = ["torch"]\nexclude-dependencies = ["torch"]\n', 1, "no readable version"),
            ("invalid", '[project\ndependencies = []\n', 1, "invalid TOML"),
        )
        for name, manifest, expected, message in cases:
            with self.subTest(name=name):
                status, out = grade(manifest)
                self.assertEqual(status, expected)
                self.assertIn(message, out)


if __name__ == "__main__":
    unittest.main()
PY
