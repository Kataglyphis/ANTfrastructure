#!/usr/bin/env python3
"""Ratchet `shellcheck -S warning` per (file, code) over lint-shell.sh's file set (shellcheck-warnings.allow).

docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_counts, load_counts, load_rows  # noqa: E402

import gate_scope  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ALLOW = os.path.join(HERE, "shellcheck-warnings.allow")
ALLOW_NAME = os.path.basename(ALLOW)
ALLOW_FMT = "<file> | SC<code> | <count> | <reason>"
LINT = os.path.join(HERE, "lint-shell.sh")
EXCLUDE = ("third_party",)
HEADER = (
    "# shellcheck -S warning findings frozen per (file, code) over lint-shell.sh's file set.",
    "# Format: %s   (the reason is the rest of the line)" % ALLOW_FMT,
    "# The four-way rule applies: a new pair, a higher count, an unrecorded lower count",
    "# and a row whose pair is gone all FAIL. Record a fix with --write-baseline [--files f].",
    "# docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings",
)


def _bash():
    # Windows searches System32 first, whose bash.exe is WSL's launcher and cannot read a C:\ path.
    return shutil.which("bash") or "bash"


def _native(path):
    # Under Git Bash, --print-bin answers in MSYS form (/tmp/...), which Windows cannot exec.
    if os.name == "nt" and path.startswith("/") and shutil.which("cygpath"):
        return subprocess.run(["cygpath", "-w", path], capture_output=True, text=True).stdout.strip() or path
    return path


def _lint(*args):
    # Anchored to this repo whatever the graded root: the shellcheck bootstrap and pins are the hub's.
    return subprocess.run([_bash(), LINT, *args], cwd=ROOT, capture_output=True, text=True)


def resolve(args):
    """(root, freeze file); a named root must be an existing git checkout, never silently this repo."""
    try:
        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    if root != ROOT:
        if not os.path.isdir(root):
            sys.stderr.write("ERROR: --root %s does not exist; refusing to grade "
                             "this repo instead of the tree you named.\n" % root)
            raise SystemExit(2)
        probe = subprocess.run(["git", "-C", root, "rev-parse", "--git-dir"],
                               capture_output=True, text=True)
        if probe.returncode:
            sys.stderr.write("ERROR: --root %s is not a git checkout; a consumer's "
                             "file set is read from git ls-files.\n" % root)
            raise SystemExit(2)
    return root, args.allow or (ALLOW if root == ROOT else os.path.join(root, ALLOW_NAME))


def _excluded(rel):
    """A vendored top-level DIRECTORY, so a file merely named third_party stays in."""
    head, _sep, rest = rel.partition("/")
    return bool(rest) and head in EXCLUDE


def scope(root):
    """lint-shell.sh's file set for `root`, minus EXCLUDE (a no-op for this repo, so applied always)."""
    proc = _lint("--list-files") if root == ROOT else _lint("--root", root, "--list-files")
    if proc.returncode != 0:
        sys.stderr.write("ERROR: `lint-shell.sh --list-files` failed for %s:\n%s\n"
                         % (root, proc.stderr))
        raise SystemExit(2)
    return [line for line in proc.stdout.splitlines() if line and not _excluded(line)]


def binary():
    override = os.environ.get("SHELLCHECK_BIN")
    if override:
        return override
    proc = _lint("--print-bin")
    out = [line for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or not out:
        sys.stderr.write("ERROR: `lint-shell.sh --print-bin` could not provide the pinned "
                         "shellcheck; set SHELLCHECK_BIN to a matching binary.\n%s\n" % proc.stderr)
        raise SystemExit(2)
    return _native(out[-1].strip())


def warnings(shellcheck, files, root, only=None):
    counts = {}
    if not files:
        return counts
    proc = subprocess.run([shellcheck, "-x", "-f", "json1", "-S", "warning", *files],
                          cwd=root, capture_output=True, text=True)
    try:
        comments = json.loads(proc.stdout)["comments"]
    except (ValueError, KeyError, TypeError):
        sys.stderr.write("ERROR: shellcheck exit %d, no json1 output:\n%s\n"
                         % (proc.returncode, proc.stderr))
        raise SystemExit(2)
    for c in comments:
        if c.get("level") != "warning" or (only is not None and c["file"] not in only):
            continue
        key = (c["file"], "SC%d" % c["code"])
        counts[key] = counts.get(key, 0) + 1
    return counts


def _rel(path, root=ROOT):
    """A --files argument relative to the graded root; under a consumer root a relative name is the consumer's."""
    if root != ROOT:
        return os.path.relpath(path if os.path.isabs(path)
                               else os.path.join(root, path), root)
    if os.path.isabs(path):
        return os.path.relpath(path, ROOT)
    if os.path.exists(os.path.join(ROOT, path)) or not os.path.exists(path):
        return os.path.normpath(path)
    return os.path.relpath(os.path.abspath(path), ROOT)


def header_of(path):
    """The comment block that opens the allow file, so --write-baseline keeps it."""
    if not os.path.exists(path):
        return list(HEADER)
    head = []
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        if line.strip() and not line.strip().startswith("#"):
            break
        head.append(line)
    return head


def write_baseline(counts, checked, partial, allow):
    header, old = header_of(allow), load_rows(allow, 2, ALLOW_FMT)
    today = datetime.date.today().isoformat()
    keep = {k: v for k, v in old.items() if partial and k[0] not in checked}
    for key, n in counts.items():
        keep[key] = (n, old.get(key, (0, "baseline %s, not yet reviewed" % today))[1])
    with open(allow, "w", encoding="utf-8") as fh:
        for line in header:
            fh.write(line + "\n")
        for (f, code), (n, reason) in sorted(keep.items()):
            fh.write("%s | %s | %d | %s\n" % (f, code, n, reason))
    print("wrote %d row(s) to %s" % (len(keep), os.path.basename(allow)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    ap.add_argument("--allow", default=None,
                    help="the freeze file (default: %s beside this script for this repo, "
                         "<root>/%s otherwise)" % (ALLOW_NAME, ALLOW_NAME))
    ap.add_argument("--files", nargs="+", metavar="FILE",
                    help="check only these files against their own baseline rows")
    ap.add_argument("--write-baseline", action="store_true",
                    help="freeze the current counts (existing reasons are kept)")
    args = ap.parse_args()

    root, allow = resolve(args)
    shellcheck = binary()
    in_scope = scope(root)
    files, skipped, only = in_scope, set(), None
    frozen = load_counts(allow, 2, ALLOW_FMT)
    if args.files:
        # _rel answers with the OS separator; lint-shell.sh's scope is always '/'.
        wanted = {_rel(f, root).replace(os.sep, "/") for f in args.files}
        files = [f for f in in_scope if f in wanted]
        skipped = wanted - set(in_scope)
        only = set(files)
        frozen = {k: n for k, n in frozen.items() if k[0] in only}
    print("=== shellcheck warning ratchet (%d of %d file(s)) via shellcheck %s ==="
          % (len(files), len(in_scope), _version(shellcheck)))
    if root != ROOT:
        print("  root: %s" % root)
        print("  allow: %s" % allow)
    for f in sorted(skipped):
        print("  note: %s is outside the lint-shell.sh scope, skipped" % f)
    counts = warnings(shellcheck, files, root, only)
    if args.write_baseline:
        write_baseline(counts, set(files), bool(args.files), allow)
        return 0
    rc = check_counts("warnings", sorted(counts.items()), frozen, 0,
                      os.path.basename(allow), "findings")
    if rc == 0:
        print("OK: shellcheck warnings match the baseline exactly")
    return rc


def _version(shellcheck):
    proc = subprocess.run([shellcheck, "--version"], capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip()
    return "?"


if __name__ == "__main__":
    sys.exit(main())
