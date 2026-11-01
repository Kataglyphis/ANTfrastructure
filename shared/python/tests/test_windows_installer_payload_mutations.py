#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
"""Prove installer fixture tests reject changed extraction guards, without a GPU."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "windows_installer_payload.py"
TEST = ROOT / "tests/test_windows_installer_payload.py"
PROCESS = ROOT / "windows_gpu_process.py"
MUTATIONS = (
    ('or ".." in PurePosixPath(item.filename).parts', "or False"),
    ("len({name.casefold() for name in names}) != len(names)", "False"),
    ("shutil.disk_usage(directory).free - size < floor + cushion", "False"),
    ("or size > limit:", ":"),
)


def run(path: Path) -> int:
    return subprocess.run(
        [sys.executable, "-I", str(path)], capture_output=True, text=True, check=False
    ).returncode


def main() -> None:
    original = SOURCE.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root / "tests").mkdir()
        (root / PROCESS.name).write_bytes(PROCESS.read_bytes())
        (root / "tests" / TEST.name).write_bytes(TEST.read_bytes())
        candidate = root / SOURCE.name
        test = root / "tests" / TEST.name
        candidate.write_text(original, encoding="utf-8")
        if run(test) != 0:
            raise SystemExit("installer fixture baseline failed")
        for old, new in MUTATIONS:
            if original.count(old) != 1:
                raise SystemExit(f"installer mutation marker changed: {old}")
            mutant = original.replace(old, new, 1)
            compile(mutant, str(candidate), "exec")
            candidate.write_text(mutant, encoding="utf-8")
            if run(test) == 0:
                raise SystemExit(f"installer fixture missed mutation: {old}")
        marker = "tempfile.TemporaryDirectory("
        if original.count(marker) != 2:
            raise SystemExit("installer temporary-directory mutation marker changed")
        mutant = original.replace(marker, "_leaky_temporary_directory(")
        mutant += (
            "\ndef _leaky_temporary_directory(*args, **kwargs):\n"
            "    import contextlib\n"
            "    return contextlib.nullcontext(tempfile.mkdtemp(*args, **kwargs))\n"
        )
        compile(mutant, str(candidate), "exec")
        candidate.write_text(mutant, encoding="utf-8")
        if run(test) == 0:
            raise SystemExit("installer fixture missed retained-payload mutation")
    print(f"Installer payload fixture rejected {len(MUTATIONS) + 1} code mutations")


if __name__ == "__main__":
    main()
