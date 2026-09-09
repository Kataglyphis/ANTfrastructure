#!/usr/bin/env python3
"""Catch functions whose STDOUT is their return value from logging on stdout.

WHY THIS EXISTS (2026-08-26 / 2026-08-27)
-----------------------------------------
`logging.sh` routes info() -- and therefore log() -- to fd 1, while warn()/err()
go to fd 2. A shell function whose result is consumed as `x="$(f)"` therefore
returns its log lines CONCATENATED WITH its value the moment anyone adds a log()
to it.

That is not hypothetical. It shipped twice:

  * compiler_cache_launcher() leaked an info() line into CC, so GCC was
    configured with CC="[INFO] Using sccache with SCCACHE_DIR=... (cap 30G)sccache
    gcc" and died as "configure: error: C compiler cannot create executables" --
    a message pointing nowhere near the cause.
  * normalize_llvm_cmake_dir() (tvm-detect.sh) logged on stdout while three call
    sites consumed its stdout as a path. Latent: it only fires when the LLVM
    CMake path actually needs normalising.

A unit test can pin one function. This pins the CLASS: any function that is both
called in a command substitution somewhere in the tree AND logs on fd 1 without
`>&2` is reported.

GRADING A CONSUMER
------------------
`--root` is the contract docs/scripts/verify_mutations.py already documents, and
it exists here for the reason run-lint-gates.sh refuses to infer a root: a
submodule checkout puts this script INSIDE the consumer, where a root derived
from __file__ resolves to ContainerHub. The gate then grades the hub, passes,
and reports green over a consumer's shell that nobody graded at all -- and this
particular defect travels with the library, since a consumer sourcing
`logging.sh` inherits the exact fd-1 log() the two shipped bugs came from.

Under the hub's own root the scan set is the historical walk of linux/scripts
(bar the Windows lane, which has its own backlog), so the hub's own verdict does
not move by a line. Under any other root it is every TRACKED *.sh outside the
excluded top-level directories -- the same `git ls-files` scope
run-lint-gates.sh builds, so a consumer needs no per-repo configuration, a
vendored submodule (a gitlink) cannot be walked into, and build output stays
out.

A --root that is not a git checkout is refused, and so is a scope that comes
back empty: both would otherwise print the OK line over nothing, which is the
failure this whole flag exists to end.

There is no --allow. This gate carries no freeze file
(docs/code-quality-gates.md records none) and gains none here: every finding is
one call site away from a poisoned return value, `>&2` is the one-token fix, and
a per-consumer ratchet would only be a place to park them.

Exit 0 when clean, 1 when something is found, 2 when the root cannot be graded.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gate_scope  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
# log()/info() reach fd 1; warn()/err()/die() reach fd 2 and are therefore safe.
STDOUT_LOGGERS = re.compile(r"^\s*(log|info)\s")
FUNC_DEF = re.compile(r"^([a-z_][a-z0-9_]*)\(\)\s*\{(.*?)^\}", re.S | re.M)
SUBST = re.compile(r"\$\(\s*([a-z_][a-z0-9_]*)\b")


def _hub_files(root: Path) -> list[Path]:
    """The historical scan: every *.sh under linux/scripts, Windows lane aside.

    A walk, not `git ls-files`: this is the hub's own verdict and it must not
    move, and this gate's tests run it over a planted throwaway tree that is no
    git checkout at all.
    """
    return [p for p in (root / "linux" / "scripts").rglob("*.sh")
            if "windows" not in str(p)]


def _tracked_files(root: Path) -> list[Path]:
    """Tracked *.sh under a consumer root, as absolute paths.

    gate_scope owns the scope rules; this only re-wraps them in pathlib,
    which is the shape the rest of this gate works in.
    """
    return [root / rel for rel in gate_scope.tracked(str(root), ["*.sh"])]

def scan_files(root: Path) -> list[Path]:
    """The hub grades its historical walk; any other root grades its tracked shell."""
    return _hub_files(root) if root == ROOT else _tracked_files(root)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Catch stdout logging inside functions whose stdout is their value.")
    ap.add_argument("--root", default=str(ROOT),
                    help="the tree to grade (default: this repo)")
    args = ap.parse_args()

    # `--root ""` would resolve to the CURRENT directory, which is how a gate
    # ends up grading whatever it happens to be standing in; and a root that is
    # not a directory must say so rather than reach git and be reported as "not
    # a git checkout".
    if not args.root:
        ap.error("--root needs a directory")
    try:
        # See gate_scope: a subdirectory of a checkout is not a valid root.
        root = Path(gate_scope.resolve_root(args.root, str(ROOT)))
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    if not root.is_dir():
        sys.stderr.write(f"ERROR: --root {root} is not a directory\n")
        raise SystemExit(2)

    files = scan_files(root)
    if root != ROOT:
        print(f"stdout-return gate over {root}")
        print(f"  scope: {len(files)} tracked *.sh outside {', '.join(EXCLUDE)}")

    consumed: set[str] = set()
    for p in files:
        consumed |= set(SUBST.findall(p.read_text(errors="replace")))

    findings = []
    for p in files:
        for name, body in FUNC_DEF.findall(p.read_text(errors="replace")):
            if name not in consumed:
                continue
            for lineno, line in enumerate(body.splitlines(), 1):
                if STDOUT_LOGGERS.match(line) and ">&2" not in line:
                    findings.append((p.relative_to(root), name, line.strip()[:88]))

    if not findings:
        print(f"stdout-return gate OK: {len(consumed)} substituted function name(s), "
              "no stdout logging inside any of them.")
        return 0

    print(f"{len(findings)} function(s) log on STDOUT while their stdout is a return value:")
    for path, name, line in findings:
        print(f"  {path}: {name}()")
        print(f"      {line}")
    print("\nlog()/info() write to fd 1 (logging.sh:77,82). Append `>&2`, or the")
    print("caller's `x=\"$(f)\"` captures the log line together with the value.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
