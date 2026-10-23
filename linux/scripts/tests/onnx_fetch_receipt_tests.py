#!/usr/bin/env python3
"""Offline fetch receipts cover command boundaries and failure policy, not Git, uv, retries or SDK execution."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(sys.argv.pop(1))
EXPECTED = json.loads(Path(__file__).with_name("onnx-fetch-receipts.json").read_text())

STUB = r"""set -euo pipefail
_trace() { printf 'TRACE cwd=%s ' "$PWD"; printf '<%s>' "$@"; printf '\n'; }
info() { _trace INFO "$*"; }
warn() { _trace WARN "$*"; }
parse_common_args() { _trace PARSE "$@"; }
detect_jobs() { _trace JOBS; }
retry() { _trace RETRY "$1" "$2" "$3"; shift 3; "$@"; }
git() {
  _trace GIT "$@"
  if [ "$1" = clone ]; then
    [ "${FAIL_CLONE:-}" != "$PWD" ] || return 23
    mkdir -p "${@: -1}"
  elif [ "$1" = submodule ]; then
    if [ "$2" = sync ] && [ "${FAIL_SYNC:-}" = "$PWD" ]; then return 17; fi
    if [ "$2" = update ] && [ "${FAIL_UPDATE:-}" = "$PWD" ]; then return 31; fi
  fi
}
require_cmd() { _trace REQUIRE "$@"; }
uv() { _trace UV "$@"; return "${FAIL_UV:-0}"; }
build_arch_oci() { printf arm64; }
"""
cases = [
    ("fresh", {}),
    ("existing", {"existing": True}),
    ("skip-genai", {"genai": False}),
    ("ort-clone-fails", {"clone": "start"}),
    ("genai-clone-fails", {"clone": "ort"}),
    ("ort-sync-advisory", {"sync": "ort"}),
    ("genai-sync-advisory", {"sync": "genai"}),
    ("ort-update-fails", {"update": "ort"}),
    ("genai-update-fails", {"update": "genai"}),
    ("requirements", {"venv": True, "requirements": True}),
    ("requirements-missing", {"venv": True}),
    ("requirements-fail", {"venv": True, "requirements": True, "uv": 11}),
]


class FetchReceipts(unittest.TestCase):
    def test_original_fetch_receipts(self):
        for name, config in cases:
            with (
                self.subTest(name=name),
                tempfile.TemporaryDirectory(prefix="ant-fetch-receipt-") as root,
            ):
                actual = self.run_fixture(root, config)
                self.assertEqual(EXPECTED[name]["status"], actual["status"])
                self.assertEqual(EXPECTED[name]["stdout"], actual["stdout"])
                self.assertEqual(EXPECTED[name]["stderr"], actual["stderr"])

    @staticmethod
    def run_fixture(root, config):
        base = Path(root)
        paths = {
            "start": base / "caller start",
            "ort": base / "ort checkout",
            "genai": base / "genai checkout",
        }
        paths["start"].mkdir()
        driver = base / "driver"
        (driver / "lib").mkdir(parents=True)
        (driver / "20-fetch.sh").write_bytes(SOURCE.read_bytes())
        (driver / "lib/common.sh").write_text(STUB)
        guard_bin = base / "guard-bin"
        guard_bin.mkdir()
        for tool in ("git", "uv"):
            guard = guard_bin / tool
            guard.write_text("#!/bin/sh\nexit 97\n")
            guard.chmod(0o755)
        if config.get("existing"):
            paths["ort"].mkdir()
            paths["genai"].mkdir()
        if config.get("requirements"):
            paths["ort"].mkdir(exist_ok=True)
            (paths["ort"] / "requirements.txt").write_text("fixture\n")
        env = dict(
            os.environ,
            ORT_SRC_DIR=str(paths["ort"]),
            GENAI_SRC_DIR=str(paths["genai"]),
            ORT_VERSION="v1.23.4",
            GENAI_VERSION="v0.8.9",
            ORT_REPO="https://fixture/ort",
            GENAI_REPO="https://fixture/genai",
            BUILD_GENAI=str(config.get("genai", True)).lower(),
            USE_UV_VENV=str(config.get("venv", False)).lower(),
            FAIL_UV=str(config.get("uv", 0)),
        )
        env["PATH"] = str(guard_bin) + os.pathsep + env.get("PATH", "")
        for flag in ("clone", "sync", "update"):
            env["FAIL_" + flag.upper()] = (
                str(paths[config[flag]]) if flag in config else ""
            )
        result = subprocess.run(
            [
                "bash",
                str(driver / "20-fetch.sh"),
                "--fixture-option",
                "value with spaces",
            ],
            cwd=paths["start"],
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        return {
            "status": result.returncode,
            "stdout": result.stdout.replace(root, "ROOT"),
            "stderr": result.stderr.replace(root, "ROOT"),
        }


if __name__ == "__main__":
    unittest.main()
