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

Each distinct test command is also run ONCE unmutated first: a bite recorded
while the suite was already red proves nothing.

Every mutation runs in a throwaway COPY of the tree, never in the tree it was
pointed at: this repo builds from its own working directory, so an in-place edit
could be snapshotted into a shipped image. The copy keeps symlinks AS symlinks
rather than dereferencing whatever they point at into it, drops the ones that
resolve outside the tree, and a symlink is therefore refused as a mutation target
-- writing through one would land outside the copy. --in-place opts out (its own
fixtures).

Every mutation is still proven on its own, but --jobs of them run at once, each
shard in its own mirror; the report is reassembled in manifest order.

Runs from a pre-commit hook or CI: --only <id> for one entry, --changed to pick
the entries whose target is in the diff, plain for all.

See docs/code-quality-tooling.md#the-mutation-gate-mutations.
"""
import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutations.json")
COPY_EXCLUDES = (".git", "external", "out", "logs", "archive", "linux/webserver/dist")
DEFAULT_JOBS = min(8, os.cpu_count() or 1)


def within(root, path):
    """Does path RESOLVE inside root? A link that leaves it must not be copied."""
    try:
        return os.path.commonpath([root, os.path.realpath(path)]) == root
    except ValueError:
        return False


def mirror_tree(src, dst):
    """Cheap throwaway copy of src, minus the trees no gate test reads."""
    skip = {os.path.join(src, rel) for rel in COPY_EXCLUDES} | {dst}
    home = os.path.realpath(src)
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames if os.path.join(dirpath, d) not in skip]
        here = os.path.join(dst, os.path.relpath(dirpath, src))
        os.makedirs(here, exist_ok=True)
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) and not within(home, path):
                continue
            try:
                shutil.copy2(path, os.path.join(here, name),
                             follow_symlinks=False)
            except OSError:
                pass
    return dst


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


def passes(cmd, root, timeout):
    """Run one test command unmutated; a timeout is not a pass."""
    try:
        proc = subprocess.run(cmd, shell=True, cwd=root, capture_output=True,
                              text=True, timeout=timeout)
        return proc.returncode == 0
    except subprocess.TimeoutExpired:
        return False


class Baselines:
    """One unmutated run per distinct test command, shared by every shard."""

    def __init__(self):
        self._ok = {}
        self._guards = {}
        self._lock = threading.Lock()

    def ok(self, cmd, root, timeout):
        with self._lock:
            guard = self._guards.setdefault(cmd, threading.Lock())
        with guard:
            if cmd not in self._ok:
                self._ok[cmd] = passes(cmd, root, timeout)
        return self._ok[cmd]


class Report:
    """Per-entry output buffer, so shards that finish out of order still read in
    manifest order."""

    def __init__(self):
        self.lines = {}
        self._cur = threading.local()

    def entry(self, key):
        self._cur.key = key
        self.lines[key] = []

    def out(self, text):
        self.lines[self._cur.key].append((sys.stdout, text))

    def err(self, text):
        self.lines[self._cur.key].append((sys.stderr, text))

    def flush(self, entries):
        for e in entries:
            for stream, text in self.lines.get(e["id"], ()):
                stream.write(text)


def apply_and_run(entry, root):
    """Mutate, run the test, restore. Returns (applied, test_failed, detail)."""
    target = os.path.join(root, entry["target"])
    if os.path.islink(target):
        return False, False, "target is a symlink -- a write through it escapes the copy"
    if not os.path.exists(target):
        return False, False, "target missing"
    with open(target, encoding="utf-8") as fh:
        original = fh.read()
    hits = original.count(entry["find"])
    if hits == 0:
        return False, False, "find text not present -- the mutation is stale"
    if hits > 1:
        return False, False, "find text matches %d times -- ambiguous, name one edit" % hits
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


def baseline_ok(entry, root, cache):
    """Does this entry's test pass UNMUTATED? Cached per command string."""
    return cache.ok(entry["test"], root, entry.get("timeout", 300))


def run_entries(args, entries, report, baselines=None):
    rc = 0
    baselines = Baselines() if baselines is None else baselines
    for e in entries:
        report.entry(e["id"])
        if not baseline_ok(e, args.root, baselines):
            rc = 1
            report.err(
                "FAIL: %s -- baseline test already fails unmutated (vacuous bite)\n"
                "      test:   %s\n" % (e["id"], e["test"]))
            continue
        applied, failed, detail = apply_and_run(e, args.root)
        if not applied:
            rc = 1
            report.err("FAIL: %s -- %s (%s)\n" % (e["id"], detail, e["target"]))
        elif failed:
            report.out("  bites   %-34s %s\n" % (e["id"], e["why"]))
        else:
            rc = 1
            report.err(
                "FAIL: %s SURVIVED -- the tests pass with this guarantee removed.\n"
                "      target: %s\n      test:   %s\n      meaning: %s\n"
                % (e["id"], e["target"], e["test"], e["why"]))
    return rc


def run_shard(args, entries, root, src, report, baselines):
    if root != args.root:
        mirror_tree(src, root)
    local = argparse.Namespace(**vars(args))
    local.root = root
    return run_entries(local, entries, report, baselines)


def run_shards(args, entries, src, report):
    """Deal the entries round-robin over --jobs mirrors and run the shards at once."""
    jobs = max(1, min(args.jobs, len(entries)))
    shards = [entries[n::jobs] for n in range(jobs)]
    extra = [tempfile.mkdtemp(prefix="mutation-gate-") for _ in shards[1:]]
    baselines = Baselines()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            done = [pool.submit(run_shard, args, shard, root, src, report, baselines)
                    for shard, root in zip(shards, [args.root] + extra)]
            return max(f.result() for f in done)
    finally:
        for root in extra:
            shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--root", default=ROOT,
                    help="resolve targets and run tests here (default: the repo)")
    ap.add_argument("--only", action="append", help="run just this mutation id (repeatable)")
    ap.add_argument("--changed", action="store_true",
                    help="only entries whose target appears in the current diff")
    ap.add_argument("--in-place", action="store_true",
                    help="mutate --root itself instead of a throwaway copy (fixtures only)")
    ap.add_argument("--jobs", type=int, default=DEFAULT_JOBS,
                    help="mutations to prove at once, one mirror each (default: %(default)s)")
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
    report = Report()
    if args.in_place:
        rc = run_entries(args, entries, report)
    else:
        src = os.path.abspath(args.root)
        workspace = tempfile.mkdtemp(prefix="mutation-gate-")
        try:
            mirror_tree(src, workspace)
            args.root = workspace
            rc = run_shards(args, entries, src, report)
        finally:
            shutil.rmtree(workspace, ignore_errors=True)
    report.flush(entries)
    if rc == 0:
        print("OK: every recorded mutation is caught by its tests")
    return rc


if __name__ == "__main__":
    sys.exit(main())
