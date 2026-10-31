# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Metric records shared by the quality-report collectors; see docs/code-quality-tooling.md#quality-report"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field

SCHEMA_VERSION = 1
LOWER, HIGHER = "lower", "higher"
CODE, REPORT = "code", "report"
COLLECTED, NOT_COLLECTED, FAILED = "collected", "not-collected", "failed"


@dataclass(frozen=True)
class Item:
    """One located queue entry; weight orders the queue, worst first."""

    path: str
    line: int
    weight: float
    detail: str


@dataclass
class Metric:
    """One measurement; members makes it set-valued, items feed queue.md only."""

    name: str
    value: float | None
    unit: str
    better: str
    klass: str
    source: str
    members: list[str] | None = None
    status: str = COLLECTED
    reason: str = ""
    items: list[Item] = field(default_factory=list)

    def record(self) -> dict[str, object]:
        """The measurements.json entry; items stay out of the record."""
        row: dict[str, object] = {"value": self.value, "unit": self.unit, "better": self.better,
                                  "class": self.klass, "source": self.source,
                                  "status": self.status}
        if self.members is not None:
            row["members"] = sorted(self.members)
        if self.reason:
            row["reason"] = self.reason
        return row


def missing(name: str, unit: str, better: str, klass: str, source: str, reason: str) -> Metric:
    """A metric whose lane or file is absent: never 0, never held."""
    return Metric(name, None, unit, better, klass, source, status=NOT_COLLECTED, reason=reason)


def failed(name: str, unit: str, better: str, klass: str, source: str, reason: str) -> Metric:
    """A metric whose collector or input broke; it makes the verdict incomplete."""
    return Metric(name, None, unit, better, klass, source, status=FAILED, reason=reason)


def normalise(text: str) -> str:
    """Whitespace-normalised line text, the stable part of a set member key."""
    return " ".join(text.split())


def keyed(rows: list[tuple[str, str]]) -> list[str]:
    """`prefix|text|n` keys; n counts earlier identical rows so a moved line keeps its key."""
    seen: dict[tuple[str, str], int] = {}
    keys = []
    for prefix, text in rows:
        n = seen.get((prefix, text), 0)
        seen[(prefix, text)] = n + 1
        keys.append(f"{prefix}|{text}|{n}")
    return keys


def tracked(root: str, *pathspecs: str) -> list[str]:
    """Tracked files under root, as repo-relative paths; submodule contents stay out."""
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *pathspecs],
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise OSError(f"git ls-files failed in {root}: {out.stderr.strip()}")
    return sorted(rel for rel in out.stdout.split("\0")
                  if rel and os.path.isfile(os.path.join(root, rel))
                  and not os.path.islink(os.path.join(root, rel)))


LOCATED = re.compile(r"^(?P<path>[^:\s][^:]*):(?P<line>\d+):(?:\d+:)?\s*(?P<detail>.*)$")


def located(line: str) -> tuple[str, int, str] | None:
    """(path, line, detail) from a `path:line[:col]: detail` report line."""
    match = LOCATED.match(line.strip())
    if not match:
        return None
    return match.group("path"), int(match.group("line")), match.group("detail")


def by_file_weight(rows: list[tuple[str, int, str]]) -> list[Item]:
    """Items weighted by how many entries their file holds, so the densest files lead."""
    per_file: dict[str, int] = {}
    for path, _line, _detail in rows:
        per_file[path] = per_file.get(path, 0) + 1
    return [Item(path, line, per_file[path], detail) for path, line, detail in rows]
