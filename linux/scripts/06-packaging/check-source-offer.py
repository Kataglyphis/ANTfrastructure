# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""check-source-offer.py <release dir> <index>: every source and build file the offer index names lies in the release with its recorded SHA-256.

The index is the <owner>-sources.json an image build writes; see docs/consumer-image-contract.md § The FFmpeg source offer.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


def findings(release: Path, index: str) -> list[str]:
    record = json.loads((release / index).read_text(encoding="utf-8"))
    sources = record.get("sources") or []
    found = [] if sources else [f"{index} offers no source"]
    for row in sources + (record.get("build") or []):
        name = Path(str(row["file"])).name
        path = release / name
        if not path.is_file():
            found.append(f"{name} is missing")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != str(row["sha256"]).lower():
            found.append(f"{name} is not the bytes {index} records")
    return found


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    problems = findings(Path(sys.argv[1]), sys.argv[2])
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
