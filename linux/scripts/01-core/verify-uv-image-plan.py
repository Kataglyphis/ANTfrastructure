#!/usr/bin/env python3
"""Reject installs outside a uv-exported set; it does not validate image provenance."""

import json
import re
import sys
from pathlib import Path

from packaging.requirements import Requirement
from packaging.version import Version


def key(name: str) -> str:
    """Normalize distribution names."""
    return re.sub(r"[-_.]+", "-", name).lower()


def read_allowed(requirements: Path) -> dict[str, set[str]]:
    """Read the exact locked overlay requirements."""
    allowed: dict[str, set[str]] = {}
    for line in requirements.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.fullmatch(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;]+)(?:\s*;.*)?\s*", line)
        if match is None:
            raise ValueError(f"Not an exact locked requirement: {line}")
        allowed.setdefault(key(match[1]), set()).add(match[2])
    return allowed


def check_install_plan(plan: Path, allowed: dict[str, set[str]]) -> None:
    """Reject unexpected planned distributions."""
    report = json.loads(plan.read_text(encoding="utf-8"))
    for item in report["install"]:
        metadata = item["metadata"]
        name, version = metadata["name"], metadata["version"]
        if version not in allowed.get(key(name), set()):
            raise ValueError(f"Install plan is outside the lock: {name}=={version}")


def read_constraints(constraints: Path) -> dict[str, str]:
    """Read exact versions present in the image."""
    image: dict[str, str] = {}
    for line in constraints.read_text(encoding="utf-8").splitlines():
        name, separator, version = line.partition("==")
        if not separator:
            raise ValueError(f"Not an exact image constraint: {line}")
        image[key(name)] = version
    return image


def check_image(full_lock: Path, image: dict[str, str]) -> None:
    """Reject image versions that differ from the active lock."""
    conflicts = []
    for line in full_lock.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        requirement = Requirement(line)
        if requirement.marker and not requirement.marker.evaluate():
            continue
        specs = list(requirement.specifier)
        if requirement.url or len(specs) != 1 or specs[0].operator != "==":
            raise ValueError(f"Not an exact locked requirement: {line}")
        name = key(requirement.name)
        if name in image and Version(image[name]) != Version(specs[0].version):
            conflicts.append(f"{name}: image {image[name]}, lock {requirement.specifier}")
    if conflicts:
        raise ValueError("Image packages conflict with the lock: " + "; ".join(conflicts))


def verify(requirements: Path, plan: Path, full_lock: Path, constraints: Path) -> None:
    """Check the planned installs and image versions against the lock."""
    check_install_plan(plan, read_allowed(requirements))
    check_image(full_lock, read_constraints(constraints))


if __name__ == "__main__":
    verify(*(Path(arg) for arg in sys.argv[1:]))
