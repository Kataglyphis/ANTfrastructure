#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Grade osv-scanner JSON into security-audit.json; security-audit.sh is the entry point.

Not covered: reachability, code vendored outside a lockfile, container images, and whether a
fixed version exists. See docs/vulnerability-scanning.md#lockfile-audit-security-auditsh
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from dataclasses import asdict, dataclass
from pathlib import Path

RANK = {"LOW": 1, "MODERATE": 2, "HIGH": 3, "CRITICAL": 4}
BLOCKING = frozenset({"HIGH", "CRITICAL"})
CVSS_HIGH = 7.0
CVSS_MODERATE = 4.0
SCHEMA = "security-audit/1"
_PUB_PACKAGE = re.compile(r"^  (?P<name>[^\s:#][^:]*):\s*$")
_PUB_VERSION = re.compile(r"^    version:\s*\"?(?P<version>[^\"\s]+)\"?\s*$")


class AuditError(Exception):
    """An input the audit cannot grade; never reported as zero findings."""


@dataclass(frozen=True)
class Finding:
    id: str
    aliases: list[str]
    severity: str
    package: str
    name: str
    version: str
    ecosystem: str
    lockfile: str
    in_base: bool | None


def normalize(name: str, lockfile: str) -> str:
    """PEP 503 names for uv.lock, where osv-scanner and the lock may spell one package two ways."""
    if Path(lockfile).name == "uv.lock":
        return re.sub(r"[-_.]+", "-", name).lower()
    return name


def _toml_packages(text: str) -> set[tuple[str, str]]:
    packages = tomllib.loads(text).get("package", [])
    return {(str(p["name"]), str(p["version"])) for p in packages
            if isinstance(p, dict) and "name" in p and "version" in p}


def _pubspec_packages(text: str) -> set[tuple[str, str]]:
    found, name, inside = set(), "", False
    for line in text.splitlines():
        if not line.startswith(" "):
            inside = line.rstrip() == "packages:"
            continue
        if not inside:
            continue
        head = _PUB_PACKAGE.match(line)
        if head:
            name = head.group("name").strip("\"'")
            continue
        version = _PUB_VERSION.match(line)
        if version and name:
            found.add((name, version.group("version")))
    return found


def _npm_name(key: str) -> str:
    return key.rsplit("node_modules/", 1)[-1]


def _npm_packages(text: str) -> set[tuple[str, str]]:
    data = json.loads(text)
    found = {(str(meta.get("name") or _npm_name(key)), str(meta["version"]))
             for key, meta in (data.get("packages") or {}).items()
             if key and isinstance(meta, dict) and "version" in meta}
    stack = [data.get("dependencies") or {}]
    while stack:
        for name, meta in stack.pop().items():
            if isinstance(meta, dict) and "version" in meta:
                found.add((str(name), str(meta["version"])))
                stack.append(meta.get("dependencies") or {})
    return found


PARSERS = {
    "uv.lock": _toml_packages,
    "Cargo.lock": _toml_packages,
    "pubspec.lock": _pubspec_packages,
    "package-lock.json": _npm_packages,
}


def lock_packages(path: Path, lockfile: str) -> set[tuple[str, str]]:
    """Every (name, version) a lockfile pins, names normalized as the findings are."""
    parser = PARSERS.get(Path(lockfile).name)
    if parser is None:
        raise AuditError(f"{lockfile}: no parser for this lockfile kind")
    try:
        pairs = parser(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise AuditError(f"{lockfile}: the base copy cannot be read ({exc})") from exc
    return {(normalize(name, lockfile), version) for name, version in pairs}


def grade(group: dict, vulns: dict[str, dict]) -> str:
    """GHSA database severity first, then the CVSS score; no score at all counts as HIGH."""
    named = []
    for vid in list(group.get("ids") or []) + list(group.get("aliases") or []):
        raw = ((vulns.get(vid) or {}).get("database_specific") or {}).get("severity")
        level = str(raw).upper().replace("MEDIUM", "MODERATE") if raw else ""
        if level in RANK:
            named.append(level)
    if named:
        return max(named, key=RANK.__getitem__)
    try:
        score = float(group.get("max_severity") or "")
    except ValueError:
        return "HIGH"
    if score >= CVSS_HIGH:
        return "HIGH"
    return "MODERATE" if score >= CVSS_MODERATE else "LOW"


def _advisory_id(group: dict) -> tuple[str, list[str]]:
    ids = [str(i) for i in group.get("ids") or []]
    aliases = sorted({str(a) for a in group.get("aliases") or []} | set(ids))
    ghsa = [i for i in ids + aliases if i.startswith("GHSA-")]
    if not ids and not ghsa:
        raise AuditError("an osv-scanner group carries no advisory id")
    return (ghsa or ids)[0], aliases


def _groups(entry: dict) -> list[dict]:
    vulns = entry.get("vulnerabilities") or []
    return entry.get("groups") or [{"ids": [v.get("id")], "aliases": v.get("aliases") or []} for v in vulns]


def relative_source(raw: str, root: Path) -> str:
    path = Path(raw)
    try:
        return path.resolve().relative_to(root.resolve()).as_posix() if path.is_absolute() else path.as_posix()
    except ValueError as exc:
        raise AuditError(f"osv-scanner reported {raw}, which is outside {root}") from exc


def load_findings(report: dict, root: Path, base: dict[str, set[tuple[str, str]] | None] | None
                  ) -> tuple[list[Finding], set[str]]:
    """-> (findings, lockfiles the scanner reported)."""
    findings, seen = [], set()
    for result in report.get("results") or []:
        lockfile = relative_source(str((result.get("source") or {}).get("path", "")), root)
        seen.add(lockfile)
        pinned = None if base is None else base.get(lockfile)
        for entry in result.get("packages") or []:
            pkg = entry.get("package") or {}
            name, version = str(pkg.get("name", "")), str(pkg.get("version", ""))
            vulns = {str(v.get("id")): v for v in entry.get("vulnerabilities") or []}
            for group in _groups(entry):
                vid, aliases = _advisory_id(group)
                in_base = None if base is None else (pinned is not None and (normalize(name, lockfile), version) in pinned)
                findings.append(Finding(vid, aliases, grade(group, vulns), f"{name}@{version}", name, version,
                                        str(pkg.get("ecosystem", "")), lockfile, in_base))
    return sorted(findings, key=lambda f: (f.lockfile, f.name, f.version, f.id)), seen


def read_cargo(path: Path | None) -> list[dict]:
    rows = []
    if path is None:
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        lockfile, code = line.split("\t")
        rows.append({"lockfile": lockfile, "exit_code": int(code), "status": "pass" if code == "0" else "fail"})
    return rows


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--osv", type=Path, required=True, help="osv-scanner --format json output")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--lockfiles", type=Path, required=True, help="one scanned lockfile per line, root-relative")
    ap.add_argument("--mode", choices=("gate", "report"), required=True)
    ap.add_argument("--base", default="", help="the base commit, recorded in the output")
    ap.add_argument("--base-dir", type=Path, help="gate mode: the base commit's lockfiles at their relative paths")
    ap.add_argument("--cargo", type=Path, help="lockfile<TAB>exit code per cargo_security_checks.sh run")
    ap.add_argument("--scanner-version", default="")
    ap.add_argument("--output", type=Path, required=True)
    return ap.parse_args(argv)


def base_packages(args: argparse.Namespace, lockfiles: list[str]) -> dict[str, set[tuple[str, str]] | None] | None:
    if args.mode != "gate":
        return None
    if args.base_dir is None or not args.base_dir.is_dir():
        raise AuditError("gate mode needs --base-dir with the base commit's lockfiles")
    return {lock: lock_packages(args.base_dir / lock, lock) if (args.base_dir / lock).is_file() else None
            for lock in lockfiles}


def run(args: argparse.Namespace) -> int:
    lockfiles = [line for line in args.lockfiles.read_text(encoding="utf-8").splitlines() if line]
    try:
        report = json.loads(args.osv.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise AuditError(f"osv-scanner output {args.osv} is missing or not JSON ({exc})") from exc
    findings, seen = load_findings(report, args.root, base_packages(args, lockfiles))
    unread = sorted(set(lockfiles) - seen)
    if unread:
        raise AuditError(f"osv-scanner reported nothing for {', '.join(unread)}; its packages were graded by nothing")
    blocking = [f for f in findings if args.mode == "gate" and f.severity in BLOCKING and not f.in_base]
    out = {
        "schema": SCHEMA,
        "scanner": {"name": "osv-scanner", "version": args.scanner_version},
        "mode": args.mode,
        "base": args.base or None,
        "lockfiles": lockfiles,
        "findings": [asdict(f) for f in findings],
        "cargo_checks": read_cargo(args.cargo),
        "blocking": [asdict(f) for f in blocking],
        "verdict": "fail" if blocking else "pass",
    }
    args.output.write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8")
    for f in findings:
        state = "" if f.in_base is None else (" known" if f.in_base else " NEW")
        print(f"  {f.severity:<8} {f.id} {f.package} {f.lockfile}{state}")
    for row in out["cargo_checks"]:
        print(f"  cargo_security_checks.sh {row['lockfile']}: {row['status']} (exit {row['exit_code']})")
    print(f"security-audit: {len(lockfiles)} lockfile(s), {len(findings)} finding(s), mode {args.mode}")
    for f in blocking:
        print(f"BLOCKING: {f.severity} {f.id} {f.package} is new in {f.lockfile} since {args.base}", file=sys.stderr)
    return 1 if blocking else 0


def main(argv: list[str]) -> int:
    try:
        return run(parse_args(argv))
    except AuditError as exc:
        print(f"security-audit: ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
