#!/usr/bin/env python3
"""Offline fetch receipts cover command boundaries and failure policy, not Git, uv, network retries or SDK execution."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Mapping
from pathlib import Path

SOURCE = Path(sys.argv.pop(1))
EXPECTED = json.loads(Path(__file__).with_name("onnx-fetch-receipts.json").read_text())

STUB = r"""set -euo pipefail
exec 3>&1
_trace() { { printf 'TRACE cwd=%s ' "$PWD"; printf '<%s>' "$@"; printf '\n'; } >&3; }
info() { _trace INFO "$*"; }
warn() { _trace WARN "$*"; }
parse_common_args() { _trace PARSE "$@"; }
detect_jobs() { _trace JOBS; }
err() { _trace ERR "$*"; exit 1; }
retry() { _trace RETRY "$1" "$2" "$3"; shift 3; "$@"; }
sleep() { _trace SLEEP "$@"; }
genai_extensions_src_dir() { printf '%s/.pinned-deps/onnxruntime-extensions\n' "$GENAI_SRC_DIR"; }
_fixture_deps() { mkdir -p "$1/cmake"; printf 'onnxruntime_extensions;https://fixture/ext.git;%s\n' "${DEPS_EXT_COMMIT}" > "$1/cmake/deps.txt"; }
git() {
  _trace GIT "$@"
  local dir="$PWD"
  if [ "$1" = -C ]; then dir="$2"; shift 2; fi
  case "$1" in
    clone)
      [ "${FAIL_CLONE:-}" != "$PWD" ] || return 23
      mkdir -p "${@: -1}/.git"
      [ "${@: -1}" != "$GENAI_SRC_DIR" ] || _fixture_deps "${@: -1}" ;;
    init) mkdir -p "$3/.git" ;;
    fetch) [ "${FAIL_FALLBACK:-}" != "$dir" ] || return 29 ;;
    rev-parse)
      case "$dir" in
        "$ORT_SRC_DIR") printf '%s\n' "${HEAD_ORT}" ;;
        "$GENAI_SRC_DIR") printf '%s\n' "${HEAD_GENAI}" ;;
        *) printf '%s\n' "${HEAD_EXT}" ;;
      esac ;;
    submodule)
      if [ "$2" = sync ] && [ "${FAIL_SYNC:-}" = "$PWD" ]; then return 17; fi
      if [ "$2" = update ] && [ "${FAIL_UPDATE:-}" = "$PWD" ]; then return 31; fi ;;
  esac
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
    ("ort-fallback", {"clone": "start", "fallback": True}),
    ("ort-fallback-fails", {"clone": "start", "fallback": True, "fallback_fails": True}),
    ("ort-moved-tag", {"head_ort": "f" * 40}),
    ("extensions-deps-mismatch", {"deps_ext": "e" * 40}),
]
PINS = {"ort": "a" * 40, "genai": "b" * 40, "ext": "c" * 40}


class FetchReceipts(unittest.TestCase):
    def test_original_fetch_receipts(self) -> None:
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
    def run_fixture(root: str, config: Mapping[str, bool | int | str]) -> dict[str, int | str]:
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
        (driver / "lib/source-fetch.sh").write_bytes(SOURCE.with_name("lib").joinpath("source-fetch.sh").read_bytes())
        fallback = " https://fixture/ort-fork" if config.get("fallback") else ""
        (driver / "lib/source-pins.txt").write_text(
            f"onnxruntime|v1.23.4|{PINS['ort']}|{fallback.strip()}\n"
            f"onnxruntime-genai|v0.8.9|{PINS['genai']}|\n"
            f"onnxruntime-extensions|-|{PINS['ext']}|\n"
        )
        guard_bin = base / "guard-bin"
        guard_bin.mkdir()
        for tool in ("git", "uv"):
            guard = guard_bin / tool
            guard.write_text("#!/bin/sh\nexit 97\n")
            guard.chmod(0o755)
        if config.get("existing"):
            paths["ort"].mkdir()
            (paths["genai"] / "cmake").mkdir(parents=True)
            (paths["genai"] / "cmake/deps.txt").write_text(f"onnxruntime_extensions;https://fixture/ext.git;{PINS['ext']}\n")
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
            HEAD_ORT=str(config.get("head_ort", PINS["ort"])),
            HEAD_GENAI=PINS["genai"],
            HEAD_EXT=PINS["ext"],
            DEPS_EXT_COMMIT=str(config.get("deps_ext", PINS["ext"])),
            FAIL_FALLBACK=str(paths["ort"]) if config.get("fallback_fails") else "",
        )
        env["PATH"] = str(guard_bin) + os.pathsep + env.get("PATH", "")
        for flag in ("clone", "sync", "update"):
            destination = config.get(flag)
            env["FAIL_" + flag.upper()] = str(paths[destination]) if isinstance(destination, str) else ""
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
