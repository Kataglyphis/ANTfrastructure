#!/usr/bin/env python3
"""Clean one labelled invocation from ExecStopPost, including when its starter was killed."""

import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

from owned_containers import OwnedContainers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", default="nerdctl")
    parser.add_argument("--owner-label", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--cidfile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--retain", action="store_true")
    args = parser.parse_args()
    owner = OwnedContainers(args.engine, args.owner_label, args.run_id)
    record: dict[str, object] = {"status": "running", "owner_label": args.owner_label,
                                "run_id": args.run_id, "cidfile": str(args.cidfile), "retain": args.retain,
                                "started_at": datetime.datetime.now(datetime.UTC).isoformat()}
    with args.output.open("x", encoding="utf-8") as report:
        report.write(json.dumps(record, indent=2) + "\n")
        report.flush()
        status = 2
        try:
            status = owner.cleanup(retain=args.retain, cidfile=args.cidfile)
        except (OSError, TypeError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            record["error"] = str(error)
            print(f"cleanup-owned-containers: {error}", file=sys.stderr)
        finally:
            record.update(status="stopped-or-absent" if status == 0 else "failed", exit_status=status,
                          finished_at=datetime.datetime.now(datetime.UTC).isoformat())
            report.seek(0)
            report.write(json.dumps(record, indent=2) + "\n")
            report.truncate()
    return status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"cleanup-owned-containers: {error}", file=sys.stderr)
        sys.exit(2)
