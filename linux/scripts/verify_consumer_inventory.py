#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Who actually calls this hub -- answered from clones, not from a local grep.

docs/consumer-inventory.md#the-consumer-inventory
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import NotRequired, TypeAlias, TypedDict, cast

from verify_consumer_quality_wiring import inspect as inspect_quality_wiring

HERE = Path(__file__).resolve().parent
HUB_ROOT = HERE.parent.parent
DEFAULT_INVENTORY = HUB_ROOT / ".github" / "consumers.json"
TOKEN_ENV = "CONSUMER_INVENTORY_TOKEN"

# Hits in these files or on these line heads are mentions, not calls; `.txt` is absent for CMakeLists.txt.
DOC_SUFFIXES = {".md", ".rst", ".log", ".patch", ".diff", ".po", ".allow"}
COMMENT_HEADS = ("#", "//", "/*", "*", "<!--", "::", ";", "rem ", "REM ")
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip",
                   ".gz", ".xz", ".7z", ".exe", ".dll", ".so", ".a", ".lib",
                   ".pyc", ".woff", ".woff2", ".ttf", ".otf", ".bin", ".ninja"}
MAX_FILE_BYTES = 4 * 1024 * 1024

# Suites name fixture paths that must not exist; matched as a path segment to cover every repo's layout.
FIXTURE_DIR = "tests"


def is_fixture(rel: str) -> bool:
    """True for a file inside a test-suite directory, in any repo's layout."""
    return FIXTURE_DIR in Path(rel).parts[:-1]

REACHED = "reached"
MENTIONED = "mentioned"

EXTERNAL = "reached by a consumer"
SELF_ONLY = "hub-internal only"
MENTIONED_ONLY = "mentioned, never reached"
UNREFERENCED = "named by nobody"
STATUS_ORDER = (UNREFERENCED, MENTIONED_ONLY, SELF_ONLY, EXTERNAL)

# Characters that end a path reference in prose or in a `uses:` value.
REF_TRAIL = "`'\").,;:)]}>*_"

# By-name reach (PowerShell modules, CMake include()) a path scan would miss; %s is the file's stem.
STEM_ALIASES = {
    "stem-word": r"(?<![\w.-])%s(?![\w.-])",
    "cmake-include": r"include\s*\(\s*%s\s*\)",
}


class Failure(Exception):
    """An integrity failure: the inventory cannot answer the question asked."""


class EntryPoint(TypedDict):
    kind: str
    needle: str
    root_file: bool
    alias_stem: str | None
    alias_re: re.Pattern[str] | None
    alias_name: str | None


class HubSpec(TypedDict):
    owner: str
    repo: str
    submodule_path: str


class ConsumerSpec(TypedDict):
    name: str
    clone_url: str
    ref: str
    self: bool


class EntryClass(TypedDict):
    kind: str
    glob: str
    needle: NotRequired[str]
    match: NotRequired[str]
    alias: NotRequired[str]
    requires: NotRequired[str]


class Inventory(TypedDict):
    hub: HubSpec
    consumers: list[ConsumerSpec]
    entry_point_classes: list[EntryClass]
    unconfirmed: NotRequired[list[object]]


class ScanContext(TypedDict):
    paths: set[str]
    qualifiers: tuple[str, str, str]
    basenames: set[str]
    is_self: bool


class VerdictRow(TypedDict):
    kind: str
    needle: str
    status: str
    reached_by: list[tuple[str, bool, str]]
    mentioned_by: list[tuple[str, str]]


HitBuckets: TypeAlias = dict[str, list[str]]
ScanHits: TypeAlias = dict[str, HitBuckets]
PerConsumer: TypeAlias = dict[str, tuple[bool, ScanHits]]
Dangling: TypeAlias = dict[str, list[str]]
QualityWiring: TypeAlias = dict[str, tuple[list[str], list[str]]]


def run_git(args: list[str]) -> bytes:
    proc = subprocess.run(args, capture_output=True, check=False)
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise Failure(f"{' '.join(args)} exited {proc.returncode}: {detail}")
    return proc.stdout


def load_inventory(path: Path) -> Inventory:
    """Parse and shape-check the inventory. A malformed list must not run."""
    if not path.is_file():
        raise Failure(f"inventory {path} does not exist")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise Failure(f"inventory {path} is not valid JSON: {exc}")
    for key in ("hub", "consumers", "entry_point_classes"):
        if not data.get(key):
            raise Failure(f"inventory {path}: '{key}' is missing or empty")
    for spec in data["consumers"]:
        missing = [k for k in ("name", "clone_url", "ref", "self") if k not in spec]
        if missing:
            raise Failure(f"inventory {path}: consumer {spec.get('name', '?')!r} lacks "
                          f"{', '.join(missing)}")
    if not [c for c in data["consumers"] if c["self"]]:
        raise Failure(f"inventory {path}: no consumer is marked self:true, so nothing "
                      "can tell hub-internal use from an external caller")
    return cast(Inventory, data)


def entry_forms(spec: EntryClass, path: Path, rel: str) -> EntryPoint:
    """One entry point: its path needle plus any by-name form its class declares."""
    needle = rel.rsplit("/", 1)[0] if spec.get("needle") == "dir" else rel
    entry: EntryPoint = {"kind": spec["kind"], "needle": needle,
                         "root_file": spec.get("match") == "root-file", "alias_stem": None,
                         "alias_re": None, "alias_name": None}
    alias = spec.get("alias")
    if not alias:
        return entry
    if alias not in STEM_ALIASES:
        raise Failure(f"entry point class {spec['kind']!r} declares alias {alias!r}; "
                      f"known: {', '.join(sorted(STEM_ALIASES))}")
    entry["alias_stem"] = path.stem
    entry["alias_re"] = re.compile(STEM_ALIASES[alias] % re.escape(path.stem))
    entry["alias_name"] = path.name
    return entry


def discover_entry_points(hub_root: Path, classes: list[EntryClass]) -> list[EntryPoint]:
    """Expand each declared class into the concrete entry points of the hub."""
    found: dict[str, EntryPoint] = {}
    for spec in classes:
        kind, glob = spec["kind"], spec["glob"]
        hits = sorted(p for p in hub_root.glob(glob) if p.is_file())
        if not hits:
            raise Failure(f"entry point class {kind!r} matches nothing under {glob} -- a class "
                          "that expands to zero would silently narrow the report")
        required = spec.get("requires")
        for path in hits:
            rel = path.relative_to(hub_root).as_posix()
            if required and required not in path.read_text(encoding="utf-8", errors="replace"):
                continue
            entry = entry_forms(spec, path, rel)
            found.setdefault(entry["needle"], entry)
    if not found:
        raise Failure("no entry points discovered -- wrong hub root?")
    return sorted(found.values(), key=lambda e: (e["kind"], e["needle"]))


def tracked_files(root: Path, name: str) -> list[str]:
    """The repository's tracked files. Untracked build output is not evidence."""
    if not (root / ".git").exists():
        raise Failure(f"{name}: {root} is not a git checkout -- refusing to grade a "
                      "partial tree")
    raw = run_git(["git", "-C", str(root), "ls-files", "-z"])
    files = [p for p in raw.decode("utf-8", "replace").split("\0") if p]
    if not files:
        raise Failure(f"{name}: git ls-files listed nothing under {root}")
    return files


def readable(root: Path, rel: str) -> str | None:
    """The file as text, or None when it is binary, huge or unreadable."""
    if Path(rel).suffix.lower() in BINARY_SUFFIXES:
        return None
    try:
        path = root / rel
        if path.stat().st_size > MAX_FILE_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if b"\0" in data[:4096]:
        return None
    return data.decode("utf-8", "replace")


def line_at(text: str, pos: int) -> tuple[int, str]:
    start = text.rfind("\n", 0, pos) + 1
    end = text.find("\n", pos)
    return text.count("\n", 0, pos) + 1, text[start:end if end >= 0 else len(text)]


def use_kind(rel: str, line: str) -> str:
    """REACHED when the hit sits where something executes it, else MENTIONED."""
    if Path(rel).suffix.lower() in DOC_SUFFIXES:
        return MENTIONED
    stripped = line.strip()
    if any(stripped.startswith(head) for head in COMMENT_HEADS):
        return MENTIONED
    return REACHED


def entry_hits(text: str, entry: EntryPoint) -> list[tuple[int, str]]:
    """(offset, matched text) per occurrence; str.find per entry is far cheaper than one giant alternation."""
    out = []
    needle = entry["needle"]
    pos = text.find(needle)
    while pos >= 0:
        out.append((pos, needle))
        pos = text.find(needle, pos + len(needle))
    stem = entry["alias_stem"]
    alias_re = entry["alias_re"]
    if stem and alias_re is not None and stem in text:
        out += [(m.start(), m.group(0)) for m in alias_re.finditer(text)]
    return out


def path_universe(files: list[str]) -> set[str]:
    """Every tracked path AND every directory on the way to one."""
    out = set(files)
    for rel in files:
        parts = rel.split("/")
        for i in range(1, len(parts)):
            out.add("/".join(parts[:i]))
    return out


def is_hub_reference(text: str, start: int, matched: str,
                     entry: EntryPoint, ctx: ScanContext) -> bool:
    """Does this hit mean the hub's copy? In a consumer only when qualified or the consumer has no such file."""
    if entry["root_file"]:
        before = text[max(0, start - 64):start]
        suffix = text[start + len(matched):start + len(matched) + 1]
        if suffix and (suffix.isalnum() or suffix in "_.-"):
            return False
        if any(before.endswith((q, q.replace("/", "\\")))
               for q in ctx["qualifiers"]):
            return True
        return ctx["is_self"] and before.endswith(("${REPO_ROOT}/", "${HUB_ROOT}/"))
    if ctx["is_self"]:
        return True
    before = text[max(0, start - 64):start]
    if any(before.endswith(q) for q in ctx["qualifiers"]):
        return True
    if matched != entry["needle"]:
        return entry["alias_name"] not in ctx["basenames"]
    return entry["needle"] not in ctx["paths"]


def scan_context(files: list[str], qualifiers: tuple[str, str, str],
                 is_self: bool) -> ScanContext:
    return {"paths": path_universe(files), "qualifiers": qualifiers,
            "basenames": {f.rsplit("/", 1)[-1] for f in files}, "is_self": is_self}


def scan_file(rel: str, text: str, entries: list[EntryPoint],
              ctx: ScanContext, hits: ScanHits) -> None:
    for entry in entries:
        needle = entry["needle"]
        if rel == needle or rel.startswith(needle + "/"):
            continue  # a file naming itself is not a caller
        for start, matched in entry_hits(text, entry):
            if not is_hub_reference(text, start, matched, entry, ctx):
                continue
            lineno, line = line_at(text, start)
            bucket = hits.setdefault(needle, {REACHED: [], MENTIONED: []})
            bucket[use_kind(rel, line)].append(f"{rel}:{lineno}")


def scan_consumer(root: Path, files: list[str], entries: list[EntryPoint],
                  ctx: ScanContext) -> ScanHits:
    """needle -> {reached: [...], mentioned: [...]} of '<file>:<line>' strings."""
    hits: ScanHits = {}
    for rel in files:
        text = readable(root, rel)
        if text is not None:
            scan_file(rel, text, entries, ctx, hits)
    return hits


def inside_url(text: str, start: int) -> bool:
    """Is this hit inside an http(s) URL, which looks like a repository path but is not one?"""
    before = text[max(0, start - 96):start]
    cut = before.rfind("://")
    return cut >= 0 and not re.search(r"[\s'\"`<>]", before[cut:])


def submodule_prefixes(hub_root: Path) -> tuple[str, ...]:
    """Submodule paths from .gitmodules, whose worktrees a fresh clone leaves empty and which are not graded."""
    gitmodules = hub_root / ".gitmodules"
    prefixes = []
    if gitmodules.is_file():
        for line in gitmodules.read_text(encoding="utf-8", errors="replace").splitlines():
            found = re.match(r"\s*path\s*=\s*(.+?)\s*$", line)
            if found:
                prefixes.append(found.group(1).rstrip("/") + "/")
    return tuple(sorted(prefixes))


def dangling_refs(root: Path, files: list[str], hub_root: Path,
                  ref_re: re.Pattern[str], vendored: tuple[str, ...]) -> list[str]:
    """Executable (reached, not prose) references to hub paths that do not exist."""
    found = []
    for rel in files:
        if is_fixture(rel):
            continue
        text = readable(root, rel)
        if text is None:
            continue
        for match in ref_re.finditer(text):
            body = match.group(1)
            # After a slash-spelled qualifier a backslash ends the path, e.g. a printf `\n` escape.
            if "\\" not in text[match.start(0):match.start(1)]:
                body = body.split("\\", 1)[0]
            target = body.split("@", 1)[0].rstrip(REF_TRAIL)
            # Checked against a POSIX checkout, so normalise to slashes.
            target = target.replace("\\", "/").rstrip("/")
            if (not target or target.startswith(vendored)
                    or (hub_root / target).exists() or inside_url(text, match.start())):
                continue
            lineno, line = line_at(text, match.start())
            if use_kind(rel, line) == REACHED:
                found.append(f"{rel}:{lineno} -> {target}")
    return sorted(set(found))


# Modules are reached by name (Import-BuildModule, Resolve-BuildModule -Name, Join-Path), so a dangling one fails only at runtime.
MODULE_DIR = "windows/scripts/modules"
MODULE_REFS = (
    re.compile(r"Import-BuildModule\s*(?:-Name\s*)?@?\s*\(?([^)\n]*)\)?"),
    re.compile(r"Resolve-BuildModule(?:Path)?\s+-Name\s+([^\n]*)"),
    re.compile(r"Join-Path\s+\S+\s+('[A-Za-z0-9_.]+\.psm1')"),
)
MODULE_NAME = re.compile(r"['{q}]([A-Za-z0-9_.]+?)(?:\.psm1)?['{q}]".replace("{q}", chr(34)))


def dangling_modules(root: Path, files: list[str], hub_root: Path) -> list[str]:
    """Module NAMES a consumer imports that the hub no longer ships."""
    have = {p.stem for p in (hub_root / MODULE_DIR).glob("*.psm1")}
    # Resolve-BuildModule falls back to the consumer's own modules; fixture modules do not count.
    own = {Path(rel).stem for rel in files if rel.endswith(".psm1") and not is_fixture(rel)}
    found = []
    for rel in files:
        if is_fixture(rel) or not rel.endswith((".ps1", ".psm1")):
            continue
        text = readable(root, rel)
        if text is None:
            continue
        for pattern in MODULE_REFS:
            for match in pattern.finditer(text):
                lineno, line = line_at(text, match.start())
                if use_kind(rel, line) != REACHED:
                    continue
                for name in MODULE_NAME.findall(match.group(1)):
                    # Only a name the hub is expected to carry can dangle.
                    if name in have or name in own or not name.startswith("Windows"):
                        continue
                    found.append(f"{rel}:{lineno} -> {name}.psm1 (module name)")
    return sorted(set(found))


def clone_url(spec: ConsumerSpec) -> str:
    """The URL to clone, with a token spliced in when one is provided."""
    url = spec["clone_url"]
    token = os.environ.get(TOKEN_ENV, "").strip()
    if token and url.startswith("https://github.com/"):
        return url.replace("https://", f"https://x-access-token:{token}@", 1)
    return url


def obtain(spec: ConsumerSpec, local: dict[str, Path], work: Path,
           offline: bool) -> Path:
    """A checkout of this consumer, or a hard failure. Never a skip."""
    name = spec["name"]
    if name in local:
        root = local[name]
        if not root.is_dir():
            raise Failure(f"{name}: --local path {root} does not exist")
        return root
    if offline:
        raise Failure(f"{name}: --offline was given and no --local path was supplied "
                      "for it. Skipping it would make the inventory lie.")
    dest = work / name
    print(f"   cloning {name} ({spec['clone_url']} @ {spec['ref']})")
    run_git(["git", "clone", "--depth", "1", "--single-branch",
             "--branch", spec["ref"], clone_url(spec), str(dest)])
    return dest


def grade(entry: EntryPoint, per_consumer: PerConsumer) -> VerdictRow:
    """Fold one entry point's hits across all consumers into a verdict row."""
    reached_by: list[tuple[str, bool, str]] = []
    mentioned_by: list[tuple[str, str]] = []
    for name in per_consumer:
        is_self, hits = per_consumer[name]
        bucket = hits.get(entry["needle"])
        if not bucket:
            continue
        if bucket[REACHED]:
            reached_by.append((name, is_self, bucket[REACHED][0]))
        elif bucket[MENTIONED]:
            mentioned_by.append((name, bucket[MENTIONED][0]))
    external = [r for r in reached_by if not r[1]]
    status = UNREFERENCED
    if external:
        status = EXTERNAL
    elif reached_by:
        status = SELF_ONLY
    elif mentioned_by:
        status = MENTIONED_ONLY
    return {"kind": entry["kind"], "needle": entry["needle"], "status": status,
            "reached_by": reached_by, "mentioned_by": mentioned_by}


def table(rows: list[VerdictRow], cell: Callable[[VerdictRow], str]) -> list[str]:
    out = ["", "| kind | entry point | evidence |", "| --- | --- | --- |"]
    out += [f"| {r['kind']} | `{r['needle']}` | {cell(r)} |" for r in rows]
    return out


def section(rows: list[VerdictRow], status: str, heading: str, blurb: str,
            cell: Callable[[VerdictRow], str]) -> list[str]:
    picked = [r for r in rows if r["status"] == status]
    out = ["", f"## {heading} -- {len(picked)}", "", blurb]
    if not picked:
        return out + ["", "_None._"]
    return out + table(picked, cell)


def evidence_reached(row: VerdictRow) -> str:
    return ", ".join(f"{n} (`{w}`)" for n, _s, w in row["reached_by"]) or "--"


def evidence_mentioned(row: VerdictRow) -> str:
    return ", ".join(f"{n} (`{w}`)" for n, w in row["mentioned_by"]) or "--"


def render_dangling(dangling: Dangling) -> list[str]:
    blurb = ("A consumer names a hub path that does not exist. Either the path"
             " moved and the consumer was not updated, or the reference was"
             " always wrong. These fail the run.")
    total = sum(len(v) for v in dangling.values())
    out = ["", f"## Dangling references -- {total}", "", blurb]
    if not any(dangling.values()):
        return out + ["", "_None._"]
    for name in sorted(dangling):
        if dangling[name]:
            out += ["", f"**{name}**"] + [f"- `{r}`" for r in dangling[name]]
    return out


def render_quality_wiring(quality: QualityWiring,
                          consumers: list[ConsumerSpec]) -> list[str]:
    out = ["", "## CI quality wiring", "",
           ("Every detected lint call must keep its ratchets enabled and its failure fatal. "
            "A consumer with no lint call is reported only: removal of every lint call "
            "is outside this gate."), ""]
    providers = {item["name"] for item in consumers if item["self"]}
    for name, (witnesses, failures) in quality.items():
        if name in providers:
            out.append(f"- **{name}:** hub provider; consumer wiring is out of scope")
            continue
        verdict = "FAIL" if failures else ("OK" if witnesses else "ADVISORY")
        out.append(f"- **{name}:** {verdict}")
        out.extend(f"  - {item}" for item in witnesses + failures)
        if not witnesses and not failures:
            out.append("  - No tracked CI lint call was found.")
    return out


def render_report(rows: list[VerdictRow], consumers: list[ConsumerSpec],
                  dangling: Dangling, quality: QualityWiring | None = None) -> str:
    counts = {s: len([r for r in rows if r["status"] == s]) for s in STATUS_ORDER}
    names = ", ".join(c["name"] + (" (hub)" if c["self"] else "")
                      for c in consumers)
    out = ["# ANTfrastructure consumer inventory", "",
           f"Consumers scanned: {len(consumers)} -- {names}", "",
           f"Entry points graded: {len(rows)}", "",
           "| verdict | count |", "| --- | --- |"]
    out += [f"| {s} | {counts[s]} |" for s in STATUS_ORDER]
    out += section(rows, UNREFERENCED, "Named by nobody",
                   "No repository in the inventory mentions these at all. This is the "
                   "candidate list for deletion -- and it is only as good as the "
                   "`consumers` list, so resolve the `unconfirmed` rows first.",
                   lambda r: "--")
    out += section(rows, MENTIONED_ONLY, "Mentioned, never reached",
                   "Named in prose or in a comment and run by nothing. Deleting one "
                   "breaks a document, not a build.", evidence_mentioned)
    out += section(rows, SELF_ONLY, "Hub-internal only",
                   "Reached from this repository and no other. Refactorable without a "
                   "consumer bump; not part of the published surface.", evidence_reached)
    out += section(rows, EXTERNAL, "Reached by a consumer",
                   "Load-bearing outside this repository. Changing one of these is a "
                   "breaking change for the named repos.", evidence_reached)
    out += render_dangling(dangling)
    if quality is not None:
        out += render_quality_wiring(quality, consumers)
    return "\n".join(out) + "\n"


def parse_local(values: list[str] | None, root: str | None,
                names: list[str]) -> dict[str, Path]:
    local = {}
    if root:
        for name in names:
            candidate = Path(root) / name
            if candidate.is_dir():
                local[name] = candidate.resolve()
    for item in values or []:
        if "=" not in item:
            raise Failure(f"--local expects NAME=PATH, got {item!r}")
        name, _, path = item.partition("=")
        local[name] = Path(path).resolve()
    unknown = sorted(set(local) - set(names))
    if unknown:
        raise Failure(f"--local names {', '.join(unknown)}, which the inventory does not list")
    return local


def build_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--inventory", default=str(DEFAULT_INVENTORY))
    ap.add_argument("--hub-root", default=str(HUB_ROOT))
    ap.add_argument("--local", action="append", metavar="NAME=PATH",
                    help="use an existing checkout instead of cloning")
    ap.add_argument("--local-root", metavar="DIR",
                    help="directory holding checkouts named after the consumers")
    ap.add_argument("--offline", action="store_true",
                    help="never clone; a consumer without a local path FAILS")
    ap.add_argument("--report", metavar="PATH", help="write the Markdown report here")
    ap.add_argument("--reuse-report", metavar="PATH",
                    help="also measure Bash/PowerShell reuse across active owned nonfork repos")
    ap.add_argument("--owned-list", metavar="PATH",
                    help="filtered GitHub API identities, required with --reuse-report")
    return ap.parse_args()


def qualifier_set(hub: HubSpec) -> tuple[str, str, str]:
    """The prefixes that make a bare hub path unambiguously the hub's."""
    return (hub["submodule_path"] + "/",
            f"{hub['owner']}/{hub['repo']}/",
            hub["repo"] + "/")


def ref_qualifiers(hub: HubSpec) -> list[str]:
    r"""The two path qualifiers in both separator spellings, since PowerShell callers write backslashes."""
    out = []
    for qualifier in qualifier_set(hub)[:2]:
        out.append(qualifier)
        out.append(qualifier.replace("/", "\\"))
    return out


def collect(data: Inventory, args: argparse.Namespace, hub_root: Path,
            entries: list[EntryPoint], work: Path) -> tuple[
                PerConsumer, Dangling, QualityWiring, dict[str, Path]]:
    """Obtain every consumer and scan paths and CI quality calls."""
    names = [c["name"] for c in data["consumers"]]
    local = parse_local(args.local, args.local_root, names)
    qualifiers = qualifier_set(data["hub"])
    vendored = submodule_prefixes(hub_root)
    # The class includes the backslash, or a Windows path would stop at its first segment.
    qualifiers_re = "|".join(re.escape(q) for q in ref_qualifiers(data["hub"]))
    ref_re = re.compile(rf"(?:{qualifiers_re})([A-Za-z0-9_./@\\-]+)")
    per_consumer: PerConsumer = {}
    dangling: Dangling = {}
    quality: QualityWiring = {}
    checkouts: dict[str, Path] = {}
    for spec in data["consumers"]:
        root = obtain(spec, local, work, args.offline)
        checkouts[spec["name"]] = root
        files = tracked_files(root, spec["name"])
        ctx = scan_context(files, qualifiers, spec["self"])
        hits = scan_consumer(root, files, entries, ctx)
        per_consumer[spec["name"]] = (spec["self"], hits)
        quality[spec["name"]] = (([], []) if spec["self"] else
                                 inspect_quality_wiring(root, files))
        dangling[spec["name"]] = sorted(set(
            dangling_refs(root, files, hub_root, ref_re, vendored)
            + dangling_modules(root, files, hub_root)))
        print(f"   {spec['name']:<22} {len(files):5d} tracked files, "
              f"{len(hits):3d} entry points touched, "
              f"{len(dangling[spec['name']])} dangling")
    return per_consumer, dangling, quality, checkouts


def report_reuse(args: argparse.Namespace, data: Inventory,
                 checkouts: dict[str, Path], hub_root: Path) -> None:
    if not args.reuse_report:
        return
    if not args.owned_list:
        raise Failure("--reuse-report requires --owned-list from the GitHub API")
    command = [sys.executable, str(HUB_ROOT / "docs/scripts/verify_fleet_reuse.py"),
               "--owned-list", args.owned_list, "--hub", str(hub_root),
               "--owner", data["hub"]["owner"], "--hub-name", data["hub"]["repo"],
               "--report", args.reuse_report]
    for name, path in checkouts.items():
        command.extend(("--checkout", f"{name}={path}"))
    result = subprocess.run(command, capture_output=True, check=False,
                            text=True, encoding="utf-8")
    if result.returncode:
        raise Failure(f"fleet reuse scan exited {result.returncode}: "
                      f"{(result.stdout + result.stderr).strip()}")
    print(f"   fleet reuse report written to {args.reuse_report}")


def report_out(args: argparse.Namespace, text: str) -> None:
    if not args.report:
        return
    dest = Path(args.report)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
    print(f"   report written to {dest}")


def print_dangling(dangling: Dangling) -> int:
    for name in sorted(dangling):
        for ref in dangling[name]:
            sys.stderr.write(f"FAIL: {name} names a hub path that does not exist: {ref}\n")
    return sum(len(v) for v in dangling.values())


def main() -> int:
    args = build_args()
    hub_root = Path(args.hub_root).resolve()
    try:
        data = load_inventory(Path(args.inventory).resolve())
        entries = discover_entry_points(hub_root, data["entry_point_classes"])
        print(f"== consumer inventory: {len(entries)} entry points, "
              f"{len(data['consumers'])} consumers ==")
        with tempfile.TemporaryDirectory(prefix="consumer-inventory-") as tmp:
            per_consumer, dangling, quality, checkouts = collect(
                data, args, hub_root, entries, Path(tmp))
            rows = [grade(e, per_consumer) for e in entries]
            report_out(args, render_report(rows, data["consumers"], dangling, quality))
            report_reuse(args, data, checkouts, hub_root)
    except Failure as exc:
        sys.stderr.write(f"FAIL: {exc}\n")
        return 1
    for status in STATUS_ORDER:
        print(f"   {status:<26} {len([r for r in rows if r['status'] == status])}")
    broken_paths = print_dangling(dangling)
    broken_quality = sum(len(failures) for _witnesses, failures in quality.values())
    for name, (_witnesses, failures) in quality.items():
        for failure in failures:
            sys.stderr.write(f"FAIL: {name} CI quality wiring: {failure}\n")
    if broken_paths or broken_quality:
        sys.stderr.write(f"CONSUMER INVENTORY FAILED ({broken_paths} dangling references, "
                         f"{broken_quality} CI quality calls)\n")
        return 1
    print(f"CONSUMER INVENTORY OK ({len(data.get('unconfirmed', []))} "
          "unconfirmed candidate repo(s) still to resolve)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
