"""The source-pins.txt rows that repeat versions.env pins; sync_versions.py writes and checks them."""

from __future__ import annotations

import sys
from pathlib import Path

SOURCE_PINS = "linux/scripts/03-media/build/onnxruntime/build/lib/source-pins.txt"

# Row name -> (tag key, commit key); the extensions row has no versions.env key because GenAI's deps.txt names it.
ROWS: dict[str, tuple[str, str]] = {
    "onnxruntime": ("ONNXRUNTIME_VERSION", "ONNXRUNTIME_WINDOWS_SOURCE_COMMIT"),
    "onnxruntime-genai": ("ONNXRUNTIME_GENAI_VERSION", "ONNXRUNTIME_GENAI_WINDOWS_SOURCE_COMMIT"),
}


def _sync(root: Path, versions: dict[str, str], write: bool) -> tuple[list[str], list[str]]:
    """(stale rows, problems); a missing key or a missing or repeated row is a problem in both modes."""
    path = root / SOURCE_PINS
    problems = [f"versions.env has no {k}" for keys in ROWS.values() for k in keys if not versions.get(k)]
    if problems:
        return [], problems
    with open(path, encoding="utf-8", newline="") as fh:
        lines = fh.read().splitlines(keepends=True)
    seen: dict[str, int] = {}
    stale = []
    for i, line in enumerate(lines):
        body = line.rstrip("\r\n")
        fields = body.split("|")
        if fields[0] not in ROWS or len(fields) < 4:
            continue
        seen[fields[0]] = seen.get(fields[0], 0) + 1
        tag_key, commit_key = ROWS[fields[0]]
        want = [fields[0], versions[tag_key], versions[commit_key], *fields[3:]]
        if fields != want:
            stale.append(f"{fields[0]}: {fields[1]} {fields[2]} -> {want[1]} {want[2]}")
            lines[i] = "|".join(want) + line[len(body):]
    problems = [f"{SOURCE_PINS} has {seen.get(n, 0)} rows named {n}, not one" for n in ROWS if seen.get(n, 0) != 1]
    if write and stale and not problems:
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write("".join(lines))
    return stale, problems


def check_source_pins(root: Path, versions: dict[str, str]) -> int:
    stale, problems = _sync(root, versions, write=False)
    for item in problems:
        print(item, file=sys.stderr)
    if stale:
        print("ORT source pins differ from versions.env:", file=sys.stderr)
        for item in stale:
            print(f"- {item}", file=sys.stderr)
        print("Run: python3 docs/scripts/sync_versions.py --write", file=sys.stderr)
    if stale or problems:
        return 1
    print("ORT source pins match versions.env.")
    return 0


def write_source_pins(root: Path, versions: dict[str, str]) -> int:
    stale, problems = _sync(root, versions, write=True)
    for item in problems:
        print(item, file=sys.stderr)
    if problems:
        return 1
    print(f"Synced ORT source pins: {', '.join(stale)}" if stale else "ORT source pins already match versions.env.")
    return 0
