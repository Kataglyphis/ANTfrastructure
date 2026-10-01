#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""The apply half of renovate-local.sh: reads the report JSON and rewrites one value per edit.

See docs/dependency-updates.md#how-one-value-gets-rewritten

Subcommands (argv[1]); every line of output is tab-separated:
  config   <ndjson-log>                          the --print-config record
  managers <config.json> <ls-files.txt>          manager, default-enabled, file
  rows     <report.json>                         manager, file, dep, cur, new
  plan     <report> <config> <root> <plan.json>  the plan (+ the JSON edits)
  verify   <root> <plan.json>                    the pre-flight and predicted audit, writing nothing
  edit     <root> <plan.json>                    write, then audit the file or put it back
"""
import collections
import json
import os
import stat
import sys
import tempfile

import renovate_audit
import renovate_locator

# Other match keys are named in the output, never silently ignored (rule_hit).
FIELDS = {"matchManagers": "manager", "matchDatasources": "datasource",
          "matchDepNames": "dep", "matchPackageNames": "pkg",
          "matchFileNames": "file", "matchDepTypes": "depType",
          "matchUpdateTypes": "updateType"}
# Fills empty columns: under bash's IFS=tab an empty middle field collapses and shifts the rest.
DASH = "-"


def load(path):
    """Parsed JSON, or an exit naming the file rather than a json/decoder.py traceback."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        sys.exit("cannot read %s: %s" % (path, exc))
    except ValueError as exc:
        sys.exit("%s is not valid JSON: %s" % (path, exc))


def load_obj(path):
    """A JSON object; a list would parse and then die in a .get() that no longer names the file."""
    obj = load(path)
    if not isinstance(obj, dict):
        sys.exit("%s must be a JSON object, not %s" % (path, type(obj).__name__))
    return obj


def load_report(path):
    """A Renovate report; a wrong shape must fail, never read as "up to date"."""
    rep = load_obj(path)
    if not isinstance(rep.get("repositories"), dict):
        sys.exit('%s is not a Renovate report: no top-level "repositories" object'
                 % path)
    return rep


def in_root(root, rel):
    """`rel` resolved inside `root`, or None; `..`, absolute paths and symlinks out all fail alike."""
    if not rel:
        return None
    base = os.path.realpath(root)
    full = os.path.realpath(os.path.join(base, rel))
    return full if full.startswith(base + os.sep) else None


def contained(root, rel, source):
    """`rel` resolved inside `root`, or exit; called where a path enters, so no later use can forget."""
    full = in_root(root, rel)
    if full is None:
        sys.exit("%s names %r, which is not a file inside %s; nothing written"
                 % (source, rel, root))
    return full


def resolved_config(log):
    """The --print-config record, with `extends` presets already expanded by Renovate."""
    out = None
    with open(log, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if "resolved config" in (rec.get("msg") or "").lower():
                out = rec.get("config") or {}
    return out


def _first_match(pats, files):
    for pat in pats or []:
        rx = renovate_locator.renovate_pattern(pat)
        for f in files:
            if rx.search(f):
                return f
    return ""


def managers(cfg, listing):
    """Every manager whose own Renovate file patterns match a tracked file."""
    with open(listing, encoding="utf-8", errors="replace") as fh:
        files = [line.strip() for line in fh if line.strip()]
    for name in sorted(cfg):
        block = cfg[name]
        if not isinstance(block, dict) or not block.get("managerFilePatterns"):
            continue
        hit = _first_match(block["managerFilePatterns"], files)
        if hit:
            off = "false" if block.get("enabled") is False else "true"
            print("%s\t%s\t%s" % (name, off, hit))


def rows(report):
    """One dict per pending update; only a dep's first update, the rest being other bucket levels."""
    for repo in (report.get("repositories") or {}).values():
        for mgr, files in (repo.get("packageFiles") or {}).items():
            for f in files:
                for dep in f.get("deps") or []:
                    for up in dep.get("updates") or []:
                        yield _row(mgr, f, dep, up)
                        break


def _row(mgr, f, dep, up):
    return {"manager": mgr, "file": f.get("packageFile") or "",
            "dep": dep.get("depName") or dep.get("packageName") or "?",
            "pkg": dep.get("packageName") or dep.get("depName") or "",
            "datasource": dep.get("datasource") or f.get("datasource") or "",
            "depType": dep.get("depType") or "",
            "cur": dep.get("currentValue") or "",
            "new": up.get("newValue") or "",
            "curDigest": dep.get("currentDigest") or "",
            "newDigest": up.get("newDigest") or "",
            "updateType": up.get("updateType") or ""}


def _one(pat, val):
    neg = pat.startswith("!")
    if neg:
        pat = pat[1:]
    if pat.startswith("/") or "*" in pat or "?" in pat:
        hit = bool(renovate_locator.renovate_pattern(pat).search(val))
    else:
        hit = pat == val
    return hit != neg


def rule_hit(rule, row):
    """(matched, unevaluated keys); an unknown match* key counts as matching, the safe direction."""
    unknown = sorted(k for k in rule if k.startswith("match") and k not in FIELDS)
    for key, field in FIELDS.items():
        pats = rule.get(key)
        if pats and not any(_one(p, row.get(field) or "") for p in pats):
            return False, unknown
    return True, unknown


def refusal(row, rules):
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
        out = "packageRule #%d: %s" % (i + 1, why[:150])
        if unknown:
            out += " [unevaluated: %s; refused conservatively]" % ",".join(unknown)
    return out


def _clean(text):
    """One plan column, flattened: a tab would add a column and a newline a row."""
    return (text or DASH).replace("\t", " ").replace("\r", "") \
                         .replace("\n", " ") or DASH


def emit(kind, row, line, detail, before=DASH, after=DASH):
    """One plan row, ending in the line's exact text before and after, taken from the edit apply writes."""
    print("\t".join(_clean(str(col)) for col in (
        kind, row["manager"], row["file"], row["dep"],
        row["curDigest"][:12] or row["cur"], row["newDigest"][:12] or row["new"],
        line, detail, before, after)))


def _read_lines(path):
    """newline="" keeps a CRLF checkout CRLF."""
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read().split("\n")


def group_key(row):
    """One pin in one file; rows sharing it are occurrences the locator must find exactly."""
    return (row["file"], row["manager"], row["dep"],
            row["curDigest"] or row["cur"], row["newDigest"] or row["new"])


def plan_group(group, edits):
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
        emit("SKIP", row, DASH, "cannot read %s: %s" % (row["file"], exc))
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


def plan(report, cfg, root, planpath):
    rules = cfg.get("packageRules") or []
    edits = []
    groups = collections.OrderedDict()
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


def _writable(path, rel):
    """Probe that the file and its directory are writable; os.access says yes on a read-only mount."""
    try:
        with open(path, "r+", encoding="utf-8"):
            pass
    except OSError as exc:
        sys.exit("cannot write %s: %s; nothing written, in any file" % (rel, exc))
    try:
        handle, probe = tempfile.mkstemp(dir=os.path.dirname(path),
                                         prefix=".renovate-probe-")
    except OSError as exc:
        sys.exit("cannot write in the directory holding %s: %s; this tool "
                 "replaces a manifest through a temp file beside it so the "
                 "file is never left half-written, and that needs a writable "
                 "directory. Nothing written, in any file." % (rel, exc))
    os.close(handle)
    os.unlink(probe)


def _verify(steps, root):
    """Re-read, contain and prove writable every target before the first byte: the run writes all or nothing."""
    files, seen = {}, set()
    for e in steps:
        target = files.get(e["file"])
        if target is None:
            path = contained(root, e["file"], "the plan")
            try:
                # The stat lets _put_back() restore the times too.
                target = {"path": path, "lines": _read_lines(path),
                          "stat": os.stat(path), "steps": []}
            except OSError as exc:
                sys.exit("cannot read %s: %s; nothing written" % (e["file"], exc))
            _writable(path, e["file"])
            files[e["file"]] = target
        target["steps"].append(e)
        # The plan comes from the command line; a step missing any of these cannot be audited.
        blank = [k for k in ("manager", "dep", "cur", "next") if not e.get(k)]
        if blank:
            sys.exit("%s line %d is planned without %s, so the edit cannot be "
                     "checked against a parse of the file; nothing written, in "
                     "any file" % (e["file"], e["line"] + 1, ", ".join(blank)))
        # Two updates on one line is a planner bug; applying both would keep the last.
        if (e["file"], e["line"]) in seen:
            sys.exit("%s line %d is planned twice; nothing written, in any file"
                     % (e["file"], e["line"] + 1))
        seen.add((e["file"], e["line"]))
        if e["line"] >= len(target["lines"]) or target["lines"][e["line"]] != e["old"]:
            sys.exit("%s line %d moved since the plan; nothing written, in any file"
                     % (e["file"], e["line"] + 1))
    for rel, target in files.items():
        _sanction(rel, target)
    return files


def groups_of(steps):
    """(dep, old, new, lines planned) per pin: the count the locator was given, for the auditor to check."""
    counts = collections.OrderedDict()
    for e in steps:
        key = (e["dep"], e["cur"], e["next"])
        counts[key] = counts.get(key, 0) + 1
    return [key + (n,) for key, n in counts.items()]


def _manager_of(steps, rel):
    names = {e["manager"] for e in steps}
    if len(names) != 1:
        sys.exit("%s is planned under %d managers (%s); one file has one syntax, "
                 "so this plan cannot be audited. Nothing written, in any file"
                 % (rel, len(names), ", ".join(sorted(names))))
    return names.pop()


def _sanction(rel, target):
    """What a real parser lets this run change in one file; per file, so two groups claiming one value fail."""
    target["syntax"] = renovate_locator.syntax(_manager_of(target["steps"], rel), rel)
    target["before"] = "\n".join(target["lines"])
    target["groups"] = groups_of(target["steps"])
    _, _, why = renovate_audit.expected(
        target["syntax"], target["before"], target["groups"])
    if why:
        sys.exit("%s: %s. Nothing written, in any file" % (rel, why))


def _edited(target):
    """The exact text this plan would put on disk for one file."""
    lines = list(target["lines"])
    for e in target["steps"]:
        lines[e["line"]] = e["new"]
    return "\n".join(lines)


def predict(files):
    """The post-write audit over the text the write would produce; `edit` still proves the file off disk."""
    for rel, target in files.items():
        why = renovate_audit.audit(target["syntax"], target["before"],
                                   _edited(target), target["groups"])
        if why:
            sys.exit("%s: %s. Nothing written, in any file" % (rel, why))


def _replace(path, text):
    """`text` onto `path` via a temp file and os.replace, never truncating; the mode survives mkstemp's 0600."""
    handle, temp = tempfile.mkstemp(dir=os.path.dirname(path),
                                    prefix=".renovate-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        os.chmod(temp, stat.S_IMODE(os.stat(path).st_mode))
        os.replace(temp, path)
        temp = ""
    finally:
        if temp and os.path.exists(temp):
            os.unlink(temp)


def _audited(files):
    """Why each written file, read back off disk and re-parsed, is not what the plan claimed."""
    out = []
    for rel, target in files.items():
        why = renovate_audit.audit(target["syntax"], target["before"],
                                   "\n".join(_read_lines(target["path"])),
                                   target["groups"])
        if why:
            out.append("  %s: %s" % (rel, why))
    return out


def _put_back(files):
    """Restore bytes, mode and mtime (a fresh one fools make and cargo); returns what would not go back."""
    stuck = []
    for rel, target in files.items():
        try:
            _replace(target["path"], target["before"])
            was = target["stat"]
            os.utime(target["path"], ns=(was.st_atime_ns, was.st_mtime_ns))
        except OSError as exc:
            stuck.append("  %s could NOT be put back: %s" % (rel, exc))
    return stuck


def _refused(problems, files):
    return "\n".join(
        ["the edit did not survive being read back by a real parser, so it "
         "was not the edit the report described:"] + problems
        + _put_back(files)
        + ["every file of this run is back at the bytes it had; nothing "
           "was written. This is the check that does not trust the "
           "locator -- see docs/dependency-updates.md"
           "#the-edit-is-audited-by-a-real-parser"])


def apply_edits(root, planpath):
    """Write the planned edits and audit them read back; a failed or raising audit puts every file back."""
    steps = load(planpath)
    files = _verify(steps, root)
    for e in steps:
        files[e["file"]]["lines"][e["line"]] = e["new"]
    for target in files.values():
        _replace(target["path"], "\n".join(target["lines"]))
    try:
        problems = _audited(files)
    except BaseException as exc:                   # noqa: BLE001 -- see above
        sys.exit(_refused(
            ["  the audit itself raised %s: %s" % (type(exc).__name__, exc)],
            files))
    if problems:
        sys.exit(_refused(problems, files))
    for e in steps:
        print("  %s:%d  %s" % (e["file"], e["line"] + 1, e["new"].strip()))


# Keyed by file name (npm has three formats); yarn.lock v1 has no stdlib parser, so it is deliberately absent.
LOCK_FORMATS = {
    "Cargo.lock": "toml", "uv.lock": "toml", "poetry.lock": "toml",
    "pdm.lock": "toml", "package-lock.json": "json",
    "pubspec.lock": "yaml", "pnpm-lock.yaml": "yaml",
}


def lock_readable(root, rel, dep):
    """Refuse a missing, empty or unparseable lockfile; only report whether it names `dep`."""
    path = contained(root, rel, "lockcheck")
    if not os.path.isfile(path):
        sys.exit("  %s: there is no lockfile at this path" % rel)
    with open(path, encoding="utf-8", errors="replace", newline="") as fh:
        text = fh.read()
    if not text.strip():
        sys.exit("  %s: the lockfile is EMPTY" % rel)
    kind = LOCK_FORMATS.get(os.path.basename(rel))
    if kind is None:
        print("  %s: present, %d bytes; no stdlib parser for this format, so "
              "'there and not empty' is the whole claim" % (rel, len(text)))
        return
    body = text[len(renovate_audit.BOM):] if text.startswith(
        renovate_audit.BOM) else text
    try:
        renovate_audit.PARSERS[kind](body)
    except BaseException as exc:                   # noqa: BLE001 -- a parser
        # may raise anything; say what, never when, as renovate-locks.sh frames before/after itself.
        sys.exit("  %s: it does not read as %s: %s: %s"
                 % (rel, kind, type(exc).__name__,
                    " ".join(str(exc).split())[:200]))
    said = "names" if dep and dep in text else "does NOT name"
    print("  %s: parses as %s, and %s %r" % (rel, kind, said, dep))


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "config":
        cfg = resolved_config(sys.argv[2])
        if cfg is None:
            sys.exit("no --print-config record in %s" % sys.argv[2])
        json.dump(cfg, sys.stdout)
    elif mode == "managers":
        managers(load_obj(sys.argv[2]), sys.argv[3])
    elif mode == "rows":
        for row in rows(load_report(sys.argv[2])):
            print("%s\t%s\t%s\t%s\t%s" % (
                row["manager"], row["file"], row["dep"],
                (row["curDigest"] or row["cur"])[:12],
                (row["newDigest"] or row["new"])[:12]))
    elif mode == "plan":
        plan(load_report(sys.argv[2]), load_obj(sys.argv[3]), sys.argv[4], sys.argv[5])
    elif mode == "verify":
        predict(_verify(load(sys.argv[3]), sys.argv[2]))
    elif mode == "edit":
        apply_edits(sys.argv[2], sys.argv[3])
    elif mode == "lockcheck":
        lock_readable(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit("unknown planner mode %r" % mode)


main()
