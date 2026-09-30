#!/usr/bin/env python3
"""Catch functions consumed as `x="$(f)"` that log on stdout, since log()/info() write to fd 1.

docs/code-quality-tooling.md#stdout-return-gate-stdout-returns
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
    """Every *.sh under linux/scripts bar the Windows lane, walked since the suites plant non-git trees."""
    return [p for p in (root / "linux" / "scripts").rglob("*.sh")
            if "windows" not in str(p)]


def _tracked_files(root: Path) -> list[Path]:
    """Tracked *.sh under a consumer root per gate_scope, as absolute paths."""
    return [root / rel for rel in gate_scope.tracked(str(root), ["*.sh"])]

def scan_files(root: Path) -> list[Path]:
    """The hub grades its historical walk; any other root grades its tracked shell."""
    return _hub_files(root) if root == ROOT else _tracked_files(root)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Catch stdout logging inside functions whose stdout is their value.")
    ap.add_argument("--root", default=None,
                    help="the tree to grade (default: this repo)")
    args = ap.parse_args()

    # `--root ""` would grade the current directory; no --root at all (None) means this repo.
    if args.root is not None and not args.root:
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
        print(f"  scope: {len(files)} tracked *.sh outside "
              f"{', '.join(gate_scope.EXCLUDE)}")

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
