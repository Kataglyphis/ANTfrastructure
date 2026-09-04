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
rather than dereferencing whatever they point at into it, and a symlink is
therefore refused as a mutation target -- writing through one would land outside
the copy. --in-place opts out (its own fixtures).

Runs from a pre-commit hook or CI: --only <id> for one entry, --changed to pick
the entries whose target is in the diff, plain for all.

See docs/code-quality-tooling.md#the-mutation-gate-mutations.
"""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutations.json")
COPY_EXCLUDES = (".git", "external", "out", "logs", "archive", "linux/webserver/dist",
                 # 1.5 GB, gitignored, read by no gate test -- and it was
                 # copied into every mirrored workspace, including the hook's.
                 "linux/llm-stack/ollama-binary.tar.zst",
                 "linux/llm-stack/benchmark-viewer/node_modules")


def _git_ignored(src):
    """Every path git ignores under src, or None when git cannot answer.

    Asked at the SOURCE, where .git still exists. The mirror is exactly the
    place where it will not, so this is the last moment the question can be
    put -- and the answer is what keeps a 1.5 GB gitignored tarball out of a
    3 GB tmpfs. A hand-kept list could not: COPY_EXCLUDES was only ever
    applied to directories, so a file listed there was still copied.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", src, "ls-files", "--others", "--ignored",
             "--exclude-standard", "--directory", "-z"],
            capture_output=True, text=True, timeout=120)
    except Exception:
        return None
    if proc.returncode != 0:
        return None
    out = set()
    for rel in proc.stdout.split("\0"):
        if rel:
            out.add(os.path.normpath(os.path.join(src, rel)))
    return out


def mirror_tree(src, dst):
    """Throwaway copy of src, minus what no gate test reads.

    Skips git-ignored paths (build output, caches, downloaded binaries) and
    the COPY_EXCLUDES fallback -- both as directories AND as files.

    A copy that fails is an error, never a shrug. This used to `except
    OSError: pass`; on a full tmpfs that produced 0-byte test files, pytest
    collected nothing, and every entry was reported as a vacuous bite -- a
    verdict about the tests that was really a verdict about disk space.
    """
    ignored = _git_ignored(src) or set()
    skip = {os.path.normpath(os.path.join(src, rel)) for rel in COPY_EXCLUDES} | {dst}
    skip |= ignored
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames if os.path.join(dirpath, d) not in skip]
        here = os.path.join(dst, os.path.relpath(dirpath, src))
        os.makedirs(here, exist_ok=True)
        for name in filenames:
            full = os.path.join(dirpath, name)
            if full in skip:
                continue
            try:
                shutil.copy2(full, os.path.join(here, name), follow_symlinks=False)
            except OSError as e:
                raise SystemExit(
                    "mirror_tree: could not copy %s: %s -- refusing to run the gate "
                    "on an incomplete copy (is the temp filesystem full?)" % (full, e))
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


def _run_test(cmd, root, timeout):
    """Run one test command; on timeout kill the WHOLE tree, not just the shell.

    subprocess.run(timeout=) kills only its direct child. A test that spawns a
    pytest which spawns a candidate left the grandchildren alive when the gate
    was interrupted -- one orphan burned CPU for twenty minutes beside the
    timing-sensitive tests of the next run. Own session, then kill the group.
    Returns (returncode, timed_out).
    """
    proc = subprocess.Popen(cmd, shell=True, cwd=root, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        proc.communicate(timeout=timeout)
        return proc.returncode, False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.kill()
        proc.communicate()
        return None, True


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
        rc, timed_out = _run_test(entry["test"], root, entry.get("timeout", 300))
        if timed_out:
            return True, True, "test timed out (counts as failing)"
        return True, rc != 0, "exit %d" % rc
    finally:
        shutil.copyfile(backup.name, target)
        os.unlink(backup.name)


def baseline_ok(entry, root, cache):
    """Does this entry's test pass UNMUTATED? Cached per command string."""
    cmd = entry["test"]
    if cmd not in cache:
        rc, timed_out = _run_test(cmd, root, entry.get("timeout", 300))
        cache[cmd] = (not timed_out) and rc == 0
    return cache[cmd]


def run_entries(args, entries):
    rc = 0
    baselines = {}
    for e in entries:
        if not baseline_ok(e, args.root, baselines):
            rc = 1
            sys.stderr.write(
                "FAIL: %s -- baseline test already fails unmutated (vacuous bite)\n"
                "      test:   %s\n" % (e["id"], e["test"]))
            continue
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
    args = ap.parse_args()

    entries = load(args.manifest)
    if args.only:
        entries = [e for e in entries if e["id"] in set(args.only)]
    if args.changed:
        touched = changed_files()
        # By target OR by the test the entry runs: a commit that only weakens
        # tests/test_x.py touched no target and selected nothing.
        entries = [e for e in entries
                   if e["target"] in touched or any(t in e["test"] for t in touched)]

    print("=== mutation gate: can these tests fail? ===")
    if not entries:
        print("  nothing selected")
        return 0
    if args.in_place:
        return run_entries(args, entries)
    workspace = tempfile.mkdtemp(prefix="mutation-gate-")
    try:
        mirror_tree(os.path.abspath(args.root), workspace)
        args.root = workspace
        return run_entries(args, entries)
    finally:
        shutil.rmtree(workspace, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
