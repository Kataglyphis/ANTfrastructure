#!/usr/bin/env python3
"""Record one real bare-soname load in a fresh process; no LLVM ABI or inference proof."""
import ctypes
import hashlib
import json
import sys
from pathlib import Path

name, root, maps_output = sys.argv[1:]
library = ctypes.CDLL(name)
text = Path("/proc/self/maps").read_text()
Path(maps_output).write_text(text)
paths = set()
for line in text.splitlines():
    fields = line.split(maxsplit=5)
    if len(fields) == 6 and fields[5].startswith("/"):
        path = Path(fields[5])
        if path.name == name:
            paths.add(path.resolve())
assert paths and all(path.is_relative_to(Path(root).resolve()) for path in paths), paths
records = []
for path in sorted(paths):
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    records.append({"path": str(path), "sha256": digest, "size": path.stat().st_size})
print(json.dumps({"status": "passed-bare-soname-mapping-only", "soname": name,
                  "expected_root": root, "loaded": records}, indent=2))
