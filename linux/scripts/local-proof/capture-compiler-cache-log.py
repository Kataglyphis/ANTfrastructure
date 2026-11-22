#!/usr/bin/env python3
"""Retain the image's existing cache error log; file presence does not attribute errors to a build phase."""

import hashlib
import json
import stat
import sys
from pathlib import Path

source = Path("/tmp/sccache.log")
output = Path(sys.argv[1])
assert output.is_dir() and not (output / "capture.json").exists()
record = {"source": str(source), "status": "missing", "scope": __doc__}
if source.exists() or source.is_symlink():
    info = source.lstat()
    assert stat.S_ISREG(info.st_mode) and info.st_size <= 64 * 1024 * 1024
    raw = source.read_bytes()
    assert len(raw) == info.st_size
    target = output / "sccache-error.log"
    with target.open("xb") as stream:
        stream.write(raw)
    target.chmod(0o600)
    record.update(status="captured", size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
(output / "capture.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record))
