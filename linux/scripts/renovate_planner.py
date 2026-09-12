#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""The half of renovate-local.sh that reads JSON and rewrites one value.

Renovate DETECTS and cannot write (--platform=local hard-forces dryRun), so the
apply half is ours. Everything that reads the report, matches a packageRule or
turns a located line into an edit lives here, in one module, so the plan a
--dry-run prints and the edit an --apply writes come from the same code and
cannot disagree. WHERE a value sits is not decided here at all -- that is
renovate_locator.py, which parses each manager's own syntax; this module only
groups the report's rows and asks it.

Two things this module owes the working tree, both bought with a measurement:

  * every path it touches is CONTAINED. A report's packageFile is JSON someone
    else wrote; an absolute one made --apply rewrite a file outside the
    checkout and exit 0. in_root() is the only way a path is built here, and it
    is called where a path ENTERS -- once over the report, once over the plan --
    so no later use can forget.
  * a run writes ALL of its files or NONE of them. Every target is re-read and
    proven writable before the first byte goes anywhere, and each file is then
    replaced through a temp file in its own directory. A plain open(path, "w")
    truncates first, so an error between the truncation and the write left no
    manifest at all.

renovate-local.sh is the only caller; the prose is
docs/dependency-updates.md#how-one-value-gets-rewritten.

Subcommands (argv[1]); every line of output is tab-separated:
  config   <ndjson-log>                          the --print-config record
  managers <config.json> <ls-files.txt>          manager, default-enabled, file
  rows     <report.json>                         manager, file, dep, cur, new
  plan     <report> <config> <root> <plan.json>  the plan (+ the JSON edits)
  verify   <root> <plan.json>                    the pre-flight, writing nothing
                                                 -- including the audit of the
                                                 text the write WOULD produce
  edit     <root> <plan.json>                    write the planned edits, then
                                                 audit the FILE, or put it back
"""
import collections
import fnmatch
import json
import os
import re
import stat
import sys
import tempfile

import renovate_audit
import renovate_locator

# The packageRule match keys this resolver evaluates. Anything else is named in
# the output rather than silently ignored -- see rule_hit().
FIELDS = {"matchManagers": "manager", "matchDatasources": "datasource",
          "matchDepNames": "dep", "matchPackageNames": "pkg",
          "matchFileNames": "file", "matchDepTypes": "depType",
          "matchUpdateTypes": "updateType"}
# The plan is 10 tab-separated columns wide. A "-" stands in for every empty
# one: bash reads these with IFS=tab, where tab is IFS WHITESPACE, so an empty
# field in the MIDDLE collapses and every column after it shifts left by one.
DASH = "-"


def load(path):
    """Parsed JSON, or a diagnostic naming the FILE and what is wrong with it.
    A traceback names json/decoder.py, which is never the file at fault, and the
    caller then repeats a guess: a malformed RENOVATE_LOCAL_CONFIG used to end
    as "no Renovate manager's file patterns match anything tracked"."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        sys.exit("cannot read %s: %s" % (path, exc))
    except ValueError as exc:
        sys.exit("%s is not valid JSON: %s" % (path, exc))


def load_obj(path):
    """A JSON *object*. A list or a bare string parses fine and then dies deep
    inside a .get(), where the message no longer names the file."""
    obj = load(path)
    if not isinstance(obj, dict):
        sys.exit("%s must be a JSON object, not %s" % (path, type(obj).__name__))
    return obj


def load_report(path):
    """A Renovate report. A file that parses but carries no `repositories`
    object is NOT "nothing to do": every consumer wrapper runs the report mode,
    and reading the wrong shape as "up to date" is a green run that graded
    nothing -- the one answer this tool must never give."""
    rep = load_obj(path)
    if not isinstance(rep.get("repositories"), dict):
        sys.exit('%s is not a Renovate report: no top-level "repositories" object'
                 % path)
    return rep


def in_root(root, rel):
    """The absolute path of `rel` inside `root`, or None when it is not inside.

    Every path this module writes to arrives as JSON someone else wrote -- a
    Renovate report, or a plan file named on the command line -- and nothing
    used to check that it stayed in the checkout: a report whose packageFile was
    ABSOLUTE made --apply rewrite a file outside the repository, at rc 0. Both
    sides are resolved, so `..`, an absolute path and a symlink pointing out of
    the tree are one question with one answer."""
    if not rel:
        return None
    base = os.path.realpath(root)
    full = os.path.realpath(os.path.join(base, rel))
    return full if full.startswith(base + os.sep) else None


def contained(root, rel, source):
    """`rel` resolved inside `root`, or the run ends here naming it. Called
    where a path ENTERS this module -- over the report in plan(), over the plan
    file in _verify() -- and never at a use, so that no later use can forget."""
    full = in_root(root, rel)
    if full is None:
        sys.exit("%s names %r, which is not a file inside %s; nothing written"
                 % (source, rel, root))
    return full


def resolved_config(log):
    """The one record --print-config writes, with `extends` presets ALREADY
    expanded by Renovate itself -- measured on 44.71.0, platform=local."""
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


def _compile(pat):
    """A Renovate matcher: /regex/ as written, anything else as a glob."""
    if len(pat) > 1 and pat.startswith("/") and pat.endswith("/"):
        return re.compile(pat[1:-1])
    return re.compile(fnmatch.translate(pat))


def _first_match(pats, files):
    for pat in pats or []:
        rx = _compile(pat)
        for f in files:
            if rx.search(f):
                return f
    return ""


def managers(cfg, listing):
    """Every manager whose OWN file patterns match a tracked file in this tree.
    The patterns come from Renovate, so this is detection, not a per-repo table."""
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
    """One flat dict per pending update. Only the FIRST update of a dep is taken:
    the rest are the same bump at other bucket levels. A dep that occurs twice in
    a file is TWO entries here, which is what lets the planner count them."""
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
        hit = bool(_compile(pat).search(val))
    else:
        hit = pat == val
    return hit != neg


def rule_hit(rule, row):
    """(matched, unevaluated keys). A match* key this resolver does not implement
    counts as MATCHING: over-refusing is the safe direction, and the key is
    printed with the refusal so nobody has to guess which way it went."""
    unknown = sorted(k for k in rule if k.startswith("match") and k not in FIELDS)
    for key, field in FIELDS.items():
        pats = rule.get(key)
        if pats and not any(_one(p, row.get(field) or "") for p in pats):
            return False, unknown
    return True, unknown


def refusal(row, rules):
    """The LAST dependencyDashboardApproval rule that matches decides, exactly as
    Renovate merges packageRules in order. Empty string = not refused."""
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
    """One plan column. A tab would add a column and a newline would add a ROW:
    the reader is `while IFS=$'\\t' read -r ...`, so a parser's own diagnostic --
    PyYAML writes four lines with a caret in them -- has to arrive flattened."""
    return (text or DASH).replace("\t", " ").replace("\r", "") \
                         .replace("\n", " ") or DASH


def emit(kind, row, line, detail, before=DASH, after=DASH):
    """One plan row: kind, manager, file, dep, cur, new, line, detail, and the
    line's exact text BEFORE and AFTER. The last two are what makes --dry-run
    reviewable without opening the file, and they come from the same edit the
    apply half writes -- there is no second rendering to drift."""
    print("\t".join(_clean(str(col)) for col in (
        kind, row["manager"], row["file"], row["dep"],
        row["curDigest"][:12] or row["cur"], row["newDigest"][:12] or row["new"],
        line, detail, before, after)))


def _read_lines(path):
    """newline="" keeps a CRLF checkout CRLF: this script edits one value, never
    a file's line endings."""
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read().split("\n")


def group_key(row):
    """One update of one dep from one value to one value, in one file. Two rows
    with the same key are two OCCURRENCES of the same pin -- a workflow that uses
    the same action in two steps, an extra that repeats a pin -- and the locator
    is told how many to expect."""
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
    kind, found, why = renovate_locator.resolve(
        row["manager"], lines, row["dep"], old, new, len(group))
    if kind == "REFUSE":
        emit("SKIP", row, DASH, why)
        return
    if kind == "DONE":
        emit("DONE", row, found[0].line + 1, why)
        return
    # The second opinion, and the one that does not read lines at all: a real
    # parser for this format says where the dep is declared and how many times.
    # It runs HERE so a group it will not sanction never reaches the plan --
    # --dry-run prints the reason, the other files of the run still apply, and
    # the pre-flight below is left holding an invariant rather than finding one.
    _, _, why = renovate_audit.expected(
        row["manager"], "\n".join(lines), [(row["dep"], old, new, len(group))])
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
        # The door: every packageFile in the report is resolved against the
        # checkout here, once, before anything downstream can use it.
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
    """Prove this run can replace `path` before it replaces anything.

    Two permissions, because the write below needs both: the FILE, opened for
    update without truncating it, and the DIRECTORY, which has to take a temp
    file and a rename. A probe rather than os.access, which answers about the
    caller's uid rather than about the filesystem and says yes on a read-only
    mount."""
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
    """Every planned line re-read, contained and proven writable BEFORE the
    first byte is written, so a plan that cannot fully apply aborts with nothing
    written at all. Per-FILE was not per-RUN: the guard used to stop at the
    offending file with the earlier files of the same plan already rewritten,
    and it never asked whether a target could be written to -- two files in one
    plan, the second read-only, left the first rewritten and a PermissionError
    traceback in the terminal."""
    files, seen = {}, set()
    for e in steps:
        target = files.get(e["file"])
        if target is None:
            path = contained(root, e["file"], "the plan")
            try:
                # The stat is taken with the bytes, and for the same reason: it
                # is what "back at the bytes it had" means for the TIMES. See
                # _put_back().
                target = {"path": path, "lines": _read_lines(path),
                          "stat": os.stat(path), "steps": []}
            except OSError as exc:
                sys.exit("cannot read %s: %s; nothing written" % (e["file"], exc))
            _writable(path, e["file"])
            files[e["file"]] = target
        target["steps"].append(e)
        # A plan step says which value moves where. The plan file is named on
        # the command line, so a step that omits any of that is a plan this
        # tool cannot audit -- and an unauditable step is never written.
        blank = [k for k in ("manager", "dep", "cur", "next") if not e.get(k)]
        if blank:
            sys.exit("%s line %d is planned without %s, so the edit cannot be "
                     "checked against a parse of the file; nothing written, in "
                     "any file" % (e["file"], e["line"] + 1, ", ".join(blank)))
        # Two updates planned onto ONE line is a planner bug, and applying both
        # would keep whichever came last.
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
    """The report's pins, recovered from the plan: (dep, old, new) -> how many
    lines this plan writes for it. That count is the same one the locator was
    given, so the auditor asks the parsed document the same question the
    locator was asked of the text -- and can disagree with the answer."""
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
    """What this run is ALLOWED to change in one file, worked out by a real
    parser before a byte is written.

    plan_group() has already asked this per group; asking again per FILE is what
    catches a pair of groups that separately look fine and together claim one
    value, and it is what makes the invariant hold over the plan file itself --
    which arrives from the command line and need not have come from plan()."""
    target["manager"] = _manager_of(target["steps"], rel)
    target["before"] = "\n".join(target["lines"])
    target["groups"] = groups_of(target["steps"])
    _, _, why = renovate_audit.expected(
        target["manager"], target["before"], target["groups"])
    if why:
        sys.exit("%s: %s. Nothing written, in any file" % (rel, why))


def _edited(target):
    """The exact text this plan would put on disk for one file."""
    lines = list(target["lines"])
    for e in target["steps"]:
        lines[e["line"]] = e["new"]
    return "\n".join(lines)


def predict(files):
    """The post-write audit, run over the text the write WOULD produce.

    The `verify` subcommand is the pre-flight -- what --dry-run prints and what
    --apply runs before it writes -- and until 2026-09-10 it stopped one step
    short. It asked what the edit was ALLOWED to change; it never asked what the
    edit WOULD change. So a `newValue` carrying a quote printed a clean plan at
    rc 0 under --dry-run and was refused by --apply after the write, and
    print_dry_run's claim to show "the exact writes this would make" was false
    about the only thing a reviewer would have wanted warned about.

    Deliberately NOT run by the `edit` subcommand. A simulation proves a string;
    the check `edit` runs proves the FILE, read back off disk, which is the only
    reading that can catch a write that landed somewhere else. Folding the two
    into one would leave the stronger check unexercised, so each entry point
    keeps its own: `verify` predicts, `edit` proves."""
    for rel, target in files.items():
        why = renovate_audit.audit(target["manager"], target["before"],
                                   _edited(target), target["groups"])
        if why:
            sys.exit("%s: %s. Nothing written, in any file" % (rel, why))


def _replace(path, text):
    """`text` onto `path`, through a temp file in the same directory.

    open(path, "w") TRUNCATES first, so an interrupt or an error between the
    truncation and the write leaves no manifest at all -- the one outcome worse
    than a wrong edit. os.replace() is one step: the file is the old bytes or
    the new ones, never a prefix of either. The mode is carried over because
    mkstemp creates 0600, and the line endings are already in `text`, which is
    why nothing here re-derives them."""
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
    """Every file this run just wrote, read back OFF DISK and parsed again, with
    the reason each one is not what the plan claimed.

    Off disk rather than out of the string that was written: a check over the
    value in hand proves the string, and what has to be proven is the FILE. It
    is also the only reading that can catch a _replace() that wrote somewhere
    else, and it costs one open."""
    out = []
    for rel, target in files.items():
        why = renovate_audit.audit(target["manager"], target["before"],
                                   "\n".join(_read_lines(target["path"])),
                                   target["groups"])
        if why:
            out.append("  %s: %s" % (rel, why))
    return out


def _put_back(files):
    """Every written file back to the bytes, the mode AND the times it had, and
    the ones that would not go back.

    A file left rewritten after a refusal is the outcome this whole module is
    arranged against, so a failure here is NAMED rather than raised past:
    renovate-local.sh keeps a copy of each target beside the run and says where
    it is.

    The mtime is part of "back", and it is restored HERE because here is where
    the contract is. Until 2026-09-10 it was not: driving `renovate_planner.py
    edit` restored the bytes and the mode and stamped the file with now, and the
    preservation anyone saw through renovate-local.sh came from that script's
    own `cp -p` copies. A rolled-back manifest carrying a fresh mtime is a file
    every timestamp-driven tool downstream believes changed -- make, ninja,
    cargo, a watcher -- over an edit that was undone."""
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
    """Write the planned edits, then prove they were the planned edits.

    _verify has already proven every target readable, contained, unmoved,
    WRITABLE and -- by a real parser -- declaring the reported dependency at
    exactly the places the report accounts for. What is left of "an I/O failure
    partway through" is a file that is either fully written or untouched.

    What is left after THAT is the locator being wrong, and no amount of
    pre-flight can rule that out: the pre-flight asks the parser where the value
    is, the locator separately picks a line, and nothing so far has compared the
    two. So the files are read back and parsed AGAIN, and the audit is what
    decides. Exactly the sanctioned paths moved, each to exactly the reported
    new value, and nothing else in the document differs -- or every file of the
    run goes back to the bytes it had and the run fails.

    And the rollback does not depend on the audit finishing. renovate_audit.py
    turns its own failures into refusals, but this `except` is here because a
    guarantee resting on the auditor's correctness is the guarantee the auditor
    was written to replace: a hostile newValue nesting 1200 arrays deep made the
    audit raise, the exception went past this function, and the bad write STAYED
    on disk at rc 1 (measured 2026-09-10). Any exception now takes the same road
    an audit FAILURE does -- every file back, and a message naming what raised."""
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


# Which real parser reads which LOCKFILE. Keyed by file NAME, not by manager,
# because npm is one manager with three lockfiles in three formats -- the same
# reason renovate-locks.sh keys its refresh command by tool rather than manager.
#
# yarn.lock is deliberately absent, and is not a hole waiting to be filled: v1
# is a bespoke format that is not YAML and has no stdlib parser. What can be
# said about it is that it is there and not empty, and lock_readable() says
# exactly that rather than implying more.
LOCK_FORMATS = {
    "Cargo.lock": "toml", "uv.lock": "toml", "poetry.lock": "toml",
    "pdm.lock": "toml", "package-lock.json": "json",
    "pubspec.lock": "yaml", "pnpm-lock.yaml": "yaml",
}


def lock_readable(root, rel, dep):
    """What can honestly be checked about a lockfile once its tool rewrote it.

    A manifest gets a value-by-value audit: parse before, parse after, exactly
    one leaf may differ. A lockfile cannot get that, and pretending otherwise
    would be the more dishonest of the two options -- one constraint bump
    rewrote 204 lines of OmniAccelerANT's pubspec.lock -- 46 resolved versions
    across 48 packages, read off the commit that landed it -- and every one of
    them is the tool doing its job.

    So the claim is narrower, and it is PRINTED rather than implied.
    REFUSED: the file is gone, or empty, or no longer parses -- a tool killed
    mid-write leaves a truncated lock, and a truncated lock beside a moved
    manifest is exactly the half-applied tree the rollback exists to prevent.
    REPORTED and never a refusal: whether `dep` is NAMED anywhere in it. A
    missing name is usually wrong and occasionally right (an optional or
    platform-gated dependency need not resolve on this host), so it goes to a
    human instead of becoming a verdict this module cannot justify."""
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
        # handed a file this tool did not write may raise anything at all, and
        # letting it past would take the rollback with it. Same rule as
        # renovate_audit.parse().
        # The message deliberately says only WHAT it found, never WHEN. The same
        # reading is taken twice -- before the run and after it -- and the two
        # mean opposite things ("the tree was already broken" vs "the tool broke
        # it"). renovate-locks.sh supplies that framing at each call site, so a
        # message carrying its own would be wrong at one of them.
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
