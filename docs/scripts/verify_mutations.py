#!/usr/bin/env python3
"""Prove that a gate's tests can actually fail.

The repeated failure this repo keeps finding is a check that looks green while
proving nothing. Reading a test cannot tell you which it is; only breaking the
thing it guards can. This session alone, EIGHT tests written to guard a fix
turned out to pass with the fix removed -- a window-grep that caught the wrong
`|| die`, a stub that bypassed the very extraction under test, an `if` wrapper
that suppressed the errexit it was meant to prove, a fixture whose short
definition came first.

Each entry in mutations.json names a file, a literal edit that NEUTERS one
guarantee, and the test command that must then FAIL. A mutation the tests survive
is reported: either the test is vacuous, or the mutation is not the guarantee you
thought it was. Both are worth knowing.

Runs from a pre-commit hook or CI: --only <id> for one entry, --changed to pick
the entries whose target is in the diff, plain for all.

See docs/code-quality-tooling.md.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutations.json")


def load(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    seen = set()
    for m in data:
        for key in ("id", "target", "find", "replace", "test", "why"):
            if key not in m:
                raise SystemExit("manifest entry missing %r: %r" % (key, m))
        if m["id"] in seen:
            raise SystemExit("duplicate mutation id: %s" % m["id"])
        seen.add(m["id"])
    return data


def changed_files():
    """Union of files committed since origin/main, staged, and edited in the tree."""
    touched = set()
    for cmd in (["git", "diff", "--name-only", "origin/main...HEAD"],
                ["git", "diff", "--cached", "--name-only"],
                ["git", "diff", "--name-only"]):
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if out.returncode == 0:
            touched |= set(out.stdout.split())
    return touched


def apply_and_run(entry, root):
    """Mutate, run the test, restore. Returns (applied, test_failed, detail)."""
    target = os.path.join(root, entry["target"])
    if not os.path.exists(target):
        return False, False, "target missing"
    with open(target, encoding="utf-8") as fh:
        original = fh.read()
    if entry["find"] not in original:
        return False, False, "find text not present -- the mutation is stale"
    mutated = original.replace(entry["find"], entry["replace"], 1)
    if mutated == original:
        return False, False, "replace is a no-op"

    backup = tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8")
    backup.write(original)
    backup.close()
    try:
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(mutated)
        proc = subprocess.run(entry["test"], shell=True, cwd=root,
                              capture_output=True, text=True, timeout=entry.get("timeout", 300))
        return True, proc.returncode != 0, "exit %d" % proc.returncode
    except subprocess.TimeoutExpired:
        return True, True, "test timed out (counts as failing)"
    finally:
        shutil.copyfile(backup.name, target)
        os.unlink(backup.name)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--root", default=ROOT,
                    help="resolve targets and run tests here (default: the repo)")
    ap.add_argument("--only", action="append", help="run just this mutation id (repeatable)")
    ap.add_argument("--changed", action="store_true",
                    help="only entries whose target appears in the current diff")
    args = ap.parse_args()

    entries = load(args.manifest)
    if args.only:
        entries = [e for e in entries if e["id"] in set(args.only)]
    if args.changed:
        touched = changed_files()
        entries = [e for e in entries if e["target"] in touched]

    print("=== mutation gate: can these tests fail? ===")
    if not entries:
        print("  nothing selected")
        return 0

    rc = 0
    for e in entries:
        applied, failed, detail = apply_and_run(e, args.root)
        if not applied:
            rc = 1
            sys.stderr.write("FAIL: %s -- %s (%s)\n" % (e["id"], detail, e["target"]))
        elif failed:
            print("  bites   %-34s %s" % (e["id"], e["why"]))
        else:
            rc = 1
            sys.stderr.write(
                "FAIL: %s SURVIVED -- the tests pass with this guarantee removed.\n"
                "      target: %s\n      test:   %s\n      meaning: %s\n"
                % (e["id"], e["target"], e["test"], e["why"]))
    if rc == 0:
        print("OK: every recorded mutation is caught by its tests")
    return rc


if __name__ == "__main__":
    sys.exit(main())
