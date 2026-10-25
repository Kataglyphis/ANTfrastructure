#!/usr/bin/env python3
"""Check ratchet arguments on tracked CI calls; absent calls and triggers are outside scope."""
from __future__ import annotations

import argparse
import re
import shlex
import sys
from pathlib import Path

import gate_scope
from verify_workflow_conventions import ParseError, line_of, load_yaml, value

HUB_ROOT = Path(__file__).resolve().parents[2]
REUSABLE = "Kataglyphis/ANTfrastructure/.github/workflows/lint-gates.yml@"
SCRIPT = "run-lint-gates.sh"
BLOCK_RUN = re.compile(r"^\s*(?:-\s+)?run:\s*([|>])[-+0-9]*\s*(?:#.*)?$")
SPLIT_COMMAND = re.compile(r"&&|\|\||;")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")


def _run_text(path: Path, step: dict) -> str:
    """Recover a run block omitted by the shared YAML subset parser."""
    run = value(step, "run")
    at = line_of(step, "run")
    if not isinstance(run, str) or at < 1:
        return ""
    lines = path.read_text(encoding="utf-8").splitlines()
    header = lines[at - 1]
    block = BLOCK_RUN.match(header)
    if not block:
        return run
    indent = len(header) - len(header.lstrip(" "))
    body = []
    for raw in lines[at:]:
        if raw.strip() and len(raw) - len(raw.lstrip(" ")) <= indent:
            break
        body.append(raw.strip())
    return (" " if block.group(1) == ">" else "\n").join(body)


def _script_argv(words: list[str]) -> list[str] | None:
    """Find a shell command's script argv, without mistaking echo text for a call."""
    while words and (words[0] in ("if", "then", "!", "exec", "env") or
                     ASSIGNMENT.match(words[0])):
        words = words[1:]
    if not words:
        return None
    if words[0] in ("bash", "sh"):
        words = words[1:]
    if words and words[0].replace("\\", "/").rsplit("/", 1)[-1] == SCRIPT:
        return words[1:]
    return None


def _direct_calls(body: str) -> list[list[str]]:
    calls = []
    for line in body.replace("\\\n", " ").splitlines():
        for command in SPLIT_COMMAND.split(line):
            try:
                argv = _script_argv(shlex.split(command, comments=True))
            except ValueError:
                if SCRIPT in command:
                    calls.append([])
                continue
            if argv is not None:
                calls.append(argv)
    return calls


def _inactive(node: dict) -> bool:
    condition = value(node, "if", "")
    return isinstance(condition, str) and condition.strip() in (
        "false", "${{ false }}", "${{false}}")


def _nonfatal(node: dict) -> bool:
    return value(node, "continue-on-error") == "true"


def _grade_reusable(rel: str, name: str, job: dict, at: int,
                    witnesses: list[str], failures: list[str]) -> None:
    uses = value(job, "uses", "")
    if not isinstance(uses, str) or not uses.startswith(REUSABLE):
        return
    where = f"{rel}:{line_of(job, 'uses', at)} job {name}"
    ratchets = value(value(job, "with", {}), "ratchets")
    if ratchets != "true" or _inactive(job) or _nonfatal(job):
        failures.append(
            f"{where}: reusable lint call needs ratchets: true and a fatal, enabled job")
    else:
        witnesses.append(f"{where}: reusable lint with ratchets: true")


def _grade_steps(path: Path, rel: str, name: str, job: dict,
                 witnesses: list[str], failures: list[str]) -> None:
    steps = value(job, "steps", [])
    if not isinstance(steps, list):
        return
    for step in steps:
        if not isinstance(step, dict):
            continue
        for argv in _direct_calls(_run_text(path, step)):
            where = f"{rel}:{line_of(step, 'run')} job {name}"
            if "--ratchets" not in argv or _inactive(job) or _inactive(step) or \
                    _nonfatal(job) or _nonfatal(step):
                failures.append(
                    f"{where}: direct lint call needs --ratchets and a fatal, enabled step")
            else:
                witnesses.append(f"{where}: direct lint with --ratchets")


def _grade_workflow(path: Path, rel: str, doc: dict,
                    witnesses: list[str], failures: list[str]) -> None:
    jobs = value(doc, "jobs", {})
    if not isinstance(jobs, dict):
        return
    for name, (job, at) in jobs.items():
        if not isinstance(job, dict):
            continue
        _grade_reusable(rel, name, job, at, witnesses, failures)
        _grade_steps(path, rel, name, job, witnesses, failures)


def _mentions_quality(path: Path) -> bool:
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.lstrip().startswith("#"):
            continue
        if REUSABLE in line or SCRIPT in line:
            return True
    return False


def inspect(root: Path, tracked: list[str]) -> tuple[list[str], list[str]]:
    """Return (working call witnesses, failures) for a declared consumer."""
    witnesses, failures = [], []
    workflows = sorted(rel for rel in tracked if rel.startswith(".github/workflows/")
                       and rel.count("/") == 2 and rel.endswith((".yml", ".yaml")))
    for rel in workflows:
        path = root / rel
        try:
            doc = load_yaml(path)
        except OSError as exc:
            failures.append(f"{rel}: cannot parse tracked workflow ({exc})")
            continue
        except (UnicodeError, ParseError) as exc:
            if _mentions_quality(path):
                failures.append(f"{rel}: cannot parse tracked workflow with a lint call ({exc})")
            continue
        _grade_workflow(path, rel, doc, witnesses, failures)
    return witnesses, failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", required=True, help="consumer repository root")
    args = ap.parse_args()
    try:
        root = Path(gate_scope.resolve_root(args.root, HUB_ROOT))
        if root == HUB_ROOT:
            raise gate_scope.ScopeError("the hub provides lint-gates.yml; --root needs a consumer")
        tracked = gate_scope.tracked(root, [".github/workflows/*.yml",
                                             ".github/workflows/*.yaml"])
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    witnesses, failures = inspect(root, tracked)
    for witness in witnesses:
        print(f"OK: {witness}")
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if not witnesses and not failures:
        print("ADVISORY: no tracked CI lint call; removal of every lint call is outside this gate")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
