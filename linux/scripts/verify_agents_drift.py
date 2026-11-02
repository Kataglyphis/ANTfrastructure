#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Fail when a consumer's AGENTS.md, docs build list or BACKLOG.md no longer names what its tree holds.

It does not check prose accuracy: a stale sentence that still names the right file passes, and a CMake
target built from a variable no literal set() or project() defines is not counted.
docs/code-quality-tooling.md#agents-drift-agents-drift
"""
import argparse
import fnmatch
import functools
import json
import os
import re
import subprocess
import sys
import tomllib
from collections.abc import Iterator
from typing import NamedTuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope

HUB = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AGENTS = "AGENTS.md"
BACKLOG = "BACKLOG.md"
CONFIG = "quality-report.toml"
TEMPLATE = "shared/templates/AGENTS.md.template"
LANGUAGE_AI = "docs/language-ai.md"
DUPLICATE_MIN = 41
LAI_LETTERS = {"AccelerANTgine": "A", "OxidANT": "O", "OrchestrANT": "P", "OmniAccelerANT": "F"}
NUMBERED = re.compile(r"^## (\d+)\. ")
FENCE = re.compile(r"^\s*(```|~~~)")
ID_CELL = re.compile(r"^LAI-[A-Z]\d+(, LAI-[A-Z]\d+)*( and spikes)?$")
LAI_ID = re.compile(r"LAI-[A-Z]\d+")
ADD_EXECUTABLE = re.compile(r"\badd_executable\s*\(\s*([^\s)]+)", re.IGNORECASE)
INSTALL_TARGETS = re.compile(r"\binstall\s*\(\s*TARGETS\s+([^)]*)\)", re.IGNORECASE)
CMAKE_KEYWORD = re.compile(r"^[A-Z_]+$")
CMAKE_SET = re.compile(r"\bset\s*\(\s*(\w+)\s+\"?([\w.-]+)\"?\s*\)", re.IGNORECASE)
CMAKE_PROJECT = re.compile(r"\bproject\s*\(\s*([\w.-]+)", re.IGNORECASE)
CMAKE_REF = re.compile(r"\$\{(\w+)\}")


class Finding(NamedTuple):
    """One drift finding, in the row shape quality_report_text.agents_drift reads."""

    check: str
    path: str
    line: int
    detail: str


def read_text(root: str, rel: str) -> str:
    """A tracked text file, decoded the same way on every host."""
    with open(os.path.join(root, rel), encoding="utf-8") as fh:
        return fh.read()


def names(name: str, text: str) -> bool:
    """A whole-name mention: `ci.yml` is not named by `linux-ci.yml`."""
    return re.search(rf"(?<![\w-]){re.escape(name)}(?![\w-])", text) is not None


def sections(agents: str) -> dict[str, str]:
    """Numbered `## N. ` sections by number; a `##` inside a code fence is no heading."""
    found: dict[str, list[str]] = {}
    current: list[str] | None = None
    fenced = False
    for line in agents.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        match = None if fenced else NUMBERED.match(line)
        if match:
            current = found.setdefault(match.group(1), [])
        elif not fenced and line.startswith("## "):
            current = None
        if current is not None:
            current.append(line)
    return {number: "\n".join(lines) for number, lines in found.items()}


@functools.cache
def _all_tracked(root: str) -> tuple[str, ...]:
    return tuple(gate_scope.tracked(root, []))


def tracked(root: str, patterns: list[str]) -> list[str]:
    """Tracked first-party paths; a submodule's own tree is its repository's to grade."""
    return [rel for rel in _all_tracked(root) if any(fnmatch.fnmatchcase(rel, p) for p in patterns)]


def toml_doc(root: str, rel: str) -> dict:
    """A parsed tracked TOML file; malformed input stops the gate rather than shrink it."""
    try:
        return tomllib.loads(read_text(root, rel))
    except tomllib.TOMLDecodeError as exc:
        raise gate_scope.ScopeError(f"{rel}: {exc}") from exc


def _cargo_bins(root: str, rel: str) -> Iterator[str]:
    """Explicit [[bin]] names, and the implicit one a package's src/main.rs builds."""
    doc = toml_doc(root, rel)
    for row in doc.get("bin", []):
        if row.get("name"):
            yield row["name"]
    package = doc.get("package", {}).get("name")
    if package and os.path.isfile(os.path.join(root, os.path.dirname(rel), "src", "main.rs")):
        yield package


def _cmake_variables(root: str, rels: list[str]) -> dict[str, str]:
    """Literal `set()` values and the root project's name, which target names are built from."""
    found: dict[str, str] = {}
    for rel in rels:
        for name, value in CMAKE_SET.findall(_cmake_text(root, rel)):
            found.setdefault(name, value)
    if "CMakeLists.txt" in rels:
        project = CMAKE_PROJECT.search(_cmake_text(root, "CMakeLists.txt"))
        if project:
            found["PROJECT_NAME"] = project.group(1)
    return found


def _cmake_text(root: str, rel: str) -> str:
    return re.sub(r"#.*", "", read_text(root, rel))


def _install_targets(block: str) -> Iterator[str]:
    for word in block.split():
        if CMAKE_KEYWORD.match(word):
            return
        yield word


def _cmake_installed(root: str) -> set[str]:
    """Executables a tracked CMake file both defines and installs, with known variables expanded."""
    rels = tracked(root, ["*CMakeLists.txt", "*.cmake"])
    executables: set[str] = set()
    installed: set[str] = set()
    for rel in rels:
        text = _cmake_text(root, rel)
        executables.update(ADD_EXECUTABLE.findall(text))
        for block in INSTALL_TARGETS.findall(text):
            installed.update(_install_targets(block))
    variables = _cmake_variables(root, rels)
    expanded = {CMAKE_REF.sub(lambda m: variables.get(m.group(1), m.group(0)), name)
                for name in executables & installed}
    return {name for name in expanded if "$" not in name}


def console_scripts(root: str) -> list[str]:
    """Every installed command: pyproject scripts, Cargo binaries and installed CMake executables."""
    found: set[str] = set()
    for rel in tracked(root, ["*pyproject.toml"]):
        found.update(toml_doc(root, rel).get("project", {}).get("scripts", {}))
    for rel in tracked(root, ["*Cargo.toml"]):
        found.update(_cargo_bins(root, rel))
    found.update(_cmake_installed(root))
    return sorted(found)


def check_section5(root: str, agents: str) -> Iterator[Finding]:
    """Workflows and console scripts section 5 (Build, run, test) does not name."""
    body = sections(agents).get("5", "")
    for rel in tracked(root, [".github/workflows/*.yml"]):
        name = os.path.basename(rel)
        if not names(name, body):
            yield Finding("section5-workflow", AGENTS, 1, f"section 5 does not name workflow {name}")
    for name in console_scripts(root):
        if not names(name, body):
            yield Finding("section5-script", AGENTS, 1, f"section 5 does not name console script {name}")


def _python_packages(root: str) -> Iterator[tuple[str, ...]]:
    for rel in tracked(root, ["*__init__.py"]):
        if rel.count("/") == 1:
            yield (os.path.dirname(rel),)


def _cargo_crates(root: str) -> Iterator[tuple[str, ...]]:
    for rel in tracked(root, ["*Cargo.toml"]):
        package = toml_doc(root, rel).get("package", {}).get("name")
        directory = os.path.dirname(rel)
        if package:
            yield (directory, package) if directory else (package,)


def _dart_packages(root: str) -> Iterator[tuple[str, ...]]:
    for rel in tracked(root, ["*pubspec.yaml"]):
        directory = os.path.dirname(rel)
        if directory and directory.count("/") <= 1:
            yield (directory, os.path.basename(directory))


def _src_modules(root: str) -> Iterator[tuple[str, ...]]:
    for rel in tracked(root, ["Src/*", "src/*"]):
        parts = rel.split("/")
        if len(parts) > 2:
            yield ("/".join(parts[:2]), parts[1])


def check_section1(root: str, agents: str) -> Iterator[Finding]:
    """Top-level packages, crates and Src modules section 1 names by neither path nor name."""
    body = sections(agents).get("1", "")
    units = {*_python_packages(root), *_cargo_crates(root),
             *_dart_packages(root), *_src_modules(root)}
    for unit in sorted(units):
        if not any(names(name, body) for name in unit):
            yield Finding("section1-unit", AGENTS, 1, f"section 1 does not name {unit[0]}")


def check_headings(agents: str, hub: str) -> Iterator[Finding]:
    """The template's numbered headings, all present and in the template's order."""
    template = read_text(hub, TEMPLATE).splitlines()
    wanted = [line.rstrip() for line in template if NUMBERED.match(line)]
    fenced = False
    have = []
    for line in agents.splitlines():
        fenced = fenced != bool(FENCE.match(line))
        if not fenced and NUMBERED.match(line):
            have.append(line.rstrip())
    if [line for line in have if line in wanted] != wanted:
        yield Finding("headings", AGENTS, 1, f"the headings must be, in order: {'; '.join(wanted)}")


def check_duplicates(agents: str) -> Iterator[Finding]:
    """A long line twice is one rule with two futures; only one of them gets the next fix."""
    first: dict[str, int] = {}
    for number, line in enumerate(agents.splitlines(), 1):
        if len(line) < DUPLICATE_MIN:
            continue
        if line in first:
            yield Finding("duplicate-line", AGENTS, number,
                          f"repeats line {first[line]} verbatim: {line.strip()[:80]}")
        first.setdefault(line, number)


def docs_pages(root: str, source: str) -> list[str]:
    """Source pages; a `_`-prefixed directory holds includes and generated reports, not pages."""
    pages = []
    for rel in tracked(root, [f"{source}/*.md", f"{source}/*.rst"]):
        if not any(part.startswith("_") for part in rel.split("/")):
            pages.append(rel)
    return pages


def _listed(page: str, source: str, build_list: str) -> bool:
    """The page's path anywhere, or its extension-free toctree entry on a line of its own."""
    below = os.path.relpath(page, source)
    if names(page, build_list) or names(below, build_list):
        return True
    stem = os.path.splitext(below)[0]
    entry = re.compile(rf"^\s*(?:.*<)?{re.escape(stem)}>?\s*$", re.MULTILINE)
    return entry.search(build_list) is not None


def check_docs(root: str) -> Iterator[Finding]:
    """A docs page its build list leaves out is written, reviewed and never published."""
    if not os.path.isfile(os.path.join(root, CONFIG)):
        raise gate_scope.ScopeError(f"no {CONFIG}: it declares the docs build list this gate reads")
    docs = toml_doc(root, CONFIG).get("docs", {})
    if not docs.get("build_list") or not docs.get("source"):
        raise gate_scope.ScopeError(f"{CONFIG} must declare [docs] build_list and source")
    listing, source = docs["build_list"], docs["source"]
    if not os.path.isfile(os.path.join(root, listing)):
        raise gate_scope.ScopeError(f"{CONFIG} names a docs build list that does not exist: {listing}")
    text = read_text(root, listing)
    for page in docs_pages(root, source):
        if page != listing and not _listed(page, source, text):
            yield Finding("docs-page", listing, 1, f"the docs build list leaves out {page}")


def open_lai_ids(language_ai: str) -> list[str]:
    """IDs whose own table row carries no `Done`; a mention in another row's prose opens nothing."""
    found = []
    for line in language_ai.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")] if line.startswith("|") else []
        if "Done " in line:
            continue
        for cell in cells[:2]:
            if ID_CELL.match(cell):
                found.extend(LAI_ID.findall(cell))
    return found


def repo_name(root: str) -> str:
    """The origin remote's name, which survives a clone into any directory."""
    out = subprocess.run(["git", "-C", root, "remote", "get-url", "origin"],
                         capture_output=True, check=False, text=True, encoding="utf-8")
    url = out.stdout.strip() if out.returncode == 0 else root
    base = url.rstrip("/").rsplit("/", 1)[-1]
    return base.removesuffix(".git")


def check_backlog(root: str, hub: str) -> Iterator[Finding]:
    """Open language-AI work the owning repo's backlog forgot."""
    letter = LAI_LETTERS.get(repo_name(root))
    if letter is None:
        return
    path = os.path.join(root, BACKLOG)
    backlog = read_text(root, BACKLOG) if os.path.isfile(path) else ""
    for lai in open_lai_ids(read_text(hub, LANGUAGE_AI)):
        if lai.startswith(f"LAI-{letter}") and not names(lai, backlog):
            yield Finding("backlog-lai", BACKLOG, 1, f"open {lai} of the hub's {LANGUAGE_AI} is missing")


def grade(root: str, hub: str, duplicates_only: bool) -> list[Finding]:
    """Every finding; the hub's AGENTS.md is a rulebook, so only the duplicate check applies to it."""
    if not os.path.isfile(os.path.join(root, AGENTS)):
        raise gate_scope.ScopeError(f"no {AGENTS} at {root}")
    agents = read_text(root, AGENTS)
    findings = list(check_duplicates(agents))
    if duplicates_only:
        return findings
    findings += check_section5(root, agents)
    findings += check_section1(root, agents)
    findings += check_headings(agents, hub)
    findings += check_docs(root)
    findings += check_backlog(root, hub)
    return findings


def write_json(path: str, findings: list[Finding]) -> None:
    """The measurement quality-report.sh reads: totals.findings and the path:line rows."""
    checks: dict[str, int] = {}
    for finding in findings:
        checks[finding.check] = checks.get(finding.check, 0) + 1
    doc = {"schema_version": gate_scope.JSON_SCHEMA_VERSION, "gate": "agents-drift",
           "totals": {"findings": len(findings), "checks": checks},
           "items": [finding._asdict() for finding in findings]}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Hold AGENTS.md, the docs build list and BACKLOG.md to the tree.")
    ap.add_argument("--root", default=None, help="the repository to grade (default: this repo)")
    ap.add_argument("--json", default=None, metavar="PATH", help="also write the findings as JSON")
    args = ap.parse_args()
    try:
        root = gate_scope.resolve_root(args.root, HUB)
        findings = grade(root, HUB, gate_scope.is_hub(root, HUB))
    except (gate_scope.ScopeError, OSError) as exc:
        sys.stderr.write(f"agents drift: {exc}\n")
        return 2
    if args.json:
        write_json(args.json, findings)
    for finding in findings:
        print(f"{finding.path}:{finding.line}: {finding.check}: {finding.detail}")
    print(f"agents drift: {len(findings)} finding(s) in {root}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
