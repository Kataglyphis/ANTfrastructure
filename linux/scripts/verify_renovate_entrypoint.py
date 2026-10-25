#!/usr/bin/env python3
"""Check the tracked, reusable Renovate entrypoint contract of one repository.

This static check cannot prove a live datasource or lock tool will succeed; run the
wrapper's report and plan on a host with credentials before applying updates.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

PRESET = "github>Kataglyphis/ANTfrastructure"
WRAPPERS = (
    Path("scripts/linux/renovate-local.sh"),
    Path("scripts/renovate-local.sh"),
)
HUB_DRIVER = Path("linux/scripts/renovate-local.sh")
CALLER_WORKFLOW = Path(".github/workflows/renovate-entrypoint.yml")
WORKFLOW_REF = "Kataglyphis/ANTfrastructure/.github/workflows/renovate-entrypoint.yml@develop"


def tracked(root: Path, relative: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", str(relative)],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def config_errors(root: Path) -> list[str]:
    """The tracked config must extend the shared preset."""
    errors: list[str] = []
    config_path = Path(".github/renovate.json")
    if not tracked(root, config_path):
        errors.append(f"{config_path} is missing or not tracked")
    else:
        try:
            config = json.loads((root / config_path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            errors.append(f"{config_path} cannot be read as JSON: {exc}")
        else:
            extends = config.get("extends") if isinstance(config, dict) else None
            if isinstance(extends, str):
                extends = [extends]
            if not isinstance(extends, list) or PRESET not in extends:
                errors.append(f"{config_path} must extend {PRESET}")
    return errors


def workflow_errors(root: Path, hub: bool) -> list[str]:
    """The tracked caller must use the reusable hub workflow."""
    errors: list[str] = []
    if not tracked(root, CALLER_WORKFLOW):
        errors.append(f"{CALLER_WORKFLOW} is missing or not tracked")
    else:
        try:
            workflow = (root / CALLER_WORKFLOW).read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"{CALLER_WORKFLOW} cannot be read: {exc}")
        else:
            if hub:
                if not re.search(r"(?m)^  workflow_call:\s*$", workflow):
                    errors.append(f"{CALLER_WORKFLOW} must expose workflow_call")
            elif not re.search(rf"(?m)^\s+uses:\s+{re.escape(WORKFLOW_REF)}\s*$", workflow):
                errors.append(f"{CALLER_WORKFLOW} must call {WORKFLOW_REF}")
    return errors


def delegate_errors(root: Path, wrapper: Path) -> list[str]:
    """A thin consumer wrapper must reach the shared driver with every argument."""
    try:
        source = (root / wrapper).read_text(encoding="utf-8")
    except OSError as exc:
        return [f"{wrapper} cannot be read: {exc}"]
    errors = []
    if "linux/scripts/renovate-local.sh" not in source:
        errors.append(f"{wrapper} must delegate to the shared linux/scripts/renovate-local.sh")
    if '"$@"' not in source and not re.search(r'\$\{[A-Za-z_][A-Za-z_0-9]*\[@\]', source):
        errors.append(f"{wrapper} must forward all arguments with \"$@\" or an argv array")
    return errors


def help_errors(root: Path, wrapper: Path) -> list[str]:
    """Exercise delegation offline so a comment-only wrapper cannot pass."""
    env = os.environ.copy()
    env["ANTFRASTRUCTURE_DIR"] = str(Path(__file__).resolve().parents[2])
    env["KATAGLYPHIS_REPO_ROOT"] = str(root)
    try:
        help_result = subprocess.run(
            ["bash", str(root / wrapper), "--help"],
            cwd=root,
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [f"{wrapper} --help could not complete: {exc}"]
    if help_result.returncode:
        return [f"{wrapper} --help failed through the shared driver: {help_result.stderr.strip()}"]
    return []


def wrapper_errors(root: Path, hub: bool) -> list[str]:
    """Require one tracked, syntactically valid, working entrypoint."""
    candidates = list(WRAPPERS)
    if hub:
        candidates.append(HUB_DRIVER)
    available = [path for path in candidates if tracked(root, path)]
    if len(available) != 1:
        return ["exactly one tracked Renovate wrapper/driver is required at " + ", ".join(map(str, candidates))]
    wrapper = available[0]
    try:
        syntax = subprocess.run(["bash", "-n", str(root / wrapper)], check=False, capture_output=True, text=True)
    except OSError as exc:
        return [f"{wrapper} cannot run Bash syntax check: {exc}"]
    errors: list[str] = []
    if syntax.returncode:
        errors.append(f"{wrapper} has invalid Bash syntax: {syntax.stderr.strip()}")
    if wrapper != HUB_DRIVER:
        errors.extend(delegate_errors(root, wrapper))
    if not syntax.returncode:
        errors.extend(help_errors(root, wrapper))
    return errors


def check(root: Path) -> list[str]:
    """Collect every independent entrypoint failure for one checkout."""
    hub = (root / "default.json").is_file()
    return config_errors(root) + workflow_errors(root, hub) + wrapper_errors(root, hub)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo_root", type=Path)
    args = parser.parse_args()
    root = args.repo_root.resolve()
    if not (root / ".git").exists():
        print(f"Renovate entrypoint FAIL: {root} is not a Git checkout", file=sys.stderr)
        return 1
    errors = check(root)
    for error in errors:
        print(f"Renovate entrypoint FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"Renovate entrypoint OK: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
