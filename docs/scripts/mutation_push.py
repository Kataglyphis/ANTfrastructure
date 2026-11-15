"""A push's scope for the mutation gate: the files and recipes its ranges change, which entries need Chrome or pwsh, and the coverage line.

Does NOT cover a change that reaches a suite only through a file its command does not name, or a suite that starts
Chrome without the harness's markers: that suite runs here and its timeout fails the push.
See docs/code-quality-tooling.md#the-pre-push-hook
"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
from collections import Counter
from collections.abc import Callable, Iterable, Mapping, Sequence
from typing import TypeVar

E = TypeVar("E", bound=Mapping[str, object])
_CHROME_MARKER = re.compile(r"\bt_skip_unless_chrome\b|\bfindChrome\(")
# pwsh as its own word, bare or quoted in an argv list; a script named like test-pwsh.sh is not it.
_PWSH_WORD = re.compile(r"(?<![\w./-])pwsh(?![\w.-])")
_PWSH_MARKER = re.compile(r"\bt_skip_unless\b[^\n]*\bcommand -v pwsh\b")
NEEDS_CHROME = "needs Chrome"
NEEDS_PWSH = "needs pwsh, which this host lacks"
_RANGE = re.compile(r"[^\s.]+(?:\.[^\s.]+)*\.\.\.[^\s.]+(?:\.[^\s.]+)*")


def _git(root: str, *args: str) -> str:
    """git's stdout; a failure raises, because an empty diff would read as nothing to prove."""
    out = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise ValueError(f"git {' '.join(args)} failed: {out.stderr.strip() or out.returncode}")
    return out.stdout


def changed_files(root: str, base: str) -> set[str]:
    """Union of files committed since base, staged, and edited in the tree: --changed, the by-hand scope."""
    touched = set()
    for cmd in (["git", "diff", "--name-only", base + "...HEAD"],
                ["git", "diff", "--cached", "--name-only"],
                ["git", "diff", "--name-only"]):
        out = subprocess.run(cmd, cwd=root, capture_output=True, text=True, check=False)
        if out.returncode == 0:
            touched |= set(out.stdout.split())
    return touched


def touches(entry: Mapping[str, object], touched: Iterable[str]) -> bool:
    """By target or by test: a commit that only weakens a test touches no target."""
    return any(path == entry["target"] or path in str(entry["test"]) for path in touched)


def _changed_recipes(root: str, spec: str, manifest: str, entries: Sequence[E]) -> set[str]:
    """Ids of recipes added or edited in a range: a new recipe on old code touches neither target nor test."""
    base = _git(root, "merge-base", *spec.split("...", 1)).strip()
    known = {row["id"]: row for row in json.loads(_git(root, "show", f"{base}:{manifest}"))}
    return {str(e["id"]) for e in entries if known.get(e["id"]) != e}


def select_push(entries: Sequence[E], ranges: Sequence[str], root: str, manifest: str) -> list[E]:
    """The entries the committed <remote>...<local> ranges change; staged and edited files are not being pushed."""
    rel = os.path.relpath(manifest, root).replace(os.sep, "/")
    touched: set[str] = set()
    recipes: set[str] = set()
    for spec in ranges:
        if not _RANGE.fullmatch(spec):
            raise ValueError(f"--push-range takes <remote>...<local>, got {spec!r}")
        files = set(_git(root, "diff", "--name-only", "-z", spec).split("\0")) - {""}
        touched |= files
        if rel in files:
            recipes |= _changed_recipes(root, spec, rel, entries)
    return [e for e in entries if e["id"] in recipes or touches(e, touched)]


def _names_marked(test: str, root: str, marker: re.Pattern[str]) -> bool:
    """Whether a script the test command names carries the marker."""
    try:
        words = shlex.split(test)
    except ValueError:
        words = test.split()
    for word in words:
        path = os.path.join(root, word)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as fh:
                if marker.search(fh.read()):
                    return True
    return False


def needs_chrome(test: str, root: str) -> bool:
    """Whether a script the test command names asks for a real Chrome."""
    return _names_marked(test, root, _CHROME_MARKER)


def split_chrome(entries: Sequence[E], root: str) -> tuple[list[E], list[E]]:
    """(entries to prove here, entries CI proves), keeping manifest order."""
    verdict = {cmd: needs_chrome(cmd, root) for cmd in {str(e["test"]) for e in entries}}
    return ([e for e in entries if not verdict[str(e["test"])]],
            [e for e in entries if verdict[str(e["test"])]])


def needs_pwsh(test: str, root: str = ".") -> bool:
    """Whether the test command starts pwsh, or names a suite that requires it with t_skip_unless."""
    return bool(_PWSH_WORD.search(test)) or _names_marked(test, root, _PWSH_MARKER)


def host_has_pwsh() -> bool:
    """Whether pwsh is on PATH; recipes name harness suites only (test-mutation-pester-targets.sh), so Pester never matters."""
    return shutil.which("pwsh") is not None


def split_pwsh(entries: Sequence[E], root: str, pwsh_here: Callable[[], bool]) -> tuple[list[E], list[E]]:
    """(entries to prove here, pwsh entries CI proves); asks the host only when an entry needs pwsh."""
    verdict = {cmd: needs_pwsh(cmd, root) for cmd in {str(e["test"]) for e in entries}}
    wanting = [e for e in entries if verdict[str(e["test"])]]
    if not wanting or pwsh_here():
        return list(entries), []
    return [e for e in entries if not verdict[str(e["test"])]], wanting


def set_aside(entries: Sequence[E], root: str, refuse: Callable[[list[E]], tuple[list[E], int]],
              say: Callable[[str], None]) -> tuple[list[E], list[E], int]:
    """(entries to prove here, entries CI proves, refuse's code); pwsh ones leave before the parse check, which needs pwsh."""
    here, pwsh = split_pwsh(entries, root, host_has_pwsh)
    runnable, refused_rc = refuse(here)
    runnable, chrome = split_chrome(runnable, root)
    for line in delegated_lines(chrome, NEEDS_CHROME) + delegated_lines(pwsh, NEEDS_PWSH):
        say(line)
    return runnable, chrome + pwsh, refused_rc


def delegated_lines(delegated: Sequence[E], why: str = NEEDS_CHROME) -> list[str]:
    """One line per suite handed to CI, and the by-hand proof of the same entries."""
    if not delegated:
        return []
    counts = Counter(str(e["test"]) for e in delegated)
    lines = [f"  delegated {n} entr(ies) to CI, {why}: {cmd}" for cmd, n in sorted(counts.items())]
    lines.append('  by hand: bash linux/scripts/run-in-ci-image.sh "$PWD" -- python3 docs/scripts/verify_mutations.py '
                 + " ".join(f"--only {e['id']}" for e in delegated[:3])
                 + (" ..." if len(delegated) > 3 else ""))
    return lines


def coverage_line(proved: int, selected: int, delegated: int, skipped: int, total: int) -> str:
    """The run's real coverage; only proving every manifest entry may call itself whole."""
    if proved == total:
        return f"coverage: proved {proved} of {total}: the whole manifest"
    return (f"coverage: proved {proved} of {selected} selected; {delegated} delegated to CI, {skipped} skipped by this host; "
            f"the manifest holds {total}, and only a full run proves them all")
