#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""The apply half of renovate-local.sh: reads the report JSON and rewrites one value per edit.

See docs/dependency-updates.md#how-one-value-gets-rewritten

Subcommands (argv[1]); every line of output is tab-separated:
  config   <ndjson-log>                          the --print-config record
  managers <config.json> <ls-files.txt>          manager, default-enabled, file
  rows     <report.json>                         manager, file, dep, cur, new
  skipped  <report.json>                         SKIP manager, file, dep, cur, reason | DESIGN reason, count
  lockmaint <report> <config>                    manager, file: manifests whose lock lockFileMaintenance refreshes
  plan     <report> <config> <root> <plan.json>  the plan (+ the JSON edits)
  verify   <root> <plan.json>                    the pre-flight and predicted audit, writing nothing
  edit     <root> <plan.json>                    write, then audit the file or put it back
"""
import collections
import json
import os
import re
import stat
import sys
import tempfile
from collections.abc import Iterator, Mapping, Sequence
from typing import NotRequired, TypedDict, cast

import renovate_audit
import renovate_locator


class RenovateUpdate(TypedDict, total=False):
    newValue: str
    newDigest: str
    updateType: str


class RenovateWarning(TypedDict, total=False):
    message: str
    topic: str


class RenovateDependency(TypedDict, total=False):
    depName: str
    packageName: str
    datasource: str
    depType: str
    currentValue: str
    currentDigest: str
    skipReason: str
    updates: list[RenovateUpdate]
    warnings: list[RenovateWarning]


class RenovatePackageFile(TypedDict, total=False):
    packageFile: str
    datasource: str
    deps: list[RenovateDependency]


class RenovateRepository(TypedDict, total=False):
    packageFiles: dict[str, list[RenovatePackageFile]]


class RenovateReport(TypedDict, total=False):
    repositories: dict[str, RenovateRepository]


class RenovateRule(TypedDict, total=False):
    dependencyDashboardApproval: bool
    description: str | list[str]
    enabled: bool


class RenovateManager(TypedDict, total=False):
    managerFilePatterns: list[str]
    enabled: bool
    lockFileMaintenance: dict[str, bool]


RenovateConfig = dict[str, object]
PlanRow = dict[str, str]
GroupKey = tuple[str, str, str, str, str]
PinGroup = tuple[str, str, str, int]


class PlanEdit(TypedDict):
    file: str
    line: int
    old: str
    new: str
    manager: str
    dep: str
    cur: str
    next: str


class PendingTarget(TypedDict):
    path: str
    lines: list[str]
    stat: os.stat_result
    steps: list[PlanEdit]
    syntax: NotRequired[str]
    before: NotRequired[str]
    groups: NotRequired[list[PinGroup]]


# Other match keys are named in the output, never silently ignored (rule_hit).
FIELDS = {"matchManagers": "manager", "matchDatasources": "datasource",
          "matchDepNames": "dep", "matchPackageNames": "pkg",
          "matchFileNames": "file", "matchDepTypes": "depType",
          "matchUpdateTypes": "updateType"}
# Fills empty columns: under bash's IFS=tab an empty middle field collapses and shifts the rest.
DASH = "-"


def load(path: str) -> object:
    """Parsed JSON, or an exit naming the file rather than a json/decoder.py traceback."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        sys.exit(f"cannot read {path}: {exc}")
    except ValueError as exc:
        sys.exit(f"{path} is not valid JSON: {exc}")


def load_obj(path: str) -> RenovateConfig:
    """A JSON object; a list would parse and then die in a .get() that no longer names the file."""
    obj = load(path)
    if not isinstance(obj, dict):
        sys.exit(f"{path} must be a JSON object, not {type(obj).__name__}")
    return cast(RenovateConfig, obj)


def load_report(path: str) -> RenovateReport:
    """A Renovate report; a wrong shape must fail, never read as "up to date"."""
    rep = load_obj(path)
    if not isinstance(rep.get("repositories"), dict):
        sys.exit(f'{path} is not a Renovate report: no top-level "repositories" object')
    return cast(RenovateReport, rep)


def in_root(root: str, rel: str) -> str | None:
    """`rel` resolved inside `root`, or None; `..`, absolute paths and symlinks out all fail alike."""
    if not rel:
        return None
    base = os.path.realpath(root)
    full = os.path.realpath(os.path.join(base, rel))
    return full if full.startswith(base + os.sep) else None


def contained(root: str, rel: str, source: str) -> str:
    """`rel` resolved inside `root`, or exit; called where a path enters, so no later use can forget."""
    full = in_root(root, rel)
    if full is None:
        sys.exit(f"{source} names {rel!r}, which is not a file inside {root}; nothing written")
    return full


def resolved_config(log: str) -> RenovateConfig | None:
    """The --print-config record, with `extends` presets already expanded by Renovate."""
    out = None
    with open(log, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                rec = cast(dict[str, object], json.loads(line))
            except ValueError:
                continue
            if "resolved config" in cast(str, rec.get("msg") or "").lower():
                out = cast(RenovateConfig, rec.get("config") or {})
    return out


def _first_match(pats: Sequence[str] | None, files: Sequence[str]) -> str:
    for pat in pats or []:
        rx = renovate_locator.renovate_pattern(pat)
        for f in files:
            if rx.search(f):
                return f
    return ""


def managers(cfg: RenovateConfig, listing: str) -> None:
    """Every manager whose own Renovate file patterns match a tracked file."""
    with open(listing, encoding="utf-8", errors="replace") as fh:
        files = [line.strip() for line in fh if line.strip()]
    for name in sorted(cfg):
        block = cfg[name]
        if not isinstance(block, dict) or not block.get("managerFilePatterns"):
            continue
        hit = _first_match(cast(RenovateManager, block)["managerFilePatterns"], files)
        if hit:
            off = "false" if block.get("enabled") is False else "true"
            print(f"{name}\t{off}\t{hit}")


def _deps(report: RenovateReport) -> Iterator[tuple[str, RenovatePackageFile, RenovateDependency]]:
    """(manager, packageFile entry, dep) for every dependency the report carries."""
    for repo in (report.get("repositories") or {}).values():
        for mgr, files in (repo.get("packageFiles") or {}).items():
            for f in files:
                for dep in f.get("deps") or []:
                    yield mgr, f, dep


def rows(report: RenovateReport) -> Iterator[PlanRow]:
    """One dict per pending update; only a dep's first update, the rest being other bucket levels."""
    for mgr, f, dep in _deps(report):
        for up in dep.get("updates") or []:
            yield _row(mgr, f, dep, up)
            break


# Skip reasons that mean "nothing to look up" by construction; any other reason hides a pin from every report.
BY_DESIGN = {"disabled", "ignored", "package-rules", "path-dependency", "local-dependency",
             "local", "file-dependency", "internal-package", "unspecified-version",
             "unversioned-reference", "git-dependency", "inherited-dependency",
             "contains-variable"}


def _skip_reason(dep: RenovateDependency) -> str:
    """Why Renovate never compared this dep's value; "" when it did."""
    if dep.get("skipReason"):
        return dep["skipReason"]
    if dep.get("updates"):
        return ""
    warns = [w.get("message") or w.get("topic") or "" for w in dep.get("warnings") or []]
    return "lookup-failed: " + warns[0] if warns else ""


def _named_build_context(root: str, file: str, name: str) -> bool:
    """A COPY source with the adjacent DL3022 context assertion is not a registry image."""
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", name):
        return False
    base = os.path.realpath(root)
    path = os.path.realpath(os.path.join(base, file))
    try:
        if os.path.commonpath((base, path)) != base:
            return False
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except (OSError, ValueError):
        return False
    copy = re.compile(rf"^\s*COPY\b.*--from={re.escape(name)}(?=\s|$)", re.IGNORECASE)
    return any(i > 0 and lines[i - 1].strip() == "# hadolint ignore=DL3022" and copy.search(line)
               for i, line in enumerate(lines))


def _semantic_skip(manager: str, file: str, dep: RenovateDependency, reason: str,
                   root: str | None) -> str:
    """Distinguish non-version inputs from malformed version pins."""
    if dep.get("warnings"):
        return ""
    if (manager == "rust-toolchain" and reason == "invalid-version"
            and dep.get("depName") == "rust" and dep.get("currentValue") == "esp"):
        return "espup-toolchain-channel"
    if reason != "invalid-value":
        return ""
    name = dep.get("depName") or dep.get("packageName") or ""
    value = dep.get("currentValue") or ""
    if manager == "docker-compose" and {"latest", "stable"} & set(re.split(r"[-_.]", value.lower())):
        return "floating-image-tag"
    if manager == "dockerfile" and name.startswith(("local/", "docker.io/local/")):
        return "local-build-image"
    if manager == "dockerfile" and not value and root and _named_build_context(root, file, name):
        return "named-build-context"
    if manager == "github-actions" and re.fullmatch(
        r"\$\{\{\s*steps\.[A-Za-z_][\w-]*\.outputs\.[A-Za-z_][\w-]*\s*\}\}", value
    ):
        return "workflow-output-expression"
    if manager == "pep621" and re.fullmatch(
        r"@\s+git\+https://[A-Za-z0-9.-]+/(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+\.git", value.strip()
    ):
        return "floating-git-source"
    return ""


def skipped(report: RenovateReport, root: str | None = None) -> tuple[list[tuple[str, str, str, str, str]], collections.Counter[str]]:
    """(listed rows, by-design counts): deps Renovate never looked up, or whose lookup failed."""
    listed, design = [], collections.Counter()
    for mgr, f, dep in _deps(report):
        why = _skip_reason(dep)
        if why in BY_DESIGN:
            design[why] += 1
        elif semantic := _semantic_skip(mgr, f.get("packageFile") or "", dep, why, root):
            design[semantic] += 1
        elif why:
            listed.append((mgr, f.get("packageFile") or DASH,
                           dep.get("depName") or dep.get("packageName") or "?",
                           dep.get("currentValue") or DASH, _clean(why)))
    return listed, design


def _row(mgr: str, f: RenovatePackageFile, dep: RenovateDependency,
         up: RenovateUpdate) -> PlanRow:
    return {"manager": mgr, "file": f.get("packageFile") or "",
            "dep": dep.get("depName") or dep.get("packageName") or "?",
            "pkg": dep.get("packageName") or dep.get("depName") or "",
            "datasource": dep.get("datasource") or f.get("datasource") or "",
            "depType": dep.get("depType") or "",
            "cur": dep.get("currentValue") or "",
            "new": up.get("newValue") or "",
            "curDigest": dep.get("currentDigest") or "",
            # npm reports the new tarball's integrity hash on every update; only a digest pin moves by digest.
            "newDigest": (up.get("newDigest") or "") if dep.get("currentDigest") else "",
            "updateType": up.get("updateType") or ""}


def _one(pat: str, val: str) -> bool:
    neg = pat.startswith("!")
    if neg:
        pat = pat[1:]
    if pat.startswith("/") or "*" in pat or "?" in pat:
        hit = bool(renovate_locator.renovate_pattern(pat).search(val))
    else:
        hit = pat == val
    return hit != neg


def rule_hit(rule: RenovateRule, row: Mapping[str, str]) -> tuple[bool, list[str]]:
    """(matched, unevaluated keys); an unknown match* key counts as matching, the safe direction."""
    unknown = sorted(k for k in rule if k.startswith("match") and k not in FIELDS)
    for key, field in FIELDS.items():
        pats = cast(list[str] | None, rule.get(key))
        if pats and not any(_one(p, row.get(field) or "") for p in pats):
            return False, unknown
    return True, unknown


def refusal(row: Mapping[str, str], rules: Sequence[RenovateRule]) -> str:
    """The last matching dependencyDashboardApproval rule decides, as Renovate merges; "" = not refused."""
    out = ""
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict) or "dependencyDashboardApproval" not in rule:
            continue
        ok, unknown = rule_hit(rule, row)
        if not ok:
            continue
        if not rule.get("dependencyDashboardApproval"):
            out = ""
            continue
        why = rule.get("description") or "(no description)"
        if isinstance(why, list):
            why = " ".join(why)
        out = f"packageRule #{i + 1}: {why[:150]}"
        if unknown:
            out += " [unevaluated: {}; refused conservatively]".format(",".join(unknown))
    return out


# The managers renovate-locks.sh owns a lock tool for; Renovate supports maintenance for more.
LOCK_MANAGERS = ("cargo", "npm", "pep621", "pub")
# The dep column of a maintenance lock job (renovate-locks.sh LOCK_ALL): every entry, not one.
LOCK_ALL = "*"


def _maint_on(cfg: RenovateConfig, mgr: str, path: str) -> bool:
    """Renovate's own layering: the top-level switch, the manager's block, then the last matching packageRule."""
    top = cfg.get("lockFileMaintenance")
    on = isinstance(top, dict) and top.get("enabled") is True
    block = cfg.get(mgr)
    sub = (block or {}).get("lockFileMaintenance") if isinstance(block, dict) else None
    if isinstance(sub, dict) and "enabled" in sub:
        on = sub["enabled"] is True
    row = {"manager": mgr, "file": path, "updateType": "lockFileMaintenance"}
    for rule in cast(list[RenovateRule], cfg.get("packageRules") or []):
        if isinstance(rule, dict) and "enabled" in rule and rule_hit(rule, row)[0]:
            on = rule["enabled"] is True
    return on


def lock_maintenance(report: RenovateReport, cfg: RenovateConfig) -> Iterator[tuple[str, str]]:
    """(manager, packageFile) per manifest whose lock is under lockFileMaintenance; the report never says so itself."""
    for repo in (report.get("repositories") or {}).values():
        for mgr, files in sorted((repo.get("packageFiles") or {}).items()):
            if mgr not in LOCK_MANAGERS:
                continue
            for f in files:
                path = f.get("packageFile") or ""
                if path and _maint_on(cfg, mgr, path):
                    yield mgr, path


def _clean(text: str) -> str:
    """One plan column, flattened: a tab would add a column and a newline a row."""
    return (text or DASH).replace("\t", " ").replace("\r", "") \
                         .replace("\n", " ") or DASH


def emit(kind: str, row: Mapping[str, str], line: str | int, detail: str,
         before: str = DASH, after: str = DASH) -> None:
    """One plan row, ending in the line's exact text before and after, taken from the edit apply writes."""
    print("\t".join(_clean(str(col)) for col in (
        kind, row["manager"], row["file"], row["dep"],
        row["curDigest"][:12] or row["cur"], row["newDigest"][:12] or row["new"],
        line, detail, before, after)))


def _read_lines(path: str) -> list[str]:
    """newline="" keeps a CRLF checkout CRLF."""
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read().split("\n")


def group_key(row: Mapping[str, str]) -> GroupKey:
    """One pin in one file; rows sharing it are occurrences the locator must find exactly."""
    return (row["file"], row["manager"], row["dep"],
            row["curDigest"] or row["cur"], row["newDigest"] or row["new"])


def plan_group(group: Sequence[PlanRow], edits: list[PlanEdit]) -> None:
    """One group's verdict, and its edits. Nothing is written here."""
    row = group[0]
    old = row["curDigest"] or row["cur"]
    new = row["newDigest"] or row["new"]
    if not old or not new:
        emit("SKIP", row, DASH, "the report carries no comparable value pair")
        return
    try:
        lines = _read_lines(row["path"])
    except OSError as exc:
        emit("SKIP", row, DASH, "cannot read {}: {}".format(row["file"], exc))
        return
    syntax = renovate_locator.syntax(row["manager"], row["file"])
    kind, found, why = renovate_locator.resolve(
        syntax, lines, row["dep"], old, new, len(group))
    if kind == "REFUSE":
        emit("SKIP", row, DASH, why)
        return
    if kind == "DONE":
        emit("DONE", row, found[0].line + 1, why)
        return
    # A real parser's second opinion, here so an unsanctioned group is skipped while the rest applies.
    _, _, why = renovate_audit.expected(
        syntax, "\n".join(lines), [(row["dep"], old, new, len(group))])
    if why:
        emit("SKIP", row, DASH, why)
        return
    for site in found:
        raw = lines[site.line]
        after = raw[:site.start] + new + raw[site.end:]
        edits.append({"file": row["file"], "line": site.line, "old": raw,
                      "new": after, "manager": row["manager"],
                      "dep": row["dep"], "cur": old, "next": new})
        emit("EDIT", row, site.line + 1, DASH, raw, after)


def plan(report: RenovateReport, cfg: RenovateConfig, root: str, planpath: str) -> None:
    rules = cast(list[RenovateRule], cfg.get("packageRules") or [])
    edits: list[PlanEdit] = []
    groups: dict[GroupKey, list[PlanRow]] = collections.OrderedDict()
    for row in rows(report):
        # Every packageFile is contained once, where it enters.
        row["path"] = contained(root, row["file"], "the report")
        why = refusal(row, rules)
        if why:
            emit("REFUSE", row, DASH, why)
        elif row["manager"] == "git-submodules":
            emit("SUBMODULE", row, DASH, DASH)
        else:
            groups.setdefault(group_key(row), []).append(row)
    for group in groups.values():
        plan_group(group, edits)
    with open(planpath, "w", encoding="utf-8") as fh:
        json.dump(edits, fh)


def _writable(path: str, rel: str) -> None:
    """Probe that the file and its directory are writable; os.access says yes on a read-only mount."""
    try:
        with open(path, "r+", encoding="utf-8"):
            pass
    except OSError as exc:
        sys.exit(f"cannot write {rel}: {exc}; nothing written, in any file")
    try:
        handle, probe = tempfile.mkstemp(dir=os.path.dirname(path),
                                         prefix=".renovate-probe-")
    except OSError as exc:
        sys.exit(f"cannot write in the directory holding {rel}: {exc}; this tool "
                 "replaces a manifest through a temp file beside it so the "
                 "file is never left half-written, and that needs a writable "
                 "directory. Nothing written, in any file.")
    os.close(handle)
    os.unlink(probe)


def _verify(steps: Sequence[PlanEdit], root: str) -> dict[str, PendingTarget]:
    """Re-read, contain and prove writable every target before the first byte: the run writes all or nothing."""
    files: dict[str, PendingTarget] = {}
    seen = set()
    for e in steps:
        target: PendingTarget | None = files.get(e["file"])
        if target is None:
            path = contained(root, e["file"], "the plan")
            try:
                # The stat lets _put_back() restore the times too.
                target = {"path": path, "lines": _read_lines(path),
                          "stat": os.stat(path), "steps": []}
            except OSError as exc:
                sys.exit("cannot read {}: {}; nothing written".format(e["file"], exc))
            _writable(path, e["file"])
            files[e["file"]] = target
        target["steps"].append(e)
        # The plan comes from the command line; a step missing any of these cannot be audited.
        blank = [k for k in ("manager", "dep", "cur", "next") if not e.get(k)]
        if blank:
            sys.exit(f"{e['file']} line {e['line'] + 1} is planned without {', '.join(blank)}, so the edit cannot be "
                     "checked against a parse of the file; nothing written, in "
                     "any file")
        # Two updates on one line is a planner bug; applying both would keep the last.
        if (e["file"], e["line"]) in seen:
            sys.exit(f"{e['file']} line {e['line'] + 1} is planned twice; nothing written, in any file")
        seen.add((e["file"], e["line"]))
        if e["line"] >= len(target["lines"]) or target["lines"][e["line"]] != e["old"]:
            sys.exit(f"{e['file']} line {e['line'] + 1} moved since the plan; nothing written, in any file")
    for rel, target in files.items():
        _sanction(rel, target)
    return files


def groups_of(steps: Sequence[PlanEdit]) -> list[PinGroup]:
    """(dep, old, new, lines planned) per pin: the count the locator was given, for the auditor to check."""
    counts = collections.OrderedDict()
    for e in steps:
        key = (e["dep"], e["cur"], e["next"])
        counts[key] = counts.get(key, 0) + 1
    return [key + (n,) for key, n in counts.items()]


def _manager_of(steps: Sequence[PlanEdit], rel: str) -> str:
    names = {e["manager"] for e in steps}
    if len(names) != 1:
        sys.exit(f"{rel} is planned under {len(names)} managers ({', '.join(sorted(names))}); one file has one syntax, "
                 "so this plan cannot be audited. Nothing written, in any file"
                 )
    return names.pop()


def _sanction(rel: str, target: PendingTarget) -> None:
    """What a real parser lets this run change in one file; per file, so two groups claiming one value fail."""
    target["syntax"] = renovate_locator.syntax(_manager_of(target["steps"], rel), rel)
    target["before"] = "\n".join(target["lines"])
    target["groups"] = groups_of(target["steps"])
    _, _, why = renovate_audit.expected(
        target["syntax"], target["before"], target["groups"])
    if why:
        sys.exit(f"{rel}: {why}. Nothing written, in any file")


def _edited(target: PendingTarget) -> str:
    """The exact text this plan would put on disk for one file."""
    lines = list(target["lines"])
    for e in target["steps"]:
        lines[e["line"]] = e["new"]
    return "\n".join(lines)


def predict(files: Mapping[str, PendingTarget]) -> None:
    """The post-write audit over the text the write would produce; `edit` still proves the file off disk."""
    for rel, target in files.items():
        why = renovate_audit.audit(target["syntax"], target["before"],
                                   _edited(target), target["groups"])
        if why:
            sys.exit(f"{rel}: {why}. Nothing written, in any file")


def _replace(path: str, text: str) -> None:
    """`text` onto `path` via a temp file and os.replace, never truncating; the mode survives mkstemp's 0600."""
    handle, temp = tempfile.mkstemp(dir=os.path.dirname(path),
                                    prefix=".renovate-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.chmod(temp, stat.S_IMODE(os.stat(path).st_mode))
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def _audited(files: Mapping[str, PendingTarget]) -> list[str]:
    """Why each written file, read back off disk and re-parsed, is not what the plan claimed."""
    out = []
    for rel, target in files.items():
        why = renovate_audit.audit(target["syntax"], target["before"],
                                   "\n".join(_read_lines(target["path"])),
                                   target["groups"])
        if why:
            out.append(f"  {rel}: {why}")
    return out


def _put_back(files: Mapping[str, PendingTarget]) -> list[str]:
    """Restore bytes, mode and mtime (a fresh one fools make and cargo); returns what would not go back."""
    stuck = []
    for rel, target in files.items():
        try:
            _replace(target["path"], target["before"])
            was = target["stat"]
            os.utime(target["path"], ns=(was.st_atime_ns, was.st_mtime_ns))
        except OSError as exc:
            stuck.append(f"  {rel} could NOT be put back: {exc}")
    return stuck


def _refused(problems: list[str], files: Mapping[str, PendingTarget]) -> str:
    return "\n".join(
        [("the edit did not survive being read back by a real parser, so it "
          "was not the edit the report described:")] + problems
        + _put_back(files)
        + [("every file of this run is back at the bytes it had; nothing "
            "was written. This is the check that does not trust the "
            "locator -- see docs/dependency-updates.md"
            "#the-edit-is-audited-by-a-real-parser")])


def apply_edits(root: str, planpath: str) -> None:
    """Write the planned edits and audit them read back; a failed or raising audit puts every file back."""
    steps = cast(list[PlanEdit], load(planpath))
    files = _verify(steps, root)
    for e in steps:
        files[e["file"]]["lines"][e["line"]] = e["new"]
    for target in files.values():
        _replace(target["path"], "\n".join(target["lines"]))
    try:
        problems = _audited(files)
    except BaseException as exc:                   # noqa: BLE001 -- see above
        sys.exit(_refused(
            [f"  the audit itself raised {type(exc).__name__}: {exc}"],
            files))
    if problems:
        sys.exit(_refused(problems, files))
    for e in steps:
        print(f"  {e['file']}:{e['line'] + 1}  {e['new'].strip()}")


# Keyed by file name (npm has three formats); yarn.lock v1 has no stdlib parser, so it is deliberately absent.
LOCK_FORMATS = {
    "Cargo.lock": "toml", "uv.lock": "toml", "poetry.lock": "toml",
    "pdm.lock": "toml", "package-lock.json": "json",
    "pubspec.lock": "yaml", "pnpm-lock.yaml": "yaml",
}


def lock_readable(root: str, rel: str, dep: str) -> None:
    """Refuse a missing, empty or unparseable lockfile; only report whether it names `dep`."""
    path = contained(root, rel, "lockcheck")
    if not os.path.isfile(path):
        sys.exit(f"  {rel}: there is no lockfile at this path")
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    if not text.strip():
        sys.exit(f"  {rel}: the lockfile is EMPTY")
    kind = LOCK_FORMATS.get(os.path.basename(rel))
    if kind is None:
        print(f"  {rel}: present, {len(text)} bytes; no stdlib parser for this format, so "
              "'there and not empty' is the whole claim")
        return
    body = text.removeprefix(renovate_audit.BOM)
    try:
        renovate_audit.PARSERS[kind](body)
    except BaseException as exc:                   # noqa: BLE001 -- a parser
        # may raise anything; say what, never when, as renovate-locks.sh frames before/after itself.
        sys.exit("  {}: it does not read as {}: {}: {}".format(rel, kind, type(exc).__name__,
                    " ".join(str(exc).split())[:200]))
    if dep == LOCK_ALL:
        print(f"  {rel}: parses as {kind} (lock file maintenance: any entry may have moved)")
        return
    said = "names" if dep and dep in text else "does NOT name"
    print(f"  {rel}: parses as {kind}, and {said} {dep!r}")


def _print_config(log: str) -> None:
    cfg = resolved_config(log)
    if cfg is None:
        sys.exit(f"no --print-config record in {log}")
    json.dump(cfg, sys.stdout)


def _print_rows(path: str) -> None:
    for row in rows(load_report(path)):
        print("{}\t{}\t{}\t{}\t{}".format(
            row["manager"], row["file"], row["dep"],
            (row["curDigest"] or row["cur"])[:12],
            (row["newDigest"] or row["new"])[:12]))


def _print_skipped(path: str, root: str | None = None) -> None:
    listed, design = skipped(load_report(path), root)
    for row in listed:
        print("SKIP\t{}\t{}\t{}\t{}\t{}".format(*row))
    for why, n in sorted(design.items()):
        print(f"DESIGN\t{why}\t{n}")


def _print_lockmaint(report: str, cfg: str) -> None:
    for mgr, path in lock_maintenance(load_report(report), load_obj(cfg)):
        print(f"{mgr}\t{path}")


# A table, not an if-chain: every mode is one entry, so a new one adds no branch to main.
MODES = {
    "config": lambda a: _print_config(a[0]),
    "managers": lambda a: managers(load_obj(a[0]), a[1]),
    "rows": lambda a: _print_rows(a[0]),
    "skipped": lambda a: _print_skipped(a[0], a[1] if len(a) > 1 else None),
    "lockmaint": lambda a: _print_lockmaint(a[0], a[1]),
    "plan": lambda a: plan(load_report(a[0]), load_obj(a[1]), a[2], a[3]),
    "verify": lambda a: predict(_verify(cast(list[PlanEdit], load(a[1])), a[0])),
    "edit": lambda a: apply_edits(a[0], a[1]),
    "lockcheck": lambda a: lock_readable(a[0], a[1], a[2]),
}


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in MODES:
        sys.exit(f"unknown planner mode {mode!r}")
    MODES[mode](sys.argv[2:])

main()
