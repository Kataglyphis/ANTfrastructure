#!/usr/bin/env python3
"""Prove a gate's tests can fail: apply each mutations.json edit in a throwaway copy and require its test to fail.

Each test command first runs once unmutated, since a bite recorded on a red suite proves nothing.
See docs/code-quality-tooling.md#the-mutation-gate-mutations
"""
import argparse
import atexit
import concurrent.futures
import json
import ntpath
import os
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from _thread import LockType
from collections import Counter
from collections.abc import Callable, Iterable, Iterator, Sequence
from types import FrameType
from typing import Never, NotRequired, TextIO, TypedDict

from mutation_parse import Edit, MissingParser, refusals
from mutation_shards import describe, load_costs, plan


class MutationEntry(TypedDict):
    id: str
    target: str
    find: str
    replace: str
    test: str
    why: str
    timeout: NotRequired[int]

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mutations.json")
COPY_EXCLUDES = (".git", "external", "out", "logs", "archive", "linux/webserver/dist",
                 # 1.5 GB, gitignored, read by no test, and otherwise copied into every mirror.
                 "linux/llm-stack/ollama-binary.tar.zst")
_IGNORED_CACHE: dict[str, set[str]] = {}
_IGNORED_LOCK = threading.Lock()
# The CPUs this process may use, so a runner pinned to 4 of a host's 32 gets 4.
DEFAULT_JOBS = (getattr(os, "process_cpu_count", None) or os.cpu_count)() or 1
# Git Bash may skip a suite (exit 77) or waive a case it cannot host; Linux, where CI runs, never may.
HOST_MAY_SKIP = os.name == "nt" or sys.platform.startswith(("cygwin", "msys"))
_HOST_SKIP = re.compile(r"^ *(?:SKIP \[|\d+ failed assertion\(s\) waived)", re.MULTILINE)


def host_skips(output: str) -> int:
    """SKIP lines and waiver counts in a run's output: the cases this host could not grade."""
    return len(_HOST_SKIP.findall(output))


def _git_ignored(src: str) -> set[str]:
    """Every path git ignores under src (empty when git cannot answer), asked at the source since mirrors have no .git."""
    with _IGNORED_LOCK:
        if src in _IGNORED_CACHE:
            return _IGNORED_CACHE[src]
    try:
        proc = subprocess.run(
            ["git", "-C", src, "ls-files", "--others", "--ignored",
             "--exclude-standard", "--directory", "-z"],
            capture_output=True, text=True, timeout=120, check=False)
        out = ({os.path.normpath(os.path.join(src, rel))
                for rel in proc.stdout.split("\0") if rel}
               if proc.returncode == 0 else set())
    except Exception:  # noqa: BLE001 -- no git, or it failed
        out = set()
    with _IGNORED_LOCK:
        _IGNORED_CACHE[src] = out
    return out


def within(root: str, path: str) -> bool:
    """Does path RESOLVE inside root? A link that leaves it must not be copied."""
    try:
        return os.path.commonpath([root, os.path.realpath(path)]) == root
    except ValueError:
        return False


def relative_file_path(path: str, label: str) -> str:
    """Require a portable relative file name without components that could leave a mirror."""
    if (not isinstance(path, str) or not path or "\\" in path
            or ntpath.splitdrive(path)[0]
            or any(part in ("", ".", "..") for part in path.split("/"))):
        raise ValueError(f"{label} must be a normalized relative path inside the mutation root")
    return path


def mirror_tree(src: str, dst: str) -> str:
    """Throwaway copy of src minus ignored and excluded paths; symlinks stay links, and a failed copy is fatal, never skipped."""
    skip = {os.path.normpath(os.path.join(src, rel)) for rel in COPY_EXCLUDES}
    skip |= {os.path.normpath(dst)} | _git_ignored(src)
    home = os.path.realpath(src)
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = [d for d in dirnames
                       if os.path.normpath(os.path.join(dirpath, d)) not in skip]
        here = os.path.join(dst, os.path.relpath(dirpath, src))
        os.makedirs(here, exist_ok=True)
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.normpath(path) in skip:
                continue
            if os.path.islink(path) and not within(home, path):
                continue
            try:
                shutil.copy2(path, os.path.join(here, name), follow_symlinks=False)
            except OSError as e:
                raise SystemExit(
                    f"mirror_tree: could not copy {path}: {e} -- refusing to run the gate "
                    "on an incomplete copy (is the temp filesystem full?)")
    return dst


def load(path: str) -> list[MutationEntry]:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    seen = set()
    for m in data:
        for key in ("id", "target", "find", "replace", "test", "why"):
            if key not in m:
                raise SystemExit(f"manifest entry missing {key!r}: {m!r}")
        relative_file_path(m["target"], f"mutation target for {m['id']}")
        if m["id"] in seen:
            raise SystemExit("duplicate mutation id: {}".format(m["id"]))
        seen.add(m["id"])
    return data


def changed_files(base: str = "origin/main") -> set[str]:
    """Union of files committed since base, staged, and edited in the tree."""
    touched = set()
    for cmd in (["git", "diff", "--name-only", base + "...HEAD"],
                ["git", "diff", "--cached", "--name-only"],
                ["git", "diff", "--name-only"]):
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
        if out.returncode == 0:
            touched |= set(out.stdout.split())
    return touched


_LIVE_GROUPS: set[int] = set()
_LIVE_LOCK = threading.Lock()


def _kill_group(pid: int, grace: float = 5.0) -> None:
    """End a test's session and its leftovers: SIGTERM lets a runner inside reap its own groups, SIGKILL follows the grace."""
    if hasattr(os, "killpg"):
        try:
            os.killpg(pid, signal.SIGTERM)
            deadline = time.monotonic() + grace
            while time.monotonic() < deadline:
                time.sleep(0.1)
                os.killpg(pid, 0)
            # Windows has no SIGKILL; this branch runs only where killpg exists.
            os.killpg(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    else:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, check=False)


def _kill_live_groups(*_: object) -> None:
    """On exit or SIGTERM/SIGINT/SIGHUP: a test session started with start_new_session never sees the gate die."""
    with _LIVE_LOCK:
        groups = list(_LIVE_GROUPS)
        _LIVE_GROUPS.clear()
    for pid in groups:
        _kill_group(pid)


def _exit_on_signal(signum: int, _frame: FrameType | None) -> Never:
    _kill_live_groups()
    sys.exit(128 + signum)


def _reap_when_test_exits(proc: subprocess.Popen[str], reap: Callable[[], None]) -> None:
    proc.wait()
    reap()


def _capture_text(data: bytes | str | None, encoding: str) -> str:
    if isinstance(data, bytes):
        return data.decode(encoding, errors="replace")
    return data or ""


def _timeout_result(
    proc: subprocess.Popen[str], expired: subprocess.TimeoutExpired,
    reap_once: Callable[[], None],
) -> tuple[int | None, bool, str]:
    leader_rc = proc.poll()
    out, err = expired.stdout, expired.stderr
    stderr_encoding = getattr(proc.stderr, "encoding", None) or "utf-8"
    stdout_encoding = getattr(proc.stdout, "encoding", None) or "utf-8"
    reap_once()
    if leader_rc is None and proc.poll() is None:
        proc.kill()
    try:
        final_out, final_err = proc.communicate(timeout=2)
    except subprocess.TimeoutExpired as cleanup_expired:
        final_out, final_err = cleanup_expired.stdout, cleanup_expired.stderr
        # A detached child can retain a pipe after the test leader has exited.
        for stream in (proc.stdout, proc.stderr):
            if stream is not None:
                stream.close()
    out = final_out or out
    err = final_err or err
    return leader_rc, True, (_capture_text(err, stderr_encoding)
                             + _capture_text(out, stdout_encoding))


def _run_test(cmd: str, root: str, timeout: float) -> tuple[int | None, bool, str]:
    """Run one test command, killing its whole process tree when it ends or times out; returns (returncode, timed_out, output)."""
    proc = subprocess.Popen(cmd, shell=True, cwd=root, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    with _LIVE_LOCK:
        _LIVE_GROUPS.add(proc.pid)
    reap_lock = threading.Lock()
    reaped = False

    def reap_once() -> None:
        nonlocal reaped
        with reap_lock:
            if not reaped:
                _kill_group(proc.pid)
                reaped = True

    watcher = None
    if hasattr(os, "killpg"):
        # A surviving child can keep a capture pipe open after the test exits.
        watcher = threading.Thread(target=_reap_when_test_exits, args=(proc, reap_once), daemon=True)
        watcher.start()
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, False, (err or "") + (out or "")
    except subprocess.TimeoutExpired as expired:
        return _timeout_result(proc, expired, reap_once)
    finally:
        if watcher is not None:
            reap_once()
            watcher.join()
        with _LIVE_LOCK:
            _LIVE_GROUPS.discard(proc.pid)


def _output_excerpt(output: str) -> str:
    lines = [line for line in output.strip().splitlines() if line.strip()]
    excerpt = lines if len(lines) <= 6 else lines[:3] + ["..."] + lines[-3:]
    return " | ".join(line[:500] for line in excerpt) or "<empty>"


def passes(cmd: str, root: str, timeout: float) -> tuple[bool | None, str | None]:
    """Run one test command unmutated; returns (ok, why), ok None for a host skip. A timeout is not a pass."""
    rc, timed_out, output = _run_test(cmd, root, timeout)
    if timed_out:
        leader = "still running" if rc is None else f"exited rc={rc}"
        return False, f"timed out after {timeout}s (a timeout is not a pass); leader {leader}; output excerpt: {_output_excerpt(output)}"
    if rc == 77 and HOST_MAY_SKIP:
        skip = [l.strip() for l in output.splitlines() if "SKIP [" in l][:1]
        return None, (skip or ["the suite exited 77"])[0]
    if rc != 0:
        return False, f"exited rc={rc}; output excerpt: {_output_excerpt(output)}"
    return True, None


class Baselines:
    """One unmutated run per distinct test command, shared by every shard."""

    def __init__(self) -> None:
        self._ok: dict[str, tuple[bool | None, str | None]] = {}
        self._guards: dict[str, LockType] = {}
        self._lock = threading.Lock()
        self.seconds: dict[str, float] = {}

    def ok(self, cmd: str, root: str, timeout: float) -> tuple[bool | None, str | None]:
        with self._lock:
            guard = self._guards.setdefault(cmd, threading.Lock())
        with guard:
            if cmd not in self._ok:
                start = time.monotonic()
                self._ok[cmd] = passes(cmd, root, timeout)
                self.seconds[cmd] = time.monotonic() - start
        return self._ok[cmd]


class Costs:
    """Seconds per test command, printed to stderr when its last selected entry ends: the input of the shard plan."""

    def __init__(self, entries: Iterable[MutationEntry], report: "Report") -> None:
        self._left = Counter(e["test"] for e in entries)
        self._count = dict(self._left)
        self._wall: dict[str, float] = {}
        self._lock = threading.Lock()
        self._report = report

    def done(self, cmd: str, seconds: float, baselines: Baselines) -> None:
        with self._lock:
            self._wall[cmd] = self._wall.get(cmd, 0.0) + seconds
            self._left[cmd] -= 1
            if self._left[cmd]:
                return
            base = baselines.seconds.get(cmd, 0.0)
            wall = self._wall[cmd] + base
        self._report.note(f"  cost    wall={wall:.2f}s baseline={base:.2f}s "
                          f"entries={self._count[cmd]} test={cmd}\n")


class Report:
    """Prints and flushes each verdict as it completes, so a run killed at its timeout still reports; summary() lists failures."""

    def __init__(self) -> None:
        self.failed: set[str] = set()
        self.skipped: set[str] = set()
        self._lock = threading.Lock()
        self._cur = threading.local()

    def shard(self, tag: str) -> None:
        self._cur.tag = tag

    def entry(self, key: str) -> None:
        self._cur.key = key
        self._cur.seconds = 0.0

    def spent(self, seconds: float) -> None:
        self._cur.seconds = seconds

    def taken(self) -> float:
        """Seconds the current entry's mutant ran; its baseline is counted once, by Costs."""
        return getattr(self._cur, "seconds", 0.0)

    def out(self, text: str) -> None:
        self._write(sys.stdout, text)

    def skip(self, text: str) -> None:
        self.skipped.add(self._cur.key)
        self._write(sys.stdout, text)

    def err(self, text: str) -> None:
        self.failed.add(self._cur.key)
        self._write(sys.stderr, text)

    def note(self, text: str) -> None:
        self._write(sys.stderr, text)

    def _write(self, stream: TextIO, text: str) -> None:
        with self._lock:
            stream.write(getattr(self._cur, "tag", "") + text)
            stream.flush()

    def summary(self, entries: Sequence[MutationEntry]) -> None:
        failed = [e["id"] for e in entries if e["id"] in self.failed]
        if failed:
            say(
                f"FAILED: {len(failed)} of {len(entries)} entr(ies), in manifest order: "
                f"{', '.join(failed)}"
            )


def say(text: str) -> None:
    """One line on stdout, flushed: see Report."""
    print(text, flush=True)


def read_exact(path: str) -> str:
    """A target's text as its bytes hold it: text mode on Windows reads CRLF as LF and writes LF back as CRLF."""
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8")


def write_exact(path: str, text: str) -> None:
    with open(path, "wb") as fh:
        fh.write(text.encode("utf-8"))


def applicable(entry: MutationEntry, root: str) -> tuple[str | None, str | None, str | None]:
    """(original, mutated, reason); mutated is None, with the reason, when the edit no longer applies."""
    target = os.path.join(root, entry["target"])
    if os.path.islink(target):
        return None, None, "target is a symlink -- a write through it escapes the copy"
    if not within(os.path.realpath(root), target):
        return None, None, "target resolves outside the mutation root"
    if not os.path.exists(target):
        return None, None, "target missing"
    original = read_exact(target)
    find, replace = entry["find"], entry["replace"]
    if "\r\n" in original:
        # core.autocrlf checks a target out as CRLF; the manifest's text is LF.
        find, replace = find.replace("\n", "\r\n"), replace.replace("\n", "\r\n")
    hits = original.count(find)
    if hits == 0:
        return original, None, "find text not present -- the mutation is stale"
    if hits > 1:
        return original, None, f"find text matches {hits} times -- ambiguous, name one edit"
    mutated = original.replace(find, replace, 1)
    if mutated == original:
        return original, None, "replace is a no-op"
    return original, mutated, None


def run_stale(entries: Iterable[MutationEntry], root: str) -> int:
    """Every recorded edit still applies, checked without running one test."""
    rc = 0
    for e in entries:
        _original, mutated, why = applicable(e, root)
        if mutated is None:
            rc = 1
            sys.stderr.write("FAIL: {} -- {} ({})\n".format(e["id"], why, e["target"]))
    return rc


def apply_and_run(entry: MutationEntry, root: str) -> tuple[bool, bool, str | None, int]:
    """Mutate, run the test, restore. Returns (applied, test_failed, detail, host_skips)."""
    target = os.path.join(root, entry["target"])
    original, mutated, why = applicable(entry, root)
    if mutated is None:
        return False, False, why, 0
    if original is None:
        raise RuntimeError("applicable returned mutated text without an original")

    with tempfile.NamedTemporaryFile("wb", delete=False) as backup:
        backup.write(original.encode("utf-8"))
    try:
        write_exact(target, mutated)
        rc, timed_out, output = _run_test(entry["test"], root, entry.get("timeout", 300))
        if timed_out:
            return True, True, "test timed out (counts as failing)", 0
        return True, rc != 0, f"exit {rc}", host_skips(output)
    finally:
        shutil.copyfile(backup.name, target)
        os.unlink(backup.name)


def baseline_ok(
    entry: MutationEntry, root: str, cache: Baselines,
) -> tuple[bool | None, str | None]:
    """Does this entry's test pass UNMUTATED? Cached per command string."""
    return cache.ok(entry["test"], root, entry.get("timeout", 300))


def prove(args: argparse.Namespace, e: MutationEntry, report: Report, baselines: Baselines) -> int:
    """One entry's verdict: baseline first, then the mutant; returns 1 when it fails the gate."""
    base_ok, base_why = baseline_ok(e, args.root, baselines)
    if base_ok is None:
        report.skip(f"  skip    {e['id']:<34} {base_why}\n")
        return 0
    if not base_ok:
        report.err(
            "FAIL: {} -- baseline test already fails unmutated (vacuous bite)\n"
            "      test:   {}\n"
            "      why:    {}\n".format(e["id"], e["test"], base_why))
        return 1
    start = time.monotonic()
    applied, failed, detail, now_skips = apply_and_run(e, args.root)
    report.spent(time.monotonic() - start)
    if not applied:
        report.err("FAIL: {} -- {} ({})\n".format(e["id"], detail, e["target"]))
        return 1
    if failed:
        report.out(f"  bites   {e['id']:<34} {e['why']}\n")
        return 0
    if HOST_MAY_SKIP and now_skips:
        report.skip(
            f"  skip    {e['id']:<34} survived where this host skips {now_skips} case(s) "
            "of its suite; Linux grades it\n"
        )
        return 0
    report.err(
        "FAIL: {} SURVIVED -- the tests pass with this guarantee removed.\n"
        "      target: {}\n      test:   {}\n      meaning: {}\n".format(e["id"], e["target"], e["test"], e["why"]))
    return 1


def run_entries(
    args: argparse.Namespace, entries: Iterable[MutationEntry], report: Report,
    baselines: Baselines | None = None, costs: Costs | None = None,
) -> int:
    rc = 0
    baselines = Baselines() if baselines is None else baselines
    for e in entries:
        report.entry(e["id"])
        rc = max(rc, prove(args, e, report, baselines))
        if costs is not None:
            costs.done(e["test"], report.taken(), baselines)
    return rc


def run_shard(
    args: argparse.Namespace, entries: Iterable[MutationEntry], root: str,
    report: Report, baselines: Baselines, tag: str = "", costs: Costs | None = None,
) -> int:
    local = argparse.Namespace(**vars(args))
    local.root = root
    report.shard(tag)
    return run_entries(local, entries, report, baselines, costs)


def tree_bytes(root: str) -> int:
    """Bytes under root, links not followed: what one more mirror of it costs."""
    total = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_size
            except OSError:
                pass
    return total


def mirror_cap(mirror_bytes: int, free_bytes: int) -> int:
    """Mirrors that fit a quarter of the temp filesystem's free space; on tmpfs that space is RAM a build may need."""
    return max(1, free_bytes // 4 // max(mirror_bytes, 1))


def setup_mirror(root: str, script: str | None) -> bool:
    """Install a consumer's test dependencies inside one disposable mirror before its baselines."""
    if not script:
        return True
    path = os.path.join(root, script)
    if (os.path.islink(path) or not within(os.path.realpath(root), path)
            or not os.path.isfile(path)):
        sys.stderr.write(f"FAIL: setup script is missing or leaves the mutation root: {script}\n")
        return False
    rc, timed_out, output = _run_test(f"bash -- {shlex.quote(script)}", root, 900)
    if timed_out or rc != 0:
        detail = "timed out after 900s" if timed_out else f"exited rc={rc}"
        sys.stderr.write(
            f"FAIL: setup script {script} {detail}; output excerpt: {_output_excerpt(output)}\n"
        )
        return False
    return True


def _drain(todo: queue.Queue[MutationEntry]) -> Iterator[MutationEntry]:
    """Entries off the shared queue until it is empty, so a mirror that is free takes the next one."""
    while True:
        try:
            yield todo.get_nowait()
        except queue.Empty:
            return


def run_shards(
    args: argparse.Namespace, entries: Sequence[MutationEntry], src: str, report: Report,
    costs: Costs | None = None,
) -> int:
    """--jobs mirrors draining one queue; each extra mirror is copied by its own shard, from src, which no shard mutates."""
    size = tree_bytes(args.root)
    cap = mirror_cap(size, shutil.disk_usage(args.root).free)
    jobs = max(1, min(args.jobs, len(entries), cap))
    if jobs < min(args.jobs, len(entries)):
        say(
            f"  --jobs {args.jobs} capped at {jobs}: mirrors of {size // 2**20} MB each "
            f"fit a quarter of the free space under {os.path.dirname(args.root)}"
        )
    todo: queue.Queue[MutationEntry] = queue.Queue()
    for e in entries:
        todo.put(e)
    extra = [tempfile.mkdtemp(prefix="mutation-gate-") for _ in range(jobs - 1)]
    baselines = Baselines()

    def shard(n: int, root: str) -> int:
        if n:
            mirror_tree(src, root)
            if not setup_mirror(root, args.setup_script):
                return 1
        return run_shard(args, _drain(todo), root, report, baselines, f"[{n + 1}/{jobs}] ", costs)

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
            done = [pool.submit(shard, n, root) for n, root in enumerate([args.root] + extra)]
            return max(f.result() for f in done)
    finally:
        for root in extra:
            shutil.rmtree(root, ignore_errors=True)


def parse_refusals(entries: Iterable[MutationEntry], root: str) -> dict[str, str]:
    """id -> why, for each applicable edit whose target parses and whose mutant does not."""
    edits = []
    for e in entries:
        original, mutated, _why = applicable(e, root)
        if original is not None and mutated is not None:
            edits.append(Edit(e["id"], e["target"], original, mutated))
    return refusals(edits)


def refuse_unparsable(
    entries: list[MutationEntry], root: str, report: Report,
) -> tuple[list[MutationEntry], int]:
    """The entries left to prove, and 1 when any was refused or a parser is missing."""
    try:
        refused = parse_refusals(entries, root)
    except MissingParser as exc:
        report.entry("")
        report.err(f"FAIL: {exc} -- a mutant that is never parsed cannot be trusted to bite\n")
        return [], 1
    for e in entries:
        if e["id"] in refused:
            report.entry(e["id"])
            report.err(f"FAIL: {e['id']} -- the mutant does not parse ({refused[e['id']]}); its bite would "
                       f"prove only the syntax error, so keep the edit valid ({e['target']})\n")
    return [e for e in entries if e["id"] not in refused], 1 if refused else 0


def select_only(
    entries: list[MutationEntry], only: list[str] | None, manifest: str,
) -> list[MutationEntry]:
    """The --only subset of exact ids, never globs; an unknown id exits 2 instead of selecting nothing."""
    if not only:
        return entries
    known = {e["id"] for e in entries}
    unknown = [o for o in only if o not in known]
    if unknown:
        sys.stderr.write(
            f"ERROR: --only names {len(unknown)} id(s) not in {manifest}: "
            f"{', '.join(sorted(unknown))}\n"
        )
        if any("*" in o or "?" in o for o in unknown):
            sys.stderr.write("       --only takes exact ids, not globs. Pass"
                             " each id explicitly, or use --changed.\n")
        sys.stderr.write(f"       {len(known)} id(s) are declared.\n")
        raise SystemExit(2)
    return [e for e in entries if e["id"] in set(only)]


def select_shard(
    entries: list[MutationEntry], spec: str | None, costs: str | None = None,
) -> list[MutationEntry]:
    """--shard K/N: entries[K::N] (K from 0), or shard K of the cost plan; a partition across N CI jobs; a bad spec exits 2."""
    if not spec:
        return entries
    try:
        k, n = (int(x) for x in spec.split("/"))
    except ValueError:
        k, n = -1, 0
    if not 0 <= k < n:
        sys.stderr.write(f"ERROR: --shard takes K/N with 0 <= K < N, got {spec!r}\n")
        raise SystemExit(2)
    if costs is None:
        return entries[k::n]
    table = load_costs(costs)
    say(describe(entries, table, k, n, costs))
    return plan(entries, table, n)[k]


def select(args: argparse.Namespace) -> list[MutationEntry]:
    """The entries this invocation proves: --only, then --changed, then --shard."""
    entries = select_only(load(args.manifest), args.only, args.manifest)
    if args.changed:
        touched = changed_files(args.base)
        # By target or by test: a commit that only weakens a test touches no target.
        entries = [e for e in entries
                   if e["target"] in touched or any(t in e["test"] for t in touched)]
    return select_shard(entries, args.shard, args.shard_costs)


def run_check_mode(args: argparse.Namespace, entries: list[MutationEntry], scope: str) -> int | None:
    """--stale-check or --parse-check, which run no test; None when neither was asked for."""
    if args.stale_check:
        say(f"=== mutation staleness: does every recorded edit still apply?{scope} ===")
        say(f"  {len(entries)} entr(ies), no test run")
        rc = run_stale(entries, args.root)
        if rc == 0:
            say("OK: every recorded mutation still applies to its target")
        return rc
    if args.parse_check:
        say(f"=== mutant parse check: does every selected mutant still parse?{scope} ===")
        _runnable, rc = refuse_unparsable(entries, args.root, Report())
        if rc == 0:
            say(f"OK: every selected mutant of a parsed target parses ({len(entries)} entr(ies), no test run)")
        return rc
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=MANIFEST)
    ap.add_argument("--root", default=ROOT,
                    help="resolve targets and run tests here (default: the repo)")
    ap.add_argument("--only", action="append", help="run just this mutation id (repeatable)")
    ap.add_argument("--changed", action="store_true",
                    help="only entries whose target appears in the current diff")
    ap.add_argument("--base", default="origin/main",
                    help="with --changed: the commits counted are those since this ref"
                         " (default: %(default)s; the pre-push hook passes the remote's tip)")
    ap.add_argument("--in-place", action="store_true",
                    help="mutate --root itself instead of a throwaway copy (fixtures only)")
    ap.add_argument("--setup-script",
                    help="run this relative Bash script once inside each disposable mirror")
    ap.add_argument("--jobs", type=int, default=DEFAULT_JOBS,
                    help="mutations to prove at once, one mirror each (default: %(default)s)")
    ap.add_argument("--stale-check", action="store_true",
                    help="only check that every selected edit still applies; run no test")
    ap.add_argument("--parse-check", action="store_true",
                    help="only check that every selected mutant still parses; run no test")
    ap.add_argument("--shard", metavar="K/N",
                    help="prove only entries[K::N] of the selection (K from 0): one of N CI jobs")
    ap.add_argument("--shard-costs", metavar="TABLE",
                    help="with --shard: take shard K of the plan built from this cost table instead")
    args = ap.parse_args()

    try:
        entries = select(args)
        if args.setup_script:
            relative_file_path(args.setup_script, "setup script")
    except ValueError as exc:
        sys.stderr.write(f"ERROR: {exc}\n")
        return 2
    if args.in_place and args.setup_script:
        sys.stderr.write("ERROR: --setup-script requires disposable mirrors; omit --in-place\n")
        return 2
    scope = f" (shard {args.shard}: {len(entries)} entr(ies))" if args.shard else ""
    checked = run_check_mode(args, entries, scope)
    if checked is not None:
        return checked

    say(f"=== mutation gate: can these tests fail?{scope} ===")
    if not entries:
        say("  nothing selected")
        return 0
    report = Report()
    runnable, refused_rc = refuse_unparsable(entries, args.root, report)
    costs = Costs(runnable, report)
    if args.in_place:
        rc = run_entries(args, runnable, report, costs=costs)
    else:
        src = os.path.abspath(args.root)
        workspace = tempfile.mkdtemp(prefix="mutation-gate-")
        try:
            mirror_tree(src, workspace)
            args.root = workspace
            rc = run_shards(args, runnable, src, report, costs) if setup_mirror(
                workspace, args.setup_script
            ) else 1
        finally:
            shutil.rmtree(workspace, ignore_errors=True)
    rc = max(rc, refused_rc)
    report.summary(entries)
    if rc == 0 and report.skipped:
        say(
            f"OK: every mutation this host can run is caught; {len(report.skipped)} "
            "skipped here (listed above), Linux proves them"
        )
    elif rc == 0:
        say("OK: every recorded mutation is caught by its tests")
    return rc


if __name__ == "__main__":
    atexit.register(_kill_live_groups)
    for _sig in ("SIGTERM", "SIGINT", "SIGHUP"):
        if hasattr(signal, _sig):
            signal.signal(getattr(signal, _sig), _exit_on_signal)
    sys.exit(main())
