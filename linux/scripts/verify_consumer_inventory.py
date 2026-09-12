#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Who actually calls this hub -- answered from clones, not from a local grep.

Every dead-code decision here has rested on grepping the repos that happen to be
checked out on one machine. That is how three deletions had to be restored: the
caller existed, in a repo nobody had cloned. This reads the declared list in
.github/consumers.json, obtains every listed repository, and grades each hub
entry point into one of four states -- reached by an external consumer, reached
only by the hub itself, merely mentioned in prose, or named by nobody.

Two rules keep the answer honest. A consumer that cannot be obtained is a hard
failure, never a skip: a silent skip turns "no caller found" into a lie with the
same shape as the truth. And a mention is not a call -- a hub script named in a
consumer's CHANGELOG keeps nothing alive, so prose and comment hits are counted
apart from executable ones.

Usage:
    python3 linux/scripts/verify_consumer_inventory.py --report out/consumers.md
    python3 linux/scripts/verify_consumer_inventory.py --offline
        --local-root /d/GitHub --report out/consumers.md

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
from pathlib import Path

HERE = Path(__file__).resolve().parent
HUB_ROOT = HERE.parent.parent
DEFAULT_INVENTORY = HUB_ROOT / ".github" / "consumers.json"
TOKEN_ENV = "CONSUMER_INVENTORY_TOKEN"

# A hit in one of these files, or on a line that opens with one of these, is a
# MENTION: prose, a changelog, or an allow-file row -- none of which runs
# anything. `.txt` is deliberately absent: CMakeLists.txt ends in it.
DOC_SUFFIXES = {".md", ".rst", ".log", ".patch", ".diff", ".po", ".allow"}
COMMENT_HEADS = ("#", "//", "/*", "*", "<!--", "::", ";", "rem ", "REM ")
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip",
                   ".gz", ".xz", ".7z", ".exe", ".dll", ".so", ".a", ".lib",
                   ".pyc", ".woff", ".woff2", ".ttf", ".otf", ".bin", ".ninja"}
MAX_FILE_BYTES = 4 * 1024 * 1024

# Test suites build FAKE consumer trees and name fixture paths that must not
# exist -- a dangling hit there is the fixture doing its job, not a stale
# reference. A real call in a test fails the suite itself, which is the better
# gate for it.
FIXTURE_PREFIXES = ("linux/scripts/tests/", "windows/scripts/tests/")

REACHED = "reached"
MENTIONED = "mentioned"

EXTERNAL = "reached by a consumer"
SELF_ONLY = "hub-internal only"
MENTIONED_ONLY = "mentioned, never reached"
UNREFERENCED = "named by nobody"
STATUS_ORDER = (UNREFERENCED, MENTIONED_ONLY, SELF_ONLY, EXTERNAL)

# Characters that end a path reference in prose or in a `uses:` value.
REF_TRAIL = "`'\").,;:)]}>*_"

# Not every entry point is reached by its path. A PowerShell module is asked for
# by NAME (Resolve-BuildModulePath -Name 'WindowsBuild.Common') and a CMake module
# by include(Sanitizers), so a path-only scan would report both as dead. A class
# declares the extra shape it is reached through; %s is the file's stem.
STEM_ALIASES = {
    "stem-word": r"(?<![\w.-])%s(?![\w.-])",
    "cmake-include": r"include\s*\(\s*%s\s*\)",
}


class Failure(Exception):
    """An integrity failure: the inventory cannot answer the question asked."""


def run_git(args):
    proc = subprocess.run(args, capture_output=True, check=False)
    if proc.returncode != 0:
        raise Failure("%s exited %d: %s"
                      % (" ".join(args), proc.returncode,
                         proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout


def load_inventory(path):
    """Parse and shape-check the inventory. A malformed list must not run."""
    if not path.is_file():
        raise Failure("inventory %s does not exist" % path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise Failure("inventory %s is not valid JSON: %s" % (path, exc))
    for key in ("hub", "consumers", "entry_point_classes"):
        if not data.get(key):
            raise Failure("inventory %s: '%s' is missing or empty" % (path, key))
    for spec in data["consumers"]:
        missing = [k for k in ("name", "clone_url", "ref", "self") if k not in spec]
        if missing:
            raise Failure("inventory %s: consumer %r lacks %s"
                          % (path, spec.get("name", "?"), ", ".join(missing)))
    if not [c for c in data["consumers"] if c["self"]]:
        raise Failure("inventory %s: no consumer is marked self:true, so nothing "
                      "can tell hub-internal use from an external caller" % path)
    return data


def entry_forms(spec, path, rel):
    """One entry point: its path needle plus, if the class declares one, the
    by-name form it is really reached through."""
    needle = rel.rsplit("/", 1)[0] if spec.get("needle") == "dir" else rel
    entry = {"kind": spec["kind"], "needle": needle, "alias_stem": None,
             "alias_re": None, "alias_name": None}
    alias = spec.get("alias")
    if not alias:
        return entry
    if alias not in STEM_ALIASES:
        raise Failure("entry point class %r declares alias %r; known: %s"
                      % (spec["kind"], alias, ", ".join(sorted(STEM_ALIASES))))
    entry["alias_stem"] = path.stem
    entry["alias_re"] = re.compile(STEM_ALIASES[alias] % re.escape(path.stem))
    entry["alias_name"] = path.name
    return entry


def discover_entry_points(hub_root, classes):
    """Expand each declared class into the concrete entry points of the hub."""
    found = {}
    for spec in classes:
        kind, glob = spec["kind"], spec["glob"]
        hits = sorted(p for p in hub_root.glob(glob) if p.is_file())
        if not hits:
            raise Failure("entry point class %r matches nothing under %s -- a class "
                          "that expands to zero would silently narrow the report"
                          % (kind, glob))
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


def tracked_files(root, name):
    """The repository's tracked files. Untracked build output is not evidence."""
    if not (root / ".git").exists():
        raise Failure("%s: %s is not a git checkout -- refusing to grade a "
                      "partial tree" % (name, root))
    raw = run_git(["git", "-C", str(root), "ls-files", "-z"])
    files = [p for p in raw.decode("utf-8", "replace").split("\0") if p]
    if not files:
        raise Failure("%s: git ls-files listed nothing under %s" % (name, root))
    return files


def readable(root, rel):
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


def line_at(text, pos):
    start = text.rfind("\n", 0, pos) + 1
    end = text.find("\n", pos)
    return text.count("\n", 0, pos) + 1, text[start:end if end >= 0 else len(text)]


def use_kind(rel, line):
    """REACHED when the hit sits where something executes it, else MENTIONED."""
    if Path(rel).suffix.lower() in DOC_SUFFIXES:
        return MENTIONED
    stripped = line.strip()
    if any(stripped.startswith(head) for head in COMMENT_HEADS):
        return MENTIONED
    return REACHED


def entry_hits(text, entry):
    """(offset, matched text) for every occurrence of one entry point in a file.

    str.find over the path form rather than one giant alternation: 149 literal
    scans of a file are a fraction of the cost of one 149-branch regex, and this
    gate walks five whole repositories.
    """
    out = []
    needle = entry["needle"]
    pos = text.find(needle)
    while pos >= 0:
        out.append((pos, needle))
        pos = text.find(needle, pos + len(needle))
    stem = entry["alias_stem"]
    if stem and stem in text:
        out += [(m.start(), m.group(0)) for m in entry["alias_re"].finditer(text)]
    return out


def path_universe(files):
    """Every tracked path AND every directory on the way to one."""
    out = set(files)
    for rel in files:
        parts = rel.split("/")
        for i in range(1, len(parts)):
            out.add("/".join(parts[:i]))
    return out


def is_hub_reference(text, start, matched, entry, ctx):
    """Does this hit mean the HUB's copy of that entry point?

    In the hub itself every hit does. In a consumer the reference may be to its
    own file of the same path or module name, so it counts only when qualified
    (third_party/ANTfrastructure/..., owner/ANTfrastructure/...) or when the consumer
    owns no such path -- and, for a by-name alias, no file of that basename.
    """
    if ctx["is_self"]:
        return True
    before = text[max(0, start - 64):start]
    if any(before.endswith(q) for q in ctx["qualifiers"]):
        return True
    if matched != entry["needle"]:
        return entry["alias_name"] not in ctx["basenames"]
    return entry["needle"] not in ctx["paths"]


def scan_context(files, qualifiers, is_self):
    return {"paths": path_universe(files), "qualifiers": qualifiers,
            "basenames": {f.rsplit("/", 1)[-1] for f in files}, "is_self": is_self}


def scan_file(rel, text, entries, ctx, hits):
    for entry in entries:
        needle = entry["needle"]
        if rel == needle or rel.startswith(needle + "/"):
            continue  # a file naming itself is not a caller
        for start, matched in entry_hits(text, entry):
            if not is_hub_reference(text, start, matched, entry, ctx):
                continue
            lineno, line = line_at(text, start)
            bucket = hits.setdefault(needle, {REACHED: [], MENTIONED: []})
            bucket[use_kind(rel, line)].append("%s:%d" % (rel, lineno))


def scan_consumer(root, files, entries, ctx):
    """needle -> {reached: [...], mentioned: [...]} of '<file>:<line>' strings."""
    hits = {}
    for rel in files:
        text = readable(root, rel)
        if text is not None:
            scan_file(rel, text, entries, ctx, hits)
    return hits


def inside_url(text, start):
    """Is this hit part of an http(s) URL rather than a path in a tree?

    github.com/<owner>/ANTfrastructure/actions/... and .../blob/main/... look
    exactly like repository paths and are not ones.
    """
    before = text[max(0, start - 96):start]
    cut = before.rfind("://")
    return cut >= 0 and not re.search(r"[\s'\"`<>]", before[cut:])


def dangling_refs(root, files, hub_root, ref_re):
    """Executable references to hub paths that do not exist -- a caller pointing
    at nothing is the other half of the question this inventory asks.

    Only REACHED positions count. A comment recording that a path was removed,
    or naming one as an example, is prose about a hub path, not a broken call.
    """
    found = []
    for rel in files:
        if rel.startswith(FIXTURE_PREFIXES):
            continue
        text = readable(root, rel)
        if text is None:
            continue
        for match in ref_re.finditer(text):
            target = match.group(1).split("@", 1)[0].rstrip(REF_TRAIL).rstrip("/")
            if not target or (hub_root / target).exists() or inside_url(text, match.start()):
                continue
            lineno, line = line_at(text, match.start())
            if use_kind(rel, line) == REACHED:
                found.append("%s:%d -> %s" % (rel, lineno, target))
    return sorted(set(found))


def clone_url(spec):
    """The URL to clone, with a token spliced in when one is provided."""
    url = spec["clone_url"]
    token = os.environ.get(TOKEN_ENV, "").strip()
    if token and url.startswith("https://github.com/"):
        return url.replace("https://", "https://x-access-token:%s@" % token, 1)
    return url


def obtain(spec, local, work, offline):
    """A checkout of this consumer, or a hard failure. Never a skip."""
    name = spec["name"]
    if name in local:
        root = local[name]
        if not root.is_dir():
            raise Failure("%s: --local path %s does not exist" % (name, root))
        return root
    if offline:
        raise Failure("%s: --offline was given and no --local path was supplied "
                      "for it. Skipping it would make the inventory lie." % name)
    dest = work / name
    print("   cloning %s (%s @ %s)" % (name, spec["clone_url"], spec["ref"]))
    run_git(["git", "clone", "--depth", "1", "--single-branch",
             "--branch", spec["ref"], clone_url(spec), str(dest)])
    return dest


def grade(entry, per_consumer):
    """Fold one entry point's hits across all consumers into a verdict row."""
    reached_by, mentioned_by = [], []
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


def table(rows, cell):
    out = ["", "| kind | entry point | evidence |", "| --- | --- | --- |"]
    out += ["| %s | `%s` | %s |" % (r["kind"], r["needle"], cell(r)) for r in rows]
    return out


def section(rows, status, heading, blurb, cell):
    picked = [r for r in rows if r["status"] == status]
    out = ["", "## %s -- %d" % (heading, len(picked)), "", blurb]
    if not picked:
        return out + ["", "_None._"]
    return out + table(picked, cell)


def evidence_reached(row):
    return ", ".join("%s (`%s`)" % (n, w) for n, _s, w in row["reached_by"]) or "--"


def evidence_mentioned(row):
    return ", ".join("%s (`%s`)" % (n, w) for n, w in row["mentioned_by"]) or "--"


def render_dangling(dangling):
    blurb = ("A consumer names a hub path that does not exist. Either the path"
             " moved and the consumer was not updated, or the reference was"
             " always wrong. These fail the run.")
    total = sum(len(v) for v in dangling.values())
    out = ["", "## Dangling references -- %d" % total, "", blurb]
    if not any(dangling.values()):
        return out + ["", "_None._"]
    for name in sorted(dangling):
        if dangling[name]:
            out += ["", "**%s**" % name] + ["- `%s`" % r for r in dangling[name]]
    return out


def render_report(rows, consumers, dangling):
    counts = {s: len([r for r in rows if r["status"] == s]) for s in STATUS_ORDER}
    names = ", ".join("%s%s" % (c["name"], " (hub)" if c["self"] else "")
                      for c in consumers)
    out = ["# ANTfrastructure consumer inventory", "",
           "Consumers scanned: %d -- %s" % (len(consumers), names), "",
           "Entry points graded: %d" % len(rows), "",
           "| verdict | count |", "| --- | --- |"]
    out += ["| %s | %d |" % (s, counts[s]) for s in STATUS_ORDER]
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
    return "\n".join(out) + "\n"


def parse_local(values, root, names):
    local = {}
    if root:
        for name in names:
            candidate = Path(root) / name
            if candidate.is_dir():
                local[name] = candidate.resolve()
    for item in values or []:
        if "=" not in item:
            raise Failure("--local expects NAME=PATH, got %r" % item)
        name, _, path = item.partition("=")
        local[name] = Path(path).resolve()
    unknown = sorted(set(local) - set(names))
    if unknown:
        raise Failure("--local names %s, which the inventory does not list"
                      % ", ".join(unknown))
    return local


def build_args():
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
    return ap.parse_args()


def qualifier_set(hub):
    """The prefixes that make a bare hub path unambiguously the hub's."""
    return (hub["submodule_path"] + "/",
            "%s/%s/" % (hub["owner"], hub["repo"]),
            hub["repo"] + "/")


def collect(data, args, hub_root, entries, work):
    """Obtain every consumer and scan it. Returns (per-consumer hits, dangling)."""
    names = [c["name"] for c in data["consumers"]]
    local = parse_local(args.local, args.local_root, names)
    qualifiers = qualifier_set(data["hub"])
    ref_re = re.compile("(?:%s)([A-Za-z0-9_./@-]+)"
                        % "|".join(re.escape(q) for q in qualifiers[:2]))
    per_consumer = {}
    dangling = {}
    for spec in data["consumers"]:
        root = obtain(spec, local, work, args.offline)
        files = tracked_files(root, spec["name"])
        ctx = scan_context(files, qualifiers, spec["self"])
        hits = scan_consumer(root, files, entries, ctx)
        per_consumer[spec["name"]] = (spec["self"], hits)
        dangling[spec["name"]] = dangling_refs(root, files, hub_root, ref_re)
        print("   %-22s %5d tracked files, %3d entry points touched, %d dangling"
              % (spec["name"], len(files), len(hits), len(dangling[spec["name"]])))
    return per_consumer, dangling


def report_out(args, text):
    if not args.report:
        return
    dest = Path(args.report)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")
    print("   report written to %s" % dest)


def print_dangling(dangling):
    for name in sorted(dangling):
        for ref in dangling[name]:
            sys.stderr.write("FAIL: %s names a hub path that does not exist: %s\n"
                             % (name, ref))
    return sum(len(v) for v in dangling.values())


def main():
    args = build_args()
    hub_root = Path(args.hub_root).resolve()
    try:
        data = load_inventory(Path(args.inventory).resolve())
        entries = discover_entry_points(hub_root, data["entry_point_classes"])
        print("== consumer inventory: %d entry points, %d consumers =="
              % (len(entries), len(data["consumers"])))
        with tempfile.TemporaryDirectory(prefix="consumer-inventory-") as tmp:
            per_consumer, dangling = collect(data, args, hub_root, entries, Path(tmp))
    except Failure as exc:
        sys.stderr.write("FAIL: %s\n" % exc)
        return 1
    rows = [grade(e, per_consumer) for e in entries]
    report_out(args, render_report(rows, data["consumers"], dangling))
    for status in STATUS_ORDER:
        print("   %-26s %d" % (status, len([r for r in rows if r["status"] == status])))
    if print_dangling(dangling):
        sys.stderr.write("CONSUMER INVENTORY FAILED (dangling hub references)\n")
        return 1
    print("CONSUMER INVENTORY OK (%d unconfirmed candidate repo(s) still to resolve)"
          % len(data.get("unconfirmed", [])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
