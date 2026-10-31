# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""The --json record and the report-only Python pass of verify_code_dupes.py; see docs/code-quality-tooling.md#measurements-as-json"""

from __future__ import annotations

import argparse
from collections.abc import Iterable
from pathlib import Path

import verify_code_dupes as dupes


def unit_pair_counts(rels: Iterable[str], units: Iterable[dupes.Unit],
                     pairs: Iterable[Iterable[str]]) -> dict[str, dict[str, int]]:
    """Units and over-threshold file pairs per file; a same-file pair counts once for its file."""
    rows = {rel: {"units": 0, "pairs": 0} for rel in rels}
    for rel, _line in units:
        rows.setdefault(rel, {"units": 0, "pairs": 0})["units"] += 1
    for pair in pairs:
        for rel in set(pair):
            rows.setdefault(rel, {"units": 0, "pairs": 0})["pairs"] += 1
    return rows


def _rels(files: list[tuple[Path, str]]) -> list[str]:
    return [path.relative_to(dupes.REPO_ROOT).as_posix() for path, _kind in files]


def _python_kind(name: str) -> str | None:
    return "py" if name.endswith(".py") else None


def python_pass(threshold: int) -> dict[str, object]:
    """Print Python file pairs over the threshold, indexed apart so no shell or PowerShell count moves."""
    import lang_units  # Imported here: the default scan must not depend on the extra readers.

    files = dupes.collect(_python_kind)
    owners, heads, texts, _lines, kind_of = dupes.index_units(
        files, readers={"py": lang_units.py_units})
    shared, _spread, _families, _suppressed = dupes.collect_shared(owners, heads, kind_of)
    _measured, per_file = dupes._collapse_to_files(shared, threshold)
    for _key, (n, a, b) in sorted(per_file.items(), key=lambda kv: (-kv[1][0], sorted(kv[0]))):
        print(f"REPORT-ONLY: python {n} shared shingles  {a[0]}:{a[1]}  <->  {b[0]}:{b[1]}")
    print(f"REPORT-ONLY: {len(per_file)} Python file pair(s) over {threshold} shared shingles "
          f"in {len(texts)} units in {len(files)} files (never fatal)")
    return {"kinds": ["py"], "files": unit_pair_counts(_rels(files), texts, per_file),
            "totals": {"files": len(files), "units": len(texts), "pairs": len(per_file)}}


def finish(
    args: argparse.Namespace, files: list[tuple[Path, str]], texts: dupes.Texts,
    per_file: dupes.PerFile, findings: list[dupes.Finding], allowed: list[dupes.AllowedPair],
    allow: dupes.Allow, suppressed: int,
) -> None:
    """Run the report-only Python pass when asked, then write the --json record when asked."""
    extra = python_pass(args.threshold) if args.extra_languages else None
    if not args.json:
        return
    totals = {"files": len(files), "units": len(texts), "pairs": len(per_file),
              "findings": len(findings), "allowed": len(allowed), "allow_rows": len(allow),
              "suppressed": suppressed}
    sections = {"report_only": extra} if extra is not None else {}
    dupes.gate_scope.write_json(args.json, "code-dupes", dupes.REPO_ROOT, totals,
                                unit_pair_counts(_rels(files), texts, per_file),
                                limits={"threshold": args.threshold, "shingle": dupes.SHINGLE},
                                items=pair_items(per_file.values()), **sections)


def pair_items(pairs: Iterable[tuple[int, dupes.Unit, dupes.Unit]],
               prefixes: tuple[str, str] = ("", "")) -> list[dict[str, object]]:
    """One located record per over-threshold pair, most shared shingles first."""
    ranked = sorted(pairs, key=lambda pair: (-pair[0], pair[1][0], pair[1][1]))
    return [{"path": a[0].removeprefix(prefixes[0]), "line": a[1],
             "other": f"{b[0].removeprefix(prefixes[1])}:{b[1]}", "shingles": n}
            for n, a, b in ranked]
