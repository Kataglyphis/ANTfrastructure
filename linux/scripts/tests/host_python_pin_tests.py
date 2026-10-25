#!/usr/bin/env python3
"""Executable fixtures cover resolver precedence and copied imports, not Python ABI compatibility or Android builds."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

TESTS = Path(__file__).resolve().parent
SCRIPTS = Path(sys.argv.pop(1)).resolve()
GST = "03-media/build/gstreamer/android/build-android-from-source.sh"
DRIVER = r"""set -uo pipefail
source "$TESTS/test-harness.sh"
source "$CORE/cross-python.sh"
if [ "$API" = gst ]; then
  unset -f host_python_bin
  eval "$(t_fn_src "$GST" resolve_host_python)"
fi
version_major_minor() { printf 'derive:%s\n' "$*" >> "$TRACE"; printf '%s' "$DERIVED"; return "$DERIVE_STATUS"; }
[() {
  if builtin [ "${1:-}" = -x ] && builtin [ "${2:-}" = /usr/local/bin/python3.99 ]; then
    builtin [ "$MM_OK" = yes ]
  else builtin '[' "$@"; fi
}
printf() {
  if builtin [ "$PRINTF_FAULT" = yes ] && builtin [ "${1:-}" = '%s' ]; then
    builtin printf 'printf-fault\n' >> "$TRACE"
    builtin printf partial
    return 43
  fi
  builtin printf "$@"
}
case "$OVERRIDE" in
  function) host_python_bin() { printf 'host override with spaces'; return "$OVERRIDE_STATUS"; } ;;
esac
PATH="$TOOLS"
if [ "$API" = gst ]; then function_name=resolve_host_python; else function_name=host_python_bin; fi
if [ "$DYNAMIC" = yes ]; then
  "$function_name"; printf '\n'
  MEDIA_HOST_PYTHON="$SECOND_PIN"
fi
if [ "$CONTEXT" = strict ]; then set -e; "$function_name"; else
  if "$function_name"; then exit 0; else exit "$?"; fi
fi
"""
CASES = {
    "printf-failure": {"media": "valid", "printf_fault": True},
    "newline-media": {"media": "newline"},
    "media": {"media": "valid", "uv": "valid", "venv": True},
    "invalid-media": {"media": "missing", "uv": "valid"},
    "nonexec-media": {"media": "nonexec", "uv": "valid"},
    "uv": {"uv": "valid", "venv": True},
    "venv": {"venv": True},
    "explicit-version": {"mm": "3.99", "mm_ok": True},
    "derived-version": {"version": "3.99.1", "derived": "3.99", "mm_ok": True},
    "derived-failure": {"version": "3.99.1", "derived": "", "derive_status": 37},
    "invalid-explicit-version": {"mm": "3.99", "version": "3.99.1", "mm_ok": False},
    "path-python3": {},
    "path-python": {"python3": False},
    "path-missing": {"python3": False, "python": False},
    "dynamic-pins": {"media": "valid", "dynamic": True},
    "function-override": {
        "override": "function",
        "override_status": 0,
        "media": "valid",
    },
    "failing-function-override": {
        "override": "function",
        "override_status": 39,
        "media": "valid",
    },
    "executable-override": {
        "override": "executable",
        "override_status": 0,
        "media": "valid",
    },
    "failing-executable-override": {
        "override": "executable",
        "override_status": 41,
        "media": "valid",
    },
}


def plant_python_tools(work: Path, config: dict[str, Any]) -> Path:
    tools = work / "tools"
    tools.mkdir()
    for name in ("python3", "python"):
        if config.get(name, True):
            path = tools / name
            path.write_text("#!/bin/sh\nexit 91\n")
            path.chmod(0o755)
    if config.get("override") == "executable":
        path = tools / "host_python_bin"
        path.write_text(
            '#!/bin/sh\nprintf "external override with spaces"\nexit "$OVERRIDE_STATUS"\n'
        )
        path.chmod(0o755)
    for name in (
        "media pin",
        "newline pin\n\n",
        "uv pin",
        "second pin",
        "nonexec pin",
        "venv/bin/python",
    ):
        path = work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\nexit 92\n")
        if name != "nonexec pin":
            path.chmod(0o755)
    return tools


def capture_case(
    scripts: Path, api: str, context: str, config: dict[str, Any]
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="ant-host-python-") as temporary:
        work = Path(temporary)
        core = work / "core"
        core.mkdir()
        for name in ("cross-python.sh", "platform.sh"):
            (core / name).write_bytes((scripts / "01-core" / name).read_bytes())
        tools = plant_python_tools(work, config)
        trace = work / "trace"
        env = dict(
            os.environ,
            CORE=str(core),
            TESTS=str(TESTS),
            GST=str(scripts / GST),
            API=api,
            CONTEXT=context,
            TRACE=str(trace),
            TOOLS=str(tools),
            MM_OK="yes" if config.get("mm_ok") else "no",
            DERIVED=config.get("derived", ""),
            DERIVE_STATUS=str(config.get("derive_status", 0)),
            PRINTF_FAULT="yes" if config.get("printf_fault") else "no",
            OVERRIDE=config.get("override", "none"),
            OVERRIDE_STATUS=str(config.get("override_status", 0)),
            DYNAMIC="yes" if config.get("dynamic") else "no",
            SECOND_PIN=str(work / "second pin"),
        )
        for name in (
            "MEDIA_HOST_PYTHON",
            "UV_PYTHON",
            "VIRTUAL_ENV",
            "PYTHON_MAJOR_MINOR",
            "PYTHON_VERSION",
            "_CROSS_PYTHON_LOADED",
            "_PLATFORM_SH_LOADED",
        ):
            env.pop(name, None)
        for key, name in (("media", "MEDIA_HOST_PYTHON"), ("uv", "UV_PYTHON")):
            if key in config:
                env[name] = str(
                    work
                    / {
                        "valid": f"{key} pin",
                        "missing": "missing pin",
                        "nonexec": "nonexec pin",
                        "newline": "newline pin\n\n",
                    }[config[key]]
                )
        if config.get("venv"):
            env["VIRTUAL_ENV"] = str(work / "venv")
        if "mm" in config:
            env["PYTHON_MAJOR_MINOR"] = config["mm"]
        if "version" in config:
            env["PYTHON_VERSION"] = config["version"]
        result = subprocess.run(
            ["bash", "-c", DRIVER],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        return {
            "status": result.returncode,
            "stdout": result.stdout.replace(str(work), "WORK"),
            "stderr": result.stderr.replace(str(work), "WORK"),
            "trace": trace.read_text() if trace.exists() else "",
        }


def capture(scripts: Path) -> dict[str, dict[str, Any]]:
    result = {}
    for api in ("canonical", "gst"):
        for context in ("strict", "conditional"):
            for name, config in CASES.items():
                if api == "canonical" and "override" in config:
                    continue
                result[f"{api}:{context}:{name}"] = capture_case(
                    scripts, api, context, config
                )
    return result


class HostPythonPins(unittest.TestCase):
    def test_original_receipts(self) -> None:
        expected = json.loads(
            Path(__file__).with_name("host-python-pin-receipts.json").read_text()
        )
        actual = capture(SCRIPTS)
        for name, receipt in expected.items():
            with self.subTest(name=name):
                self.assertEqual(receipt, actual[name])

    def test_required_imports_and_load_guards(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ant-python-import-") as temporary:
            core = Path(temporary)
            (core / "cross-python.sh").write_bytes(
                (SCRIPTS / "01-core/cross-python.sh").read_bytes()
            )
            for content, status in ((None, 1), ("return 37\n", 37), (":\n", 1)):
                platform = core / "platform.sh"
                if content is None:
                    platform.unlink(missing_ok=True)
                else:
                    platform.write_text(content)
                result = subprocess.run(
                    [
                        "bash",
                        "-c",
                        'if source "$1"; then exit 0; else exit 73; fi',
                        "_",
                        str(core / "cross-python.sh"),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10,
                )
                self.assertEqual(status, result.returncode)
            (core / "platform.sh").write_bytes(
                (SCRIPTS / "01-core/platform.sh").read_bytes()
            )
            script = 'source "$1/platform.sh"; host_python_path() { printf "preserved guard:%s" "$1"; }; source "$1/cross-python.sh"; host_python_bin'
            result = subprocess.run(
                ["bash", "-euc", script, "_", str(core)],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(0, result.returncode)
            self.assertEqual("preserved guard:derived", result.stdout)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    '_PLATFORM_SH_LOADED=1; source "$1"',
                    "_",
                    str(core / "cross-python.sh"),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(1, result.returncode)
            self.assertIn("platform.sh lacks host_python_path", result.stderr)

    def test_source_only_and_already_loaded_guards(self) -> None:
        source = SCRIPTS / "01-core/cross-python.sh"
        executed = subprocess.run(
            ["bash", str(source)],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(1, executed.returncode)
        self.assertIn("meant to be sourced", executed.stderr)
        command = '_CROSS_PYTHON_LOADED=1; host_python_bin() { printf "existing definition"; }; source "$1"; host_python_bin'
        loaded = subprocess.run(
            ["bash", "-euc", command, "_", str(source)],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(0, loaded.returncode)
        self.assertEqual("existing definition", loaded.stdout)

    def test_android_import_order_and_override(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ant-android-python-") as temporary:
            root = Path(temporary)
            android = root / "03-media/build/gstreamer/android"
            android.mkdir(parents=True)
            preamble = root / "03-media/build/android-build-preamble.sh"
            preamble.write_text('android_build_preamble_init() { printf "init\\n"; }\n')
            core = root / "01-core"
            core.mkdir()
            installed = root / "installed-core"
            installed.mkdir()
            text = (
                (SCRIPTS / GST)
                .read_text()
                .split("patch_cerbero_system_m4_usage()", 1)[0]
            )
            child = android / "build-android-from-source.sh"
            child.write_text(text.replace("/opt/scripts/core", str(installed)))
            command = 'host_python_bin() { printf "preserved override"; return 47; }; source "$1"; if resolve_host_python; then exit 0; else exit "$?"; fi'
            for layout in ("repo", "installed", "missing", "failed", "incomplete"):
                (core / "platform.sh").unlink(missing_ok=True)
                (installed / "platform.sh").unlink(missing_ok=True)
                if layout in ("repo", "installed"):
                    (core / "platform.sh").write_bytes(
                        (SCRIPTS / "01-core/platform.sh").read_bytes()
                    )
                    if layout == "installed":
                        (installed / "platform.sh").write_bytes(
                            (SCRIPTS / "01-core/platform.sh").read_bytes()
                        )
                        (core / "platform.sh").write_text("echo POISON; return 31\n")
                elif layout == "failed":
                    (installed / "platform.sh").write_text("return 37\n")
                elif layout == "incomplete":
                    (installed / "platform.sh").write_text(":\n")
                result = subprocess.run(
                    ["bash", "-c", command, "_", str(child)],
                    env=dict(os.environ, GSTREAMER_VERSION="1.2.3"),
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=10,
                )
                self.assertEqual(
                    47
                    if layout in ("repo", "installed")
                    else 37
                    if layout == "failed"
                    else 1,
                    result.returncode,
                )
                self.assertEqual(
                    "init\npreserved override"
                    if layout in ("repo", "installed")
                    else "init\n",
                    result.stdout,
                )
            preamble.write_text(
                "android_build_preamble_init() { echo skipped; exit 0; }\n"
            )
            (installed / "platform.sh").unlink(missing_ok=True)
            result = subprocess.run(
                ["bash", str(child)],
                env=dict(os.environ, GSTREAMER_VERSION="1.2.3"),
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(0, result.returncode)
            self.assertEqual("skipped\n", result.stdout)

    def test_independent_policy(self) -> None:
        actual = capture(SCRIPTS)
        self.assertEqual("WORK/media pin", actual["canonical:strict:media"]["stdout"])
        self.assertEqual(43, actual["gst:conditional:printf-failure"]["status"])
        self.assertEqual("partial", actual["gst:conditional:printf-failure"]["stdout"])
        self.assertEqual(
            "printf-fault\n", actual["gst:conditional:printf-failure"]["trace"]
        )
        self.assertEqual(43, actual["canonical:strict:printf-failure"]["status"])
        self.assertEqual(0, actual["canonical:conditional:printf-failure"]["status"])
        self.assertEqual(
            "printf-fault\nprintf-fault\n",
            actual["canonical:conditional:printf-failure"]["trace"],
        )
        self.assertEqual(
            "WORK/newline pin", actual["canonical:strict:newline-media"]["stdout"]
        )
        self.assertEqual(
            "WORK/newline pin\n\n", actual["gst:strict:newline-media"]["stdout"]
        )
        self.assertEqual("WORK/uv pin", actual["gst:strict:invalid-media"]["stdout"])
        self.assertEqual("WORK/venv/bin/python", actual["gst:strict:venv"]["stdout"])
        self.assertEqual(
            "/usr/local/bin/python3.99",
            actual["canonical:strict:derived-version"]["stdout"],
        )
        self.assertEqual(
            "WORK/tools/python3\n", actual["gst:strict:derived-version"]["stdout"]
        )
        self.assertEqual("", actual["gst:strict:derived-version"]["trace"])
        self.assertEqual(
            39, actual["gst:conditional:failing-function-override"]["status"]
        )
        self.assertEqual(41, actual["gst:strict:failing-executable-override"]["status"])
        self.assertEqual(
            "WORK/media pin\nWORK/second pin",
            actual["gst:strict:dynamic-pins"]["stdout"],
        )


if __name__ == "__main__":
    unittest.main()
