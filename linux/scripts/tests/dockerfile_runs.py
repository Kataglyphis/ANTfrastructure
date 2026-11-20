"""Dockerfile RUN instructions and actual declared script maps for structural suites."""

import json
import subprocess
from collections.abc import Iterator
from pathlib import Path


def dockerfile_runs(path: str) -> Iterator[tuple[int, str]]:
    """Yield (1-based line, text) of each RUN with its backslash continuations and interleaved comments."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("RUN"):
            start = i
            while i + 1 < len(lines) and (lines[i].rstrip().endswith("\\") or lines[i].lstrip().startswith("#")):
                i += 1
            yield start + 1, "\n".join(lines[start:i + 1])
        i += 1


def dockerfile_script_map(root: Path, name: str) -> dict[str, str]:
    """Use a fresh gate process so copied fixture roots do not share imported module state."""
    result = subprocess.run(
        ["python3", str(root / "linux/scripts/verify_script_copy_coverage.py"), "--provided-scripts", name],
        capture_output=True, text=True, check=True, timeout=20,
    )
    return json.loads(result.stdout)
