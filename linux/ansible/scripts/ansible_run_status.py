#!/usr/bin/env python3
"""Turns an ansible-playbook log into the status file that Home Assistant's Ansible dashboard reads."""
import argparse
import datetime
import json
import os
import re
from collections.abc import Iterable, Mapping, Sequence
from typing import Any, Literal, TypedDict

RECAP = re.compile(
    r"^(\S+)\s*:\s*ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)"
    r"\s+skipped=(\d+)\s+rescued=(\d+)\s+ignored=(\d+)"
)
# A BACKUP note also stops at a backslash, so a stderr string's escaped newlines split it into its lines.
NOTE = re.compile(r"(GARAGE: [^\"]*|TOOLCHAIN: [^\"]*|BACKUP: [^\"\\]*|\S+ did not answer, so it was not updated)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# profile_tasks' summary line: the task's name, a ruler of dashes, its seconds.
TIMING = re.compile(r"^(.+?) -{3,} ([0-9.]+)s$")
SLOWEST = 10
COUNTS = ("ok", "changed", "unreachable", "failed", "skipped", "rescued", "ignored")
TAIL_LINES = 60
# Home Assistant's recorder drops a state whose attributes pass 16 KB; the tail stays well below.
TAIL_CHARS = 6000
HISTORY = 10


class HostStatus(TypedDict):
    name: str
    status: Literal["unreachable", "failed", "changed", "ok"]
    ok: int
    changed: int
    unreachable: int
    failed: int
    skipped: int
    rescued: int
    ignored: int


class SlowTask(TypedDict):
    task: str
    seconds: float


def host_status(counts: Mapping[str, int]) -> Literal["unreachable", "failed", "changed", "ok"]:
    """One word per host: unreachable, failed, changed or ok (a rescued task is no failure)."""
    if counts["unreachable"]:
        return "unreachable"
    if counts["failed"]:
        return "failed"
    return "changed" if counts["changed"] else "ok"


def parse(lines: Iterable[str]) -> tuple[list[HostStatus], list[str], list[SlowTask]]:
    """The PLAY RECAP's hosts, profile_tasks' slowest tasks and the notes the playbooks print, in log order."""
    hosts, notes, slowest, in_recap, in_timing = [], [], [], False, False
    for line in lines:
        if line.startswith("PLAY RECAP"):
            in_recap = True
            continue
        if line.startswith("TASKS RECAP"):
            in_recap, in_timing = False, True
            continue
        timing = TIMING.match(line) if in_timing else None
        if timing and len(slowest) < SLOWEST:
            slowest.append({"task": timing.group(1).strip(), "seconds": float(timing.group(2))})
            continue
        match = RECAP.match(line) if in_recap else None
        if match:
            counts = dict(zip(COUNTS, (int(n) for n in match.groups()[1:])))
            hosts.append({"name": match.group(1), "status": host_status(counts), **counts})
            continue
        for note in NOTE.findall(line):
            if note not in notes:
                notes.append(note)
    return hosts, notes, slowest


def tail(lines: Sequence[str]) -> str:
    """The log's last lines, as much as fits in TAIL_CHARS."""
    text = "\n".join(line for line in lines[-TAIL_LINES:] if line.strip())
    return text[-TAIL_CHARS:]


def seconds_between(started: str, finished: str) -> int | None:
    try:
        delta = datetime.datetime.fromisoformat(finished) - datetime.datetime.fromisoformat(started)
    except ValueError:
        return None
    return int(delta.total_seconds())


def build(args: argparse.Namespace, previous: Mapping[str, Any]) -> dict[str, Any]:
    with open(args.log, encoding="utf-8", errors="replace") as handle:
        lines = [ANSI.sub("", line.rstrip("\n")) for line in handle]
    hosts, notes, slowest = parse(lines)
    # No recap means ansible stopped before it could report; that is a failed run whatever rc says.
    result = "ok" if args.rc == 0 and hosts else "failed"
    run = {"finished": args.finished, "result": result, "rc": args.rc, "playbook": args.playbook}
    return {
        "result": result,
        "rc": args.rc,
        "playbook": args.playbook,
        "started": args.started,
        "finished": args.finished,
        "duration_s": seconds_between(args.started, args.finished),
        "next_run": args.next_run or None,
        "hosts": hosts,
        "hosts_total": len(hosts),
        "hosts_failed": sum(h["status"] == "failed" for h in hosts),
        "hosts_unreachable": sum(h["status"] == "unreachable" for h in hosts),
        "hosts_changed": sum(h["status"] == "changed" for h in hosts),
        "notes": notes,
        "slowest": slowest,
        "history": ([run] + previous.get("history", []))[:HISTORY],
        "log_file": os.path.basename(args.log),
        "log_tail": tail(lines),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True)
    parser.add_argument("--rc", type=int, required=True)
    parser.add_argument("--playbook", required=True)
    parser.add_argument("--started", required=True)
    parser.add_argument("--finished", required=True)
    parser.add_argument("--next-run", default="")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    previous = {}
    if os.path.exists(args.out):
        try:
            with open(args.out, encoding="utf-8") as handle:
                previous = json.load(handle)
        except (OSError, ValueError):
            previous = {}
    status = build(args, previous)
    # Written beside the old file and renamed, so Home Assistant never reads half a file.
    partial = args.out + ".partial"
    with open(partial, "w", encoding="utf-8") as handle:
        json.dump(status, handle, ensure_ascii=False, indent=1)
    os.replace(partial, args.out)


if __name__ == "__main__":
    main()
