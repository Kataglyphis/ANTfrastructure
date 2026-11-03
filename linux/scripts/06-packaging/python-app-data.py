#!/usr/bin/env python3
"""Copy app.json's data rows into a bundle; a lock row copies the lock and every file it names."""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path


def lock_names(lock: Path) -> list[str]:
    """The file column of a `sha256 file url` lock; an empty lock or one naming a path is refused."""
    names = [cols[1] for cols in (line.split() for line in lock.read_text(encoding="utf-8").splitlines())
             if len(cols) >= 3 and not cols[0].startswith("#")]
    if not names:
        sys.exit(f"{lock} names no file")
    bad = [n for n in names if Path(n).name != n or "\\" in n or n in (".", "..")]
    if bad:
        sys.exit(f"{lock} names a path, not a file: {', '.join(bad)}")
    return names


def copy_lock(item: dict[str, str], bundle: Path) -> None:
    lock = Path(item["lock"])
    dest = bundle / item["to"]
    dest.mkdir(parents=True, exist_ok=True)
    for name in [lock.name, *lock_names(lock)]:
        shutil.copy2(lock.parent / name, dest / name)
        print(f"  {item['lock']}: {name} -> {item['to']}/{name}")


def main(config: str, bundle: str) -> int:
    with open(config, encoding="utf-8") as config_file:
        data = json.load(config_file).get("data", [])
    for item in data:
        if "lock" in item:
            copy_lock(item, Path(bundle))
            continue
        dest = Path(bundle) / item["to"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item["from"], dest)
        print(f"  {item['from']} -> {item['to']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
