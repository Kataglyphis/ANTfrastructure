#!/usr/bin/env python3
"""Names Home Assistant's newest backup and fails unless it is encrypted and recent enough to copy."""
import argparse
import datetime
import json
import pathlib
import sys
import tarfile
from typing import Any


def metadata(path: pathlib.Path) -> dict[str, Any]:
    """The backup.json every Home Assistant backup archive starts with."""
    with tarfile.open(path) as outer:
        for member in outer.getmembers():
            handle = outer.extractfile(member) if member.name.lstrip("./") == "backup.json" else None
            if handle is not None:
                return json.load(handle)
    raise ValueError(f"{path.name} has no backup.json")


def newest(directory: str) -> tuple[datetime.datetime, pathlib.Path, dict[str, Any]]:
    """The archive whose backup.json carries the latest date, with that metadata."""
    found = []
    for path in sorted(pathlib.Path(directory).glob("*.tar")):
        meta = metadata(path)
        stamp = datetime.datetime.fromisoformat(meta["date"])
        found.append((stamp if stamp.tzinfo else stamp.astimezone(), path, meta))
    if not found:
        raise ValueError(f"no backup archive in {directory}")
    return max(found, key=lambda item: item[0])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--max-age-hours", type=float, required=True)
    parser.add_argument("--now", help="ISO time to measure the age against (tests)")
    args = parser.parse_args()
    now = datetime.datetime.fromisoformat(args.now) if args.now else datetime.datetime.now().astimezone()
    try:
        date, path, meta = newest(args.dir)
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"BACKUP: homeassistant: {error}", file=sys.stderr)
        return 1
    age_hours = round((now - date).total_seconds() / 3600, 1)
    report = {
        "file": str(path),
        "name": meta.get("name", path.name),
        "date": meta["date"],
        "protected": meta.get("protected") is True,
        "age_hours": age_hours,
        "version": (meta.get("homeassistant") or {}).get("version"),
    }
    print(json.dumps(report))
    problems = []
    # An unencrypted archive carries every token in .storage; it never leaves the Pi.
    if not report["protected"]:
        problems.append("is not encrypted: turn on encryption for 'This system' under Settings > System > Backups")
    if age_hours > args.max_age_hours:
        problems.append(f"is {age_hours} h old, more than {args.max_age_hours:g} h: Home Assistant stopped backing up")
    for problem in problems:
        print(f"BACKUP: homeassistant: {path.name} {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
