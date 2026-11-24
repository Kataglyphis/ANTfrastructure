# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Shared free-threaded bootstrap checks; see docs/local-proof-workflows.md#proof-workflow-fixture-companions."""

import os
import shlex
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


class FreeThreadedBootstrapChecks(unittest.TestCase):
    root: Path
    scripts: Path

    def ft_tools(self) -> tuple[Path, Path, dict[str, str]]:
        directory = self.root / "ft tools"
        directory.mkdir(exist_ok=True)
        scripts = {
            "uv": 'printf "uv[%s] %s\\n" "$UV_PYTHON_INSTALL_DIR" "$*" >> "$FT_TRACE"\ncase "$2" in install) exit "${FT_INSTALL_RC:-0}" ;; find) printf "%s\\n" "$FT_EXECUTABLE" ;; *) exit 41 ;; esac\n',
            "ft-python": 'printf "ft %s\\n" "$*" >> "$FT_TRACE"\nexit "${FT_PROBE_RC:-0}"\n',
            "git": 'printf "%s\\n" "$ISOLATED_PREFLIGHT_REVISION"\n',
            "make": 'printf "make %s\\n" "$*" >> "$FT_TRACE"\nexit "${FT_MAKE_RC:-0}"\n',
            "python3": "exit 0\n",
        }
        for name in (
            "jq",
            "shellcheck",
            "rsync",
            "ps",
            "cc",
            "readelf",
            "ldconfig",
            "patchelf",
            "pytest",
            "pwsh",
            "node",
            "chromium",
        ):
            scripts[name] = "exit 0\n"
        for name, body in scripts.items():
            path = directory / name
            path.write_text("#!/usr/bin/env bash\n" + body)
            path.chmod(0o755)
        trace = self.root / "ft-trace"
        trace.unlink(missing_ok=True)
        environment = dict(
            os.environ,
            PATH=str(directory) + os.pathsep + os.environ["PATH"],
            FT_TRACE=str(trace),
            FT_EXECUTABLE=str(directory / "ft-python"),
            ISOLATED_PREFLIGHT_REVISION="f" * 40,
            ISOLATED_PREFLIGHT_JOBS="4",
            PREFLIGHT_ONLY="",
            PREFLIGHT_SKIP="",
            PREFLIGHT_MUTATION_SHARD="",
        )
        return directory, trace, environment

    def test_ft_fixture_clears_inherited_preflight_selection(self) -> None:
        inherited = {"PREFLIGHT_ONLY": "docs", "PREFLIGHT_SKIP": "mutations", "PREFLIGHT_MUTATION_SHARD": "6/8"}
        with patch.dict(os.environ, inherited):
            _, _, environment = self.ft_tools()
        for name in inherited:
            self.assertEqual(environment[name], "", name)

    def test_ft_bootstrap_installs_the_source_pin_and_preserves_raw_failures(
        self,
    ) -> None:
        bootstrap = (self.scripts / "isolated-preflight/bootstrap.sh").read_text()
        self.assertIn("unset UV_VERSION PYTHON_VERSION", bootstrap)
        self.assertLess(
            bootstrap.index("unset UV_VERSION PYTHON_VERSION"),
            bootstrap.index(
                'load_versions_env "${task_source}/linux/scripts/01-core/versions.env"'
            ),
        )
        prefix = "uv pip install --python /opt/preflight-venv/bin/python --require-hashes --requirement /tmp/preflight-quality.txt\n"
        block = bootstrap.split(prefix, 1)[1].split(
            'bash "${task_source}/linux/scripts/ensure-pe-icon-test-tools.sh"', 1
        )[0]
        pin = next(
            line.split("=", 1)[1]
            for line in (self.scripts / "01-core/versions.env").read_text().splitlines()
            if line.startswith("PYTHON_VERSION=")
        )
        for install, probe in ((0, 0), (43, 0), (0, 47)):
            with self.subTest(install=install, probe=probe):
                directory, trace, environment = self.ft_tools()
                environment.update(
                    PYTHON_VERSION=pin,
                    FT_INSTALL_RC=str(install),
                    FT_PROBE_RC=str(probe),
                )
                result = subprocess.run(
                    [
                        "bash",
                        "-euo",
                        "pipefail",
                        "-c",
                        block + '\nprintf "%s\\n" "$task_ft_python"',
                    ],
                    env=environment,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, install or probe, result.stderr)
                calls = trace.read_text().splitlines()
                self.assertEqual(
                    calls[0], f"uv[/opt/preflight-ft-python] python install {pin}t"
                )
                if install:
                    self.assertEqual(len(calls), 1)
                else:
                    self.assertEqual(
                        calls[1],
                        f"uv[/opt/preflight-ft-python] python find --managed-python {pin}t",
                    )
                    self.assertEqual(len(calls), 3)
                    self.assertTrue(calls[2].startswith("ft -I -c import sys;"))
                    self.assertTrue(calls[2].endswith(pin))
                if not (install or probe):
                    self.assertEqual(
                        result.stdout.decode().strip(), str(directory / "ft-python")
                    )

    def test_ft_worker_keeps_the_clean_envelope_and_refuses_a_failed_probe(
        self,
    ) -> None:
        bootstrap = (self.scripts / "isolated-preflight/bootstrap.sh").read_text()
        forwarded = 'FT_PYTHON="${task_ft_python}"'
        self.assertIn(forwarded, bootstrap)
        self.assertLess(bootstrap.index("exec setpriv"), bootstrap.index(forwarded))
        self.assertLess(
            bootstrap.index(forwarded),
            bootstrap.index(
                '/bin/bash "${task_source}/linux/scripts/isolated-preflight/worker.sh"'
            ),
        )
        source = self.root / "worker/linux/scripts/isolated-preflight"
        source.mkdir(parents=True)
        evidence = self.root / "worker evidence"
        evidence.mkdir()
        worker = (self.scripts / "isolated-preflight/worker.sh").read_text()
        (source / "worker.sh").write_text(worker.replace("/evidence", shlex.quote(str(evidence))))
        logs = self.root / "worker/logs"
        for probe, make in ((None, 0), (42, 0), (0, 37), (0, 0)):
            with self.subTest(probe=probe, make=make):
                directory, trace, environment = self.ft_tools()
                environment.pop("FT_PYTHON", None)
                if probe is not None:
                    environment.update(
                        FT_PYTHON=str(directory / "ft-python"), FT_PROBE_RC=str(probe)
                    )
                environment["FT_MAKE_RC"] = str(make)
                if logs.is_symlink():
                    logs.unlink()
                result = subprocess.run(
                    ["bash", str(source / "worker.sh")],
                    env=environment,
                    capture_output=True,
                    check=False,
                )
                calls = trace.read_text().splitlines() if trace.exists() else []
                if probe is None:
                    self.assertNotEqual(result.returncode, 0)
                else:
                    self.assertEqual(result.returncode, probe or make, result.stderr)
                    self.assertTrue(calls[0].startswith("ft -I -c "))
                self.assertEqual(
                    any(call == "make preflight" for call in calls), probe == 0
                )

    def test_ft_worker_genuine_probe_refuses_the_normal_interpreter(self) -> None:
        worker = (self.scripts / "isolated-preflight/worker.sh").read_text()
        line = next(
            (
                line
                for line in worker.splitlines()
                if line.startswith('"${FT_PYTHON:?}" -I -c ')
            ),
            None,
        )
        self.assertIsNotNone(
            line,
            "The worker must run its genuine free-threading/header probe before make.",
        )
        assert line is not None
        code = shlex.split(line)[-1]
        result = subprocess.run(
            [sys.executable, "-I", "-c", code], capture_output=True, check=False
        )
        self.assertNotEqual(
            result.returncode,
            0,
            "A normal GIL interpreter cannot satisfy the FT prerequisite.",
        )
        include = self.root / "probe include"
        include.mkdir()
        (include / "Python.h").write_text("fixture existence only\n")
        for ft, gil, headers in (
            (1, False, True),
            (0, False, True),
            (1, True, True),
            (1, False, False),
        ):
            with self.subTest(ft=ft, gil=gil, headers=headers):
                selected = include if headers else self.root / "absent headers"
                patched = (
                    f"import sys,sysconfig; sysconfig.get_config_var=lambda name: {ft}; "
                    f"sys._is_gil_enabled=lambda: {gil!r}; "
                    f'sysconfig.get_paths=lambda: {{"include": {str(selected)!r}}}; exec({code!r})'
                )
                result = subprocess.run(
                    [sys.executable, "-I", "-c", patched],
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(
                    result.returncode == 0,
                    bool(ft and not gil and headers),
                    result.stderr,
                )
