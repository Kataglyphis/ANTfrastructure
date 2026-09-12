#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Four fleet workflow conventions, asserted instead of restated in comments.

Each of the four is written down somewhere in the fleet -- most of them in
several workflow headers at once -- and enforced by nothing, so the copies drift
and the rule is only as strong as the last person who read one.
docs/code-quality-tooling.md#four-fleet-workflow-conventions-workflow-lint

  runner-ban       A `*-latest` runner label is banned fleet-wide: the alias
                   MOVES, so the OS under a green build changes with no commit
                   to blame. Seven workflow headers say so today.
  job-timeout      Every job that owns a runner carries `timeout-minutes`.
                   Without it a hung step burns the account's six-hour default.
  permissions      Every workflow declares `permissions:` at the top level or on
                   every job, so GITHUB_TOKEN is not whatever the repository
                   default happens to be that month.
  artifact-error   `actions/upload-artifact` sets `if-no-files-found: error`.
                   The default is `warn`: a build that produced nothing uploads
                   nothing and stays green.

THE RAMP. Three of the four have a real backlog in real workflows, so this
follows lint-env-knobs.sh's ramp rather than turning eight repositories red in
one commit: those three REPORT and pass unless armed with
WORKFLOW_CONVENTIONS_GATE (`1`/`all`, or a comma-separated list of check names;
`0`/`off`/`no`/`none`/`false`/empty disarms every ramped check). `runner-ban` is
armed ALWAYS: it is measured clean across the whole fleet, so enforcing it costs
nothing today and is the only state in which the seven headers are true.

THE RATCHET, because "advisory" alone can grow for ever. Every repository's
count of RAMPING findings per check is FROZEN in a CENSUS row of
workflow-conventions.allow and may only go down: a count above its row fails
whatever the arming says, and a check with findings and no row fails too, so a
new violation is red on the day it lands even while the convention is ramping.
An armed check is graded by the findings above and counts zero here, which gives
every finding exactly one verdict and retires a row the moment its check is
armed. Going down is the point of the ramp, so it is not made expensive: in this
hub, whose commit can edit the row beside the fix, an unrecorded shrink FAILS
the way every other allow file here does; in a consumer, which reads this table
through the submodule and cannot edit it, the shrink is reported with the number
to write down and passes. That asymmetry is the whole reason this is a count and
not the frozen offender list shellcheck-warnings.allow can afford.

DELIBERATE DEVIATIONS ARE DECLARED, not silent: a row in
workflow-conventions.allow with a reason. That is verify_ci_image_refs.py's
EXCUSED table, moved into a file because these rows name OTHER repositories'
files and the hub cannot hold them all in one module's dict. A row that matches
no live finding is stale and fails; a row naming a repository that
.github/consumers.json does not declare is a typo and fails. The bookkeeping
half never ramps -- an allowlist may not rot.

Usage:
    python3 linux/scripts/verify_workflow_conventions.py           # this repo
    python3 linux/scripts/verify_workflow_conventions.py <root>    # a consumer

The consumer root exists for the reason lint-workflows.sh takes one: a submodule
checkout puts this script INSIDE the consumer, where a root derived from
__file__ resolves to ANTfrastructure and the gate reports green over the wrong tree.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HUB_ROOT = HERE.parent.parent
ALLOW = HERE / "workflow-conventions.allow"
CONSUMERS = HUB_ROOT / ".github" / "consumers.json"

CHECKS = ("runner-ban", "job-timeout", "permissions", "artifact-error")
# Not a convention: the pseudo-check a file this gate cannot READ is reported
# under. It never ramps, is never counted in the census and cannot be excused --
# a workflow nothing graded is the hazard, not a finding about one.
PARSE = "parse"
# Armed with no knob: measured clean fleet-wide, so it can only catch a NEW one.
ALWAYS_ARMED = frozenset({"runner-ban"})
ARM_ENV = "WORKFLOW_CONVENTIONS_GATE"
# The obvious ways to say "off". Refusing them made switching the ramp off a
# hard failure, which teaches people to delete the call instead.
DISARM = frozenset({"", "0", "off", "no", "none", "false"})
CENSUS = "CENSUS"

UPLOAD_ACTION = "actions/upload-artifact"
LATEST_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*-latest$", re.IGNORECASE)
# Keys whose scalar value GitHub resolves to a runner label: `runs-on` itself,
# the `with:` inputs and matrix columns every lane in this fleet feeds it
# through, and an `os` column, which is the conventional third spelling.
RUNNER_KEYS = frozenset({"runs-on", "runs_on", "runner", "os"})
EXPRESSION = "${{"


class ParseError(Exception):
    """The file is not the block-YAML subset this gate can read."""


def fail(msg: str) -> None:
    # Flushed against stdout so a CI log reads in the order it happened: the
    # advisory lines and the failures below them are one narrative.
    sys.stdout.flush()
    sys.stderr.write("FAIL: %s\n" % msg)
    sys.stderr.flush()


# --- the YAML subset ---------------------------------------------------------
# Hand-parsed for verify_ci_image_refs.py's reason: the gate must run on the
# stdlib alone, CI installs no PyYAML for it. The subset is block mappings,
# block sequences (indented, or at the SAME column as their key, which is
# ordinary YAML), flow sequences and flow mappings, plain and quoted scalars,
# and block scalars kept as one opaque string. Anything outside it RAISES rather
# than being read approximately -- anchors, aliases, merge keys, multi-document
# files, a flow collection that spans lines or holds a collection as a KEY, a
# document whose top level is not a mapping, and any line the walk did not
# consume: a gate that guesses at its input is worse than one that says it
# cannot read it.

_KEY = re.compile(r"^(?P<key>(?:\"[^\"]*\"|'[^']*'|[^:#\s][^:#]*?))\s*:(?:\s+(?P<val>.*?))?\s*$")
# `-` then whitespace or end of line. `-foo: bar` is a KEY named `-foo`, and
# reading it as a sequence entry silently reshapes the document.
_ITEM = re.compile(r"^-(?:(?P<gap>[ \t]+)(?P<rest>\S.*?))?[ \t]*$")
_BLOCK = re.compile(r"^[|>][+-]?[0-9]*$")
_FLOW_BREAK = ",:[]{}"


def _strip_comment(line: str) -> str:
    out, quote = [], ""
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        out.append(ch)
    return "".join(out).rstrip()


# --- flow collections --------------------------------------------------------
# `runs-on: [ubuntu-latest]` and `jobs: {build: {...}}` are valid YAML that this
# gate used to hand to _scalar() as one opaque string: the banned label inside
# was never looked at and the file reported clean. Read for real, or refuse.


def _flow_ws(s: str, i: int) -> int:
    while i < len(s) and s[i] in " \t":
        i += 1
    return i


def _flow_scalar(s: str, i: int):
    """One quoted or plain scalar inside a flow collection -> (text, next index)."""
    if i < len(s) and s[i] in "\"'":
        end = s.find(s[i], i + 1)
        if end < 0:
            raise ParseError("a quoted scalar inside a flow collection is unterminated")
        return s[i + 1:end], end + 1
    j = i
    while j < len(s) and s[j] not in _FLOW_BREAK:
        j += 1
    text = s[i:j].strip()
    if not text:
        raise ParseError("an empty entry in a flow collection")
    if text[0] in "&*" or text.startswith("<<"):
        raise ParseError("anchors, aliases and merge keys are not supported")
    return text, j


def _flow_close(s: str, i: int, close: str, what: str):
    """(finished, next index) after one entry: a `,`, the closer, or a refusal."""
    i = _flow_ws(s, i)
    if i >= len(s):
        raise ParseError("an unterminated flow %s; one that spans lines is "
                         "outside this subset" % what)
    if s[i] == close:
        return True, i + 1
    if s[i] != ",":
        raise ParseError("unexpected %r inside a flow %s" % (s[i], what))
    i = _flow_ws(s, i + 1)
    if i < len(s) and s[i] == close:  # a trailing comma before the closer
        return True, i + 1
    return False, i


def _flow_seq(s: str, i: int, line: int):
    out, i = [], _flow_ws(s, i + 1)
    if i < len(s) and s[i] == "]":
        return out, i + 1
    while True:
        node, i = _flow_node(s, i, line)
        out.append(node)
        done, i = _flow_close(s, i, "]", "sequence")
        if done:
            return out, i


def _flow_map(s: str, i: int, line: int):
    out, i = {}, _flow_ws(s, i + 1)
    if i < len(s) and s[i] == "}":
        return out, i + 1
    while True:
        i = _flow_ws(s, i)
        if i < len(s) and s[i] in "[{":
            raise ParseError("a flow collection as a mapping KEY is not supported")
        key, i = _flow_scalar(s, i)
        i = _flow_ws(s, i)
        val = None
        if i < len(s) and s[i] == ":":
            val, i = _flow_node(s, i + 1, line)
        out[key] = (val, line)
        done, i = _flow_close(s, i, "}", "mapping")
        if done:
            return out, i


def _flow_node(s: str, i: int, line: int):
    i = _flow_ws(s, i)
    if i >= len(s):
        raise ParseError("a flow collection ends in the middle of a value")
    if s[i] == "[":
        return _flow_seq(s, i, line)
    if s[i] == "{":
        return _flow_map(s, i, line)
    return _flow_scalar(s, i)


def _scalar(text: str, line: int = 0):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    if text[:1] in ("[", "{"):
        node, i = _flow_node(text, 0, line)
        if text[i:].strip():
            raise ParseError("%r follows a flow collection" % text[i:].strip()[:24])
        return node
    if text.startswith(("&", "*")) or text.startswith("<<"):
        raise ParseError("anchors, aliases and merge keys are not supported")
    return text


def _lines(text: str):
    """(indent, content, line number) for every line that carries structure."""
    out = []
    for num, raw in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
        if raw.lstrip().startswith("#"):
            continue
        line = _strip_comment(raw)
        if not line.strip():
            continue
        if line.strip() in ("---", "..."):
            raise ParseError("multi-document files are not supported")
        out.append((len(line) - len(line.lstrip(" ")), line.strip(), num))
    return out


class _Cursor:
    def __init__(self, rows):
        self.rows = rows
        self.i = 0

    def peek(self):
        return self.rows[self.i] if self.i < len(self.rows) else None


def _skip_continuation(cur: _Cursor, indent: int) -> None:
    """Consume the deeper lines a scalar owns: a `|`/`>` block, or the wrapped
    remainder of a plain multi-line scalar. A key cannot hold both a value and
    children, so anything deeper here belongs to the value -- and leaving it in
    the stream would end the enclosing mapping early and silently drop the rest
    of the file, which is a workflow this gate then graded nothing about."""
    while True:
        row = cur.peek()
        if row is None or row[0] <= indent:
            return
        cur.i += 1


def _parse(cur: _Cursor, indent: int):
    """The node starting at the current row, at or beyond ``indent``."""
    row = cur.peek()
    if row is None or row[0] < indent:
        return None
    if _ITEM.match(row[1]):
        return _parse_seq(cur, row[0])
    return _parse_map(cur, row[0])


def _parse_seq(cur: _Cursor, indent: int) -> list:
    out = []
    while True:
        row = cur.peek()
        if row is None or row[0] != indent:
            return out
        m = _ITEM.match(row[1])
        if not m:
            return out
        cur.i += 1
        rest = m.group("rest")
        if rest is None:
            out.append(_parse(cur, indent + 1))
            continue
        # `- key: value` opens a mapping whose keys align where the dash's own
        # padding put the first one -- measured, not assumed to be one space.
        at = indent + 1 + len(m.group("gap"))
        if _KEY.match(rest):
            cur.rows[cur.i - 1] = (at, rest, row[2])
            cur.i -= 1
            out.append(_parse_map(cur, at))
        else:
            out.append(_scalar(rest, row[2]))
            _skip_continuation(cur, indent)


def _child(cur: _Cursor, indent: int):
    """The node a valueless key owns, or None.

    A block sequence may sit at the SAME column as its key -- `steps:` with its
    `- uses:` entries flush underneath is ordinary, valid, extremely common
    Actions YAML. Demanding a strictly deeper child read that as an empty key
    and dropped every entry: an upload step with no `if-no-files-found` went
    invisible under one, and a matrix `include:` truncated the rest of its job
    under another, which then reported a `timeout-minutes` the job did carry. A
    dash at exactly this column cannot belong to an ENCLOSING sequence, whose
    own dash is necessarily further left, so there is no ambiguity to weigh."""
    nxt = cur.peek()
    if nxt is None:
        return None
    if nxt[0] > indent:
        return _parse(cur, indent + 1)
    if nxt[0] == indent and _ITEM.match(nxt[1]):
        return _parse_seq(cur, indent)
    return None


def _parse_map(cur: _Cursor, indent: int) -> dict:
    out: dict = {}
    while True:
        row = cur.peek()
        if row is None or row[0] != indent or _ITEM.match(row[1]):
            return out
        m = _KEY.match(row[1])
        if not m:
            return out
        cur.i += 1
        key = _scalar(m.group("key"), row[2])
        if not isinstance(key, str):
            # `[a]: v`. Unhashable here, so without this it is a TypeError
            # traceback rather than the refusal the subset promises.
            raise ParseError("a flow collection as a mapping KEY is not supported")
        val = m.group("val")
        if val is None or val == "":
            out[key] = (_child(cur, indent), row[2])
        elif _BLOCK.match(val):
            _skip_continuation(cur, indent)
            out[key] = ("", row[2])
        else:
            out[key] = (_scalar(val, row[2]), row[2])
            _skip_continuation(cur, indent)


def load_yaml(path: Path) -> dict:
    """The document as {key: (value, line)} maps; sequences hold bare values."""
    rows = _lines(path.read_text(encoding="utf-8"))
    if not rows:
        raise ParseError("the file carries no YAML at all -- it is empty, or "
                         "nothing but comments")
    cur = _Cursor(rows)
    node = _parse(cur, 0)
    if not isinstance(node, dict):
        raise ParseError("the top level is a %s, not the mapping a workflow or a "
                         "composite action is"
                         % ("sequence" if isinstance(node, list) else "scalar"))
    left = cur.peek()
    if left is not None:
        raise ParseError("line %d (%r) is outside the document the walk read, so "
                         "the rest of the file was graded by nothing"
                         % (left[2], left[1][:40]))
    return node


def value(node, key, default=None):
    """The value half of a {key: (value, line)} entry."""
    if isinstance(node, dict) and key in node:
        return node[key][0]
    return default


def line_of(node, key, default=0):
    if isinstance(node, dict) and key in node:
        return node[key][1]
    return default


# --- the four checks ---------------------------------------------------------


def _label_values(val) -> list:
    """The literal strings in a runner-key value: a scalar, a sequence, or the
    `runs-on: {group: ..., labels: [...]}` mapping GitHub also accepts."""
    if isinstance(val, str):
        return [val]
    if isinstance(val, list):
        out = []
        for item in val:
            out.extend(_label_values(item))
        return out
    if isinstance(val, dict):
        out = []
        for inner in val.values():
            out.extend(_label_values(inner[0] if isinstance(inner, tuple) else inner))
        return out
    return []


def _labels(node, out):
    """Every literal value a runner label can be spelled as, with its line."""
    if isinstance(node, dict):
        for key, (val, num) in node.items():
            if key in RUNNER_KEYS:
                out.extend((v, num) for v in _label_values(val))
            _labels(val, out)
    elif isinstance(node, list):
        for item in node:
            _labels(item, out)


def check_runner_ban(rel, doc):
    found = []
    _labels(doc, found)
    return [(rel, "runner-ban", label, num,
             "runner label '%s' is a MOVING alias; pin the image (ubuntu-26.04, "
             "windows-2025)" % label)
            for label, num in found
            if EXPRESSION not in label and LATEST_LABEL.match(label)]


def _jobs(doc):
    jobs = value(doc, "jobs")
    return jobs.items() if isinstance(jobs, dict) else []


def check_job_timeout(rel, doc):
    out = []
    for jid, (job, num) in _jobs(doc):
        if not isinstance(job, dict) or "uses" in job:
            # A job that calls a reusable workflow may not carry
            # timeout-minutes at all -- the callee's jobs own it.
            continue
        if "timeout-minutes" not in job:
            out.append((rel, "job-timeout", jid, num,
                        "job '%s' has no timeout-minutes; a hung step runs to "
                        "the six-hour account default" % jid))
    return out


def check_permissions(rel, doc):
    if "permissions" in doc:
        return []
    return [(rel, "permissions", jid, num,
             "no top-level `permissions:` and job '%s' declares none either, so "
             "GITHUB_TOKEN gets the repository default" % jid)
            for jid, (job, num) in _jobs(doc)
            if not isinstance(job, dict) or "permissions" not in job]


def _steps(node, out):
    if isinstance(node, dict):
        for key, (val, _num) in node.items():
            if key == "steps" and isinstance(val, list):
                out.extend(s for s in val if isinstance(s, dict))
            else:
                _steps(val, out)
    elif isinstance(node, list):
        for item in node:
            _steps(item, out)


def check_artifact_error(rel, doc):
    steps = []
    _steps(doc, steps)
    out = []
    for step in steps:
        uses = value(step, "uses")
        if not isinstance(uses, str) or UPLOAD_ACTION not in uses:
            continue
        with_block = value(step, "with")
        setting = value(with_block, "if-no-files-found") if isinstance(with_block, dict) else None
        if setting == "error":
            continue
        # The allow file is pipe-delimited and a job id or a runner label cannot
        # carry one, but a step NAME can. Normalise it here so the row a reader
        # writes is exactly the detail the gate printed.
        name = (value(step, "name") or value(step, "id") or "(unnamed)").replace("|", "/")
        out.append((rel, "artifact-error", name, line_of(step, "uses"),
                    "upload-artifact step %r sets if-no-files-found=%s; a build "
                    "that produced nothing uploads nothing and stays green"
                    % (name, setting or "<unset, defaults to warn>")))
    return out


CHECKERS = {
    "runner-ban": check_runner_ban,
    "job-timeout": check_job_timeout,
    "permissions": check_permissions,
    "artifact-error": check_artifact_error,
}


# --- the EXCUSED-with-reason table and the census ratchet ---------------------


def _allow_fail(path: Path, num: int, msg: str):
    raise SystemExit("FAIL: %s:%d: %s\n" % (path.name, num, msg))


def _census_row(path: Path, parts: list, num: int, census: dict):
    """`CENSUS | <repo> | <check> | <count> | <reason>` -> into `census`."""
    if len(parts) < 5 or not parts[4]:
        _allow_fail(path, num, "expected 'CENSUS | <repo> | <check> | <count> | "
                               "<reason>'; a frozen count with no reason is not a baseline.")
    if parts[2] not in CHECKS:
        _allow_fail(path, num, "unknown check %r (known: %s)" % (parts[2], ", ".join(CHECKS)))
    if not parts[3].isdigit():
        _allow_fail(path, num, "census count %r is not a number" % parts[3])
    key = (parts[1], parts[2])
    if key in census:
        _allow_fail(path, num, "duplicate CENSUS row for %s [%s] (already at line %d). "
                               "Two baselines for one check means one of them is unread."
                    % (key[0], key[1], census[key][2]))
    census[key] = (int(parts[3]), " | ".join(parts[4:]), num)


def _excuse_row(path: Path, parts: list, num: int, rows: list, seen: dict):
    """`<repo> | <path> | <check> | <detail> | <reason>` -> onto `rows`."""
    if len(parts) < 5 or not parts[4]:
        _allow_fail(path, num, "expected '<repo> | <path> | <check> | <detail> | "
                               "<reason>'; a row with no reason is not an excuse.")
    if parts[2] not in CHECKS:
        _allow_fail(path, num, "unknown check %r (known: %s)" % (parts[2], ", ".join(CHECKS)))
    key = tuple(parts[:4])
    if key in seen:
        _allow_fail(path, num, "duplicate row for %s (already at line %d). Two "
                               "reasons for one deviation means one of them is unread."
                    % (" | ".join(key), seen[key]))
    seen[key] = num
    rows.append((key, " | ".join(parts[4:]), num))


def load_allow(path: Path):
    """-> (excuse rows in file order, {(repo, check): (count, reason, line)})."""
    rows, seen, census = [], {}, {}
    if not path.exists():
        raise SystemExit("FAIL: %s is missing. Its CENSUS rows are the ratchet; "
                         "without them every ramped check would be advisory with "
                         "no ceiling.\n" % path)
    for num, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if parts[0] == CENSUS:
            _census_row(path, parts, num, census)
        else:
            _excuse_row(path, parts, num, rows, seen)
    return rows, census


def declared_repos():
    """(every repository .github/consumers.json declares, the hub's own name).

    A missing or malformed file FAILS rather than returning an empty set: the
    allow file's <repo> column is graded against this, so an empty answer turns
    the typo check off and a mis-spelled row then excuses nothing, for ever,
    while looking like an excuse that worked. That is the shape this gate is
    for."""
    try:
        raw = CONSUMERS.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit("FAIL: cannot read %s (%s); the allow file's <repo> and "
                         "CENSUS columns are graded against it.\n" % (CONSUMERS, exc))
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise SystemExit("FAIL: %s is not valid JSON (%s).\n" % (CONSUMERS, exc))
    consumers = data.get("consumers")
    if not isinstance(consumers, list) or not consumers:
        raise SystemExit("FAIL: %s declares no `consumers` list.\n" % CONSUMERS)
    names = set()
    for entry in consumers:
        name = entry.get("name") if isinstance(entry, dict) else None
        if not name:
            raise SystemExit("FAIL: %s has a consumer entry with no `name`: %r\n"
                             % (CONSUMERS, entry))
        names.add(name)
    hub = data.get("hub", {}).get("repo")
    if not hub:
        raise SystemExit("FAIL: %s declares no `hub.repo`.\n" % CONSUMERS)
    names.add(hub)
    return names, hub


def repo_name(root: Path) -> str:
    """The repository being linted, for the allow file's first column.

    The origin remote, because a clone directory can be renamed and a submodule
    checkout is named by its path, not by its project. Falls back to the
    directory name, which is what a fixture checkout with no remote has.
    """
    out = subprocess.run(["git", "-C", str(root), "remote", "get-url", "origin"],
                         capture_output=True, text=True)
    url = out.stdout.strip() if out.returncode == 0 else ""
    if url:
        return url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    return root.name


def armed() -> frozenset:
    raw = os.environ.get(ARM_ENV, "").strip()
    if raw.lower() in DISARM:
        return ALWAYS_ARMED
    if raw.lower() in ("1", "all"):
        return frozenset(CHECKS)
    named = {p.strip() for p in raw.split(",") if p.strip()}
    unknown = named - set(CHECKS)
    if unknown:
        raise SystemExit("FAIL: %s names unknown check(s): %s (known: %s; or %s "
                         "to disarm the ramped ones)\n"
                         % (ARM_ENV, ", ".join(sorted(unknown)), ", ".join(CHECKS),
                            "/".join(sorted(d for d in DISARM if d))))
    return frozenset(named) | ALWAYS_ARMED


def yaml_files(root: Path) -> list:
    gh = root / ".github"
    found = sorted(gh.glob("workflows/*.yml")) + sorted(gh.glob("workflows/*.yaml"))
    return found + sorted(gh.glob("actions/*/action.yml")) + sorted(gh.glob("actions/*/action.yaml"))


def collect(root: Path, files: list) -> list:
    findings = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        try:
            doc = load_yaml(path)
        except ParseError as exc:
            findings.append((rel, PARSE, "-", 0,
                             "cannot be read by this gate (%s), so NONE of the "
                             "four conventions was graded over it" % exc))
            continue
        # A composite action has no `jobs:` and no `permissions:` of its own;
        # only the two step-shaped checks can say anything about one.
        is_action = rel.startswith(".github/actions/")
        for name in CHECKS:
            if is_action and name in ("job-timeout", "permissions"):
                continue
            findings.extend(CHECKERS[name](rel, doc))
    return findings


def grade_findings(findings: list, repo: str, excused: dict, live: frozenset):
    """Each finding gets exactly one verdict. -> (excuses used, fatal, advisory)"""
    used, fatal, advisory = set(), 0, 0
    for rel, check, detail, num, why in sorted(findings):
        key = (repo, rel, check, detail)
        if key in excused:
            used.add(key)
            print("  EXCUSED %s:%d [%s] %s" % (rel, num, check, excused[key]))
        elif check in live or check == PARSE:
            fail("%s:%d [%s] %s" % (rel, num, check, why))
            fatal += 1
        else:
            print("  ADVISORY %s:%d [%s] %s" % (rel, num, check, why))
            advisory += 1
    return used, fatal, advisory


def grade_rows(rows: list, census: dict, repo: str, known: set, used: set):
    """The bookkeeping half, which never ramps. -> (stale rows, typo'd rows)"""
    stale = typos = 0
    for key, _reason, num in rows:
        if key[0] == repo and key not in used:
            fail("%s:%d: STALE allow row -- %s no longer reports [%s] %s. "
                 "Delete the row." % (ALLOW.name, num, key[1], key[2], key[3]))
            stale += 1
    named = [(key[0], num) for key, _reason, num in rows]
    named += [(key[0], num) for key, (_c, _r, num) in census.items()]
    for name, num in sorted(named, key=lambda pair: pair[1]):
        if name not in known:
            fail("%s:%d: row names repository %r, which .github/consumers.json "
                 "does not declare." % (ALLOW.name, num, name))
            typos += 1
    return stale, typos


def grade_census(findings: list, repo: str, excused: set, census: dict,
                 is_hub: bool, live: frozenset) -> int:
    """The ratchet: this repository's RAMPING count per check may only go down.
    An armed check counts zero -- its findings already failed above, and one
    finding may not produce two verdicts. -> the number of rows that failed."""
    counts = {}
    for rel, check, detail, _num, _why in findings:
        if check not in live and check != PARSE and (repo, rel, check, detail) not in excused:
            counts[check] = counts.get(check, 0) + 1
    bad = 0
    for check in CHECKS:
        now = counts.get(check, 0)
        row = census.get((repo, check))
        if row is None:
            if now:
                bad += 1
                fail("%s reports %d unexcused, still-ramping [%s] finding(s) and "
                     "%s has no CENSUS row for it. Fix them, arm the check, or "
                     "freeze the count with a reason: "
                     "'CENSUS | %s | %s | %d | <why>'."
                     % (repo, now, check, ALLOW.name, repo, check, now))
            continue
        was, _reason, num = row
        if now > was:
            bad += 1
            fail("%s:%d: [%s] GREW from %d to %d in %s. The census may only go "
                 "down; fix the new finding(s) above." % (ALLOW.name, num, check, was, now, repo))
        elif now < was and is_hub:
            bad += 1
            fail("%s:%d: [%s] is down to %d in %s from a frozen %d -- %s in the "
                 "same commit so the baseline cannot rot."
                 % (ALLOW.name, num, check, now, repo, was,
                    "delete the row" if now == 0 else "lower the row"))
        elif now < was:
            print("   RATCHET [%s] is down to %d in %s from a frozen %d; %s:%d "
                  "can be lowered next time the hub is edited."
                  % (check, now, repo, was, ALLOW.name, num))
    return bad


def report(repo: str, findings: list, rows: list, census: dict, live: frozenset,
           known: set, hub: str) -> int:
    excused = {key: reason for key, reason, _num in rows if key[0] == repo}
    foreign = sum(1 for key, _r, _n in rows if key[0] != repo)

    used, fatal, advisory = grade_findings(findings, repo, excused, live)
    stale, typos = grade_rows(rows, census, repo, known, used)
    grew = grade_census(findings, repo, set(excused), census, repo == hub, live)

    print("   %d finding(s): %d enforced, %d advisory, %d excused; "
          "%d allow row(s) for this repo, %d for other repositories"
          % (len(findings), fatal, advisory, len(used), len(excused), foreign))
    if advisory:
        print("   (advisory -- set %s=%s to enforce; the census ratchet holds "
              "them at today's count meanwhile)"
              % (ARM_ENV, ",".join(sorted(set(CHECKS) - live))))
    if fatal or stale or typos or grew:
        sys.stderr.write("WORKFLOW CONVENTION GATE FAILED (%d finding(s), %d stale "
                         "row(s), %d unknown repo(s), %d census row(s))\n"
                         % (fatal, stale, typos, grew))
        return 1
    print("WORKFLOW CONVENTIONS OK (%s)" % repo)
    return 0


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HUB_ROOT
    live = armed()
    known, hub = declared_repos()
    repo = repo_name(root)
    print("== workflow conventions under %s ==" % root)
    print("   repository %s; enforced %s; advisory %s"
          % (repo, ",".join(sorted(live)), ",".join(sorted(set(CHECKS) - live)) or "-"))

    files = yaml_files(root)
    if not files:
        # A gate that checks nothing must not report green.
        fail("no workflow or action YAML under %s/.github -- wrong root?" % root)
        return 1
    if repo not in known:
        # Every row of the allow file -- excuse and census alike -- is keyed on
        # this name. Under a repository consumers.json does not declare, neither
        # could ever be written, so the gate would grade the files with its whole
        # bookkeeping half disconnected and still print OK.
        fail("%r, resolved from this tree's `origin` remote, is not declared in "
             ".github/consumers.json. No %s row can be keyed to it, so its "
             "%d file(s) would be graded with the excuse table and the census "
             "ratchet both inert. Declare the repository, or fix the remote."
             % (repo, ALLOW.name, len(files)))
        return 1
    rows, census = load_allow(ALLOW)
    return report(repo, collect(root, files), rows, census, live, known, hub)


if __name__ == "__main__":
    sys.exit(main())
