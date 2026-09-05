#!/usr/bin/env python3
"""Ratchet `shellcheck -S warning` per (file, code) over exactly lint-shell.sh's file set.
lint-shell.sh gates at -S error; the 177 warnings in 74 files were watched by nothing.
Rows `file | SCxxxx | count | reason` in shellcheck-warnings.allow, four-way rule.
lint-shell.sh owns both the scope (--list-files) and the pinned binary (--print-bin).
docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings
"""
import argparse
import datetime
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quality_allow import check_counts, load_counts, load_rows  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ALLOW = os.path.join(HERE, "shellcheck-warnings.allow")
ALLOW_NAME = os.path.basename(ALLOW)
ALLOW_FMT = "<file> | SC<code> | <count> | <reason>"
LINT = os.path.join(HERE, "lint-shell.sh")
HEADER = (
    "# shellcheck -S warning findings frozen per (file, code) over lint-shell.sh's file set.",
    "# Format: %s   (the reason is the rest of the line)" % ALLOW_FMT,
    "# The four-way rule applies: a new pair, a higher count, an unrecorded lower count",
    "# and a row whose pair is gone all FAIL. Record a fix with --write-baseline [--files f].",
    "# docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings",
)


def _lint(*args):
    return subprocess.run(["bash", LINT, *args], cwd=ROOT, capture_output=True, text=True)


def scope():
    proc = _lint("--list-files")
    if proc.returncode != 0:
        sys.stderr.write("ERROR: `lint-shell.sh --list-files` failed:\n%s\n" % proc.stderr)
        raise SystemExit(2)
    return [line for line in proc.stdout.splitlines() if line]


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
    return out[-1].strip()


def warnings(shellcheck, files, only=None):
    counts = {}
    if not files:
        return counts
    proc = subprocess.run([shellcheck, "-x", "-f", "json1", "-S", "warning", *files],
                          cwd=ROOT, capture_output=True, text=True)
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


def _rel(path):
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


def write_baseline(counts, checked, partial):
    header, old = header_of(ALLOW), load_rows(ALLOW, 2, ALLOW_FMT)
    today = datetime.date.today().isoformat()
    keep = {k: v for k, v in old.items() if partial and k[0] not in checked}
    for key, n in counts.items():
        keep[key] = (n, old.get(key, (0, "baseline %s, not yet reviewed" % today))[1])
    with open(ALLOW, "w", encoding="utf-8") as fh:
        for line in header:
            fh.write(line + "\n")
        for (f, code), (n, reason) in sorted(keep.items()):
            fh.write("%s | %s | %d | %s\n" % (f, code, n, reason))
    print("wrote %d row(s) to %s" % (len(keep), ALLOW_NAME))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--files", nargs="+", metavar="FILE",
                    help="check only these files against their own baseline rows")
    ap.add_argument("--write-baseline", action="store_true",
                    help="freeze the current counts (existing reasons are kept)")
    args = ap.parse_args()

    shellcheck = binary()
    in_scope = scope()
    files, skipped, only = in_scope, set(), None
    frozen = load_counts(ALLOW, 2, ALLOW_FMT)
    if args.files:
        wanted = {_rel(f) for f in args.files}
        files = [f for f in in_scope if f in wanted]
        skipped = wanted - set(in_scope)
        only = set(files)
        frozen = {k: n for k, n in frozen.items() if k[0] in only}
    print("=== shellcheck warning ratchet (%d of %d file(s)) via shellcheck %s ==="
          % (len(files), len(in_scope), _version(shellcheck)))
    for f in sorted(skipped):
        print("  note: %s is outside the lint-shell.sh scope, skipped" % f)
    counts = warnings(shellcheck, files, only)
    if args.write_baseline:
        write_baseline(counts, set(files), bool(args.files))
        return 0
    rc = check_counts("warnings", sorted(counts.items()), frozen, 0, ALLOW_NAME, "findings")
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
