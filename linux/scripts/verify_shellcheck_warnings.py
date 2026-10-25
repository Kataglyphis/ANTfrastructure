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
import gate_scope
from quality_allow import check_counts, load_counts, load_rows

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ALLOW = os.path.join(HERE, "shellcheck-warnings.allow")
ALLOW_NAME = os.path.basename(ALLOW)
ALLOW_FMT = "<file> | SC<code> | <count> | <reason>"
LINT = os.path.join(HERE, "lint-shell.sh")
EXCLUDE = ("third_party",)
SHELLCHECK_ARGUMENT_LIMIT = 24000
SHELLCHECK_ARGUMENTS = ("-x", "-f", "json1", "-S", "warning")
HEADER = (
    "# shellcheck -S warning findings frozen per (file, code) over lint-shell.sh's file set.",
    f"# Format: {ALLOW_FMT}   (the reason is the rest of the line)",
    "# The four-way rule applies: a new pair, a higher count, an unrecorded lower count",
    "# and a row whose pair is gone all FAIL. Record a fix with --write-baseline [--files f].",
    "# docs/code-quality-tooling.md#shellcheck-warning-ratchet-shellcheck-warnings",
)


def _bash() -> str:
    # Windows searches System32 first, whose bash.exe is WSL's launcher and cannot read a C:\ path.
    return shutil.which("bash") or "bash"


def _native(path: str) -> str:
    # Under Git Bash, --print-bin answers in MSYS form (/tmp/...), which Windows cannot exec.
    if os.name == "nt" and path.startswith("/") and shutil.which("cygpath"):
        return (
            subprocess.run(
                ["cygpath", "-w", path], capture_output=True, text=True, check=False
            ).stdout.strip()
            or path
        )
    return path


def _lint(*args: str) -> subprocess.CompletedProcess[str]:
    # Anchored to this repo whatever the graded root: the shellcheck bootstrap and pins are the hub's.
    return subprocess.run(
        [_bash(), LINT, *args], cwd=ROOT, capture_output=True, text=True, check=False
    )


def resolve(args: argparse.Namespace) -> tuple[str, str]:
    """(root, freeze file); a named root must be an existing git checkout, never silently this repo."""
    try:
        # resolve_root, not abspath: a subdirectory root would silently shift every allowlist key.
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        raise SystemExit(gate_scope.die(exc)) from exc
    if root != ROOT:
        if not os.path.isdir(root):
            sys.stderr.write(
                f"ERROR: --root {root} does not exist; refusing to grade "
                "this repo instead of the tree you named.\n"
            )
            raise SystemExit(2)
        probe = subprocess.run(
            ["git", "-C", root, "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            check=False,
        )
        if probe.returncode:
            sys.stderr.write(
                f"ERROR: --root {root} is not a git checkout; a consumer's "
                "file set is read from git ls-files.\n"
            )
            raise SystemExit(2)
    return root, args.allow or (
        ALLOW if root == ROOT else os.path.join(root, ALLOW_NAME)
    )


def _excluded(rel: str) -> bool:
    """A vendored top-level DIRECTORY, so a file merely named third_party stays in."""
    head, _sep, rest = rel.partition("/")
    return bool(rest) and head in EXCLUDE


def scope(root: str) -> list[str]:
    """lint-shell.sh's file set for `root`, minus EXCLUDE (a no-op for this repo, so applied always)."""
    proc = (
        _lint("--list-files") if root == ROOT else _lint("--root", root, "--list-files")
    )
    if proc.returncode != 0:
        sys.stderr.write(
            f"ERROR: `lint-shell.sh --list-files` failed for {root}:\n{proc.stderr}\n"
        )
        raise SystemExit(2)
    return [line for line in proc.stdout.splitlines() if line and not _excluded(line)]


def binary() -> str:
    override = os.environ.get("SHELLCHECK_BIN")
    if override:
        return override
    proc = _lint("--print-bin")
    out = [line for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or not out:
        sys.stderr.write(
            "ERROR: `lint-shell.sh --print-bin` could not provide the pinned "
            f"shellcheck; set SHELLCHECK_BIN to a matching binary.\n{proc.stderr}\n"
        )
        raise SystemExit(2)
    return _native(out[-1].strip())


def warnings(
    shellcheck: str, files: list[str], root: str, only: set[str] | None = None
) -> dict[tuple[str, str], int]:
    counts = {}
    if not files:
        return counts
    limit = SHELLCHECK_ARGUMENT_LIMIT if os.name == "nt" else sys.maxsize
    comments = []
    for batch in shellcheck_batches(shellcheck, files, limit):
        proc = subprocess.run(
            [shellcheck, *SHELLCHECK_ARGUMENTS, *batch],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        try:
            comments.extend(json.loads(proc.stdout)["comments"])
        except (ValueError, KeyError, TypeError):
            sys.stderr.write(
                f"ERROR: shellcheck exit {proc.returncode}, no json1 output for "
                f"a {len(batch)}-file batch:\n{proc.stderr}\n"
            )
            raise SystemExit(2)
    for c in comments:
        if c.get("level") != "warning" or (only is not None and c["file"] not in only):
            continue
        key = (c["file"], f"SC{c['code']}")
        counts[key] = counts.get(key, 0) + 1
    return counts


def shellcheck_batches(
    shellcheck: str, files: list[str], limit: int
) -> list[list[str]]:
    """Keep each ShellCheck argv below the Windows process command-line limit."""
    batches = []
    current = []
    for path in files:
        candidate = [*current, path]
        command = [shellcheck, *SHELLCHECK_ARGUMENTS, *candidate]
        if len(subprocess.list2cmdline(command)) > limit:
            if not current:
                raise SystemExit(
                    f"ERROR: one ShellCheck path exceeds the {limit}-character command limit: {path}"
                )
            batches.append(current)
            candidate = [path]
            if (
                len(
                    subprocess.list2cmdline(
                        [shellcheck, *SHELLCHECK_ARGUMENTS, *candidate]
                    )
                )
                > limit
            ):
                raise SystemExit(
                    f"ERROR: one ShellCheck path exceeds the {limit}-character command limit: {path}"
                )
        current = candidate
    if current:
        batches.append(current)
    return batches


def _rel(path: str, root: str = ROOT) -> str:
    """A --files argument relative to the graded root; under a consumer root a relative name is the consumer's."""
    if root != ROOT:
        return os.path.relpath(
            path if os.path.isabs(path) else os.path.join(root, path), root
        )
    if os.path.isabs(path):
        return os.path.relpath(path, ROOT)
    if os.path.exists(os.path.join(ROOT, path)) or not os.path.exists(path):
        return os.path.normpath(path)
    return os.path.relpath(os.path.abspath(path), ROOT)


def header_of(path: str) -> list[str]:
    """The comment block that opens the allow file, so --write-baseline keeps it."""
    if not os.path.exists(path):
        return list(HEADER)
    head = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.strip() and not line.strip().startswith("#"):
                break
            head.append(line)
    return head


def write_baseline(
    counts: dict[tuple[str, str], int], checked: set[str], partial: bool, allow: str
) -> None:
    header, old = header_of(allow), load_rows(allow, 2, ALLOW_FMT)
    today = datetime.date.today().isoformat()
    keep = {k: v for k, v in old.items() if partial and k[0] not in checked}
    for key, n in counts.items():
        keep[key] = (n, old.get(key, (0, f"baseline {today}, not yet reviewed"))[1])
    with open(allow, "w", encoding="utf-8") as fh:
        fh.writelines(line + "\n" for line in header)
        for (f, code), (n, reason) in sorted(keep.items()):
            fh.write(f"{f} | {code} | {n} | {reason}\n")
    print(f"wrote {len(keep)} row(s) to {os.path.basename(allow)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--root", default=None, help="the tree to grade (default: this repo)"
    )
    ap.add_argument(
        "--allow",
        default=None,
        help=f"the freeze file (default: {ALLOW_NAME} beside this script for this repo, "
        f"<root>/{ALLOW_NAME} otherwise)",
    )
    ap.add_argument(
        "--files",
        nargs="+",
        metavar="FILE",
        help="check only these files against their own baseline rows",
    )
    ap.add_argument(
        "--write-baseline",
        action="store_true",
        help="freeze the current counts (existing reasons are kept)",
    )
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
    print(
        f"=== shellcheck warning ratchet ({len(files)} of {len(in_scope)} file(s)) "
        f"via shellcheck {_version(shellcheck)} ==="
    )
    if root != ROOT:
        print(f"  root: {root}")
        print(f"  allow: {allow}")
    for f in sorted(skipped):
        print(f"  note: {f} is outside the lint-shell.sh scope, skipped")
    counts = warnings(shellcheck, files, root, only)
    if args.write_baseline:
        write_baseline(counts, set(files), bool(args.files), allow)
        return 0
    rc = check_counts(
        "warnings",
        sorted(counts.items()),
        frozen,
        0,
        os.path.basename(allow),
        "findings",
    )
    if rc == 0:
        print("OK: shellcheck warnings match the baseline exactly")
    return rc


def _version(shellcheck: str) -> str:
    proc = subprocess.run(
        [shellcheck, "--version"], capture_output=True, text=True, check=False
    )
    for line in proc.stdout.splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip()
    return "?"


if __name__ == "__main__":
    sys.exit(main())
