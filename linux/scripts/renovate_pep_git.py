# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Reconcile tagged PEP 508 Git sources that Renovate's native manager skips."""

import collections
import json
import os
import re
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

import renovate_audit
import renovate_locator

PAIR = {
    "pytorch/pytorch": ("torch", "PYTORCH_VERSION"),
    "pytorch/vision": ("torchvision", "TORCHVISION_VERSION"),
}
MANIFEST = "pyproject.toml"


def needs_regex_manager(root: str) -> bool:
    """Require tag lookups when PEP 621 declares a pinned PyTorch Git source."""
    path = os.path.join(root, MANIFEST)
    if not os.path.isfile(path):
        return False
    with open(path, encoding="utf-8") as fh:
        struct = renovate_audit.parse("pep621", fh.read())
    return any(renovate_audit.decl_pep621_git(struct, repo) for repo in PAIR)


@dataclass
class PairState:
    active: bool = False
    verified: bool = False
    reason: str = ""
    covered: set[int] = field(default_factory=set)
    current: dict[str, str] = field(default_factory=dict)
    candidate: dict[str, str] = field(default_factory=dict)
    specs: dict[tuple[str, str], int] = field(default_factory=dict)


def _deps(report: Mapping[str, Any], manager: str) -> list[tuple[str, dict[str, Any]]]:
    out = []
    for repo in (report.get("repositories") or {}).values():
        for item in (repo.get("packageFiles") or {}).get(manager, []):
            path = item.get("packageFile") or ""
            if path == MANIFEST:
                out.extend((path, dep) for dep in item.get("deps") or [])
    return out


def _source_spec(leaf: str) -> str:
    parsed = renovate_locator.pep508_span(leaf)
    return leaf[parsed[2] : parsed[3]] if parsed else ""


def _tag_from_native(dep: dict[str, Any], repo: str) -> str:
    value = (dep.get("currentValue") or "").strip()
    match = re.fullmatch(
        r"@\s+git\+https://github\.com/"
        + re.escape(repo)
        + r"\.git@(?P<tag>v[A-Za-z0-9._+-]+)",
        value,
    )
    return match.group("tag") if match else ""


def _checked_lookups(
    lookups: list[dict[str, Any]],
) -> tuple[collections.Counter[tuple[str, str]], dict[str, set[str]]]:
    observed: collections.Counter[tuple[str, str]] = collections.Counter()
    candidates: dict[str, set[str]] = collections.defaultdict(set)
    for dep in lookups:
        repo = dep["depName"]
        old = dep.get("currentValue") or ""
        if (
            dep.get("datasource") != "github-tags"
            or dep.get("packageName") != repo
            or dep.get("lookupName", repo) != repo
            or dep.get("skipReason")
            or dep.get("warnings")
            or not renovate_locator.valid_pep_git_tag(old)
            or dep.get("currentVersion") != old
        ):
            raise ValueError(f"{repo} has no successful GitHub tag lookup")
        updates = dep.get("updates") or []
        if len(updates) > 1:
            raise ValueError(f"{repo} has ambiguous GitHub tag updates")
        next_tag = updates[0].get("newValue") if updates else old
        if not renovate_locator.valid_pep_git_tag(next_tag or ""):
            raise ValueError(f"{repo} proposes a malformed GitHub tag")
        observed[repo, old] += 1
        candidates[repo].add(next_tag)
    return observed, candidates


def _one_source(
    state: PairState,
    struct: object,
    repo: str,
    package: str,
    observed: collections.Counter[tuple[str, str]],
    candidates: dict[str, set[str]],
) -> int:
    source = renovate_audit.decl_pep621_git(struct, repo)
    if not source or len({d.leaf[d.start : d.end] for d in source}) != 1:
        raise ValueError(f"{repo} Git URL tags are absent or inconsistent")
    tag = source[0].leaf[source[0].start : source[0].end]
    if observed[repo, tag] != len(source) or sum(
        n for (name, _), n in observed.items() if name == repo
    ) != len(source):
        raise ValueError(f"{repo} Git URL lookup coverage is incomplete")
    if len(candidates[repo]) != 1:
        raise ValueError(f"{repo} GitHub tag lookups disagree")
    state.current[repo] = tag
    state.candidate[repo] = candidates[repo].pop()
    source_spec = _source_spec(source[0].leaf)
    if any(_source_spec(d.leaf) != source_spec for d in source):
        raise ValueError(f"{repo} Git URL forms disagree")
    state.specs[package, source_spec] = len(source)
    declared = renovate_audit.decl_pep621(struct, package)
    git_specs = [d for d in declared if _source_spec(d.leaf).startswith("@ git+")]
    if len(git_specs) != len(source):
        raise ValueError(f"{package} has a Git source outside the checked tags")
    wheels = [d for d in declared if _source_spec(d.leaf).startswith("==")]
    if len(declared) != len(git_specs) + len(wheels):
        raise ValueError(
            f"{package} has a dependency outside the checked Git and wheel pins"
        )
    bare = tag.removeprefix("v")
    if not wheels or any(_source_spec(d.leaf) != "==" + bare for d in wheels):
        raise ValueError(f"{package} wheel pins do not match its Git tag")
    state.specs[package, "==" + bare] = len(wheels)
    return len(source)


def _cover_native(
    state: PairState,
    report: Mapping[str, Any],
    observed: collections.Counter[tuple[str, str]],
) -> None:
    native = collections.Counter(observed)
    seen: collections.Counter[tuple[str, str]] = collections.Counter()
    for _, dep in _deps(report, "pep621"):
        package = dep.get("depName")
        if package not in ("torch", "torchvision"):
            continue
        spec = (dep.get("currentValue") or "").strip()
        seen[package, spec] += 1
        if (package, spec) not in state.specs or seen[package, spec] > state.specs[
            package, spec
        ]:
            raise ValueError(
                f"{package} native report row is outside the checked declarations"
            )
        if dep.get("skipReason") != "invalid-value":
            continue
        if dep.get("warnings"):
            raise ValueError(f"{package} native skip also carries a warning")
        repo = next(name for name, (pkg, _) in PAIR.items() if pkg == package)
        tag = _tag_from_native(dep, repo)
        if not tag or native[repo, tag] <= 0:
            raise ValueError(f"{package} native skip has no matching GitHub lookup")
        native[repo, tag] -= 1
        state.covered.add(id(dep))


def inspect(report: Mapping[str, Any], root: str | None) -> PairState:
    """Only a complete, matching regex lookup covers native invalid-value rows."""
    state = PairState()
    if root is None:
        return state
    lookups = [dep for _, dep in _deps(report, "regex") if dep.get("depName") in PAIR]
    if not lookups:
        return state
    state.active = True
    try:
        with open(os.path.join(root, MANIFEST), encoding="utf-8") as fh:
            struct = renovate_audit.parse("pep621", fh.read())
        observed, candidates = _checked_lookups(lookups)
        counts = {}
        for repo, (package, _) in PAIR.items():
            count = _one_source(state, struct, repo, package, observed, candidates)
            counts[repo, state.current[repo]] = count
        if observed != collections.Counter(counts):
            raise ValueError("GitHub tag lookups include an untracked source")
        _cover_native(state, report, observed)
        state.verified = True
    except (OSError, ValueError, KeyError, TypeError, renovate_audit.Unreadable) as exc:
        state.reason = str(exc)
        state.covered.clear()
    return state


def _git(root: str, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", root, *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode:
        raise ValueError(
            f"cannot verify the pinned hub gitlink: {result.stderr.strip()[:160]}"
        )
    return result.stdout.strip()


def _pinned_versions(root: str) -> str:
    subpath = "third_party/ANTfrastructure"
    relative = "linux/scripts/01-core/versions.env"
    tree = _git(root, "ls-tree", "HEAD", "--", subpath)
    match = re.fullmatch(
        r"160000 commit ([0-9a-f]{40})\tthird_party/ANTfrastructure", tree
    )
    if match is None:
        raise ValueError("the parent commit has no pinned ANTfrastructure gitlink")
    pinned = match.group(1)
    indexed = _git(root, "ls-files", "--stage", "--", subpath)
    if indexed != f"160000 {pinned} 0\t{subpath}":
        raise ValueError("the hub gitlink is staged away from the parent commit")
    subroot = os.path.join(root, "third_party", "ANTfrastructure")
    if not os.path.exists(os.path.join(subroot, ".git")):
        raise ValueError("the pinned hub submodule is not initialized")
    if _git(subroot, "rev-parse", "HEAD") != pinned:
        raise ValueError("the hub submodule HEAD differs from the parent gitlink")
    if _git(subroot, "status", "--porcelain", "--untracked-files=all", "--", relative):
        raise ValueError("the hub versions.env differs from the parent-pinned commit")
    return _git(subroot, "show", f"{pinned}:{relative}")


def _approved(root: str) -> dict[str, str]:
    text = _pinned_versions(root)
    out = {}
    for repo, (_, key) in PAIR.items():
        values = re.findall(r"^" + re.escape(key) + r"=([^\s#]+)$", text, re.MULTILINE)
        if len(values) != 1 or not renovate_locator.valid_pep_git_tag(values[0]):
            raise ValueError(f"the hub has no single valid {key} tag")
        out[repo] = values[0]
    return out


def report_gap(state: PairState, root: str | None) -> str:
    """A newer accepted pair must appear in the successful GitHub lookup results."""
    if root is None or not state.active or not state.verified:
        return ""
    try:
        approved = _approved(root)
    except (OSError, ValueError) as exc:
        return str(exc)
    if approved != state.current and approved != state.candidate:
        return (
            "the GitHub tag candidates differ from the hub-approved Torch/vision pair"
        )
    return ""


def projection(state: PairState, root: str) -> tuple[list[dict[str, str]], str]:
    """Synthetic pep621 rows; the planner's ordinary TOML/uv transaction owns them."""
    if not state.active:
        return [], ""
    if not state.verified:
        return [], state.reason or "Git URL lookups were not verified"
    try:
        approved = _approved(root)
    except (OSError, ValueError) as exc:
        return [], str(exc)
    if approved == state.current:
        return [], "the hub-approved Torch/vision pair has not moved"
    if approved != state.candidate:
        return (
            [],
            "the GitHub tag candidates differ from the hub-approved Torch/vision pair",
        )
    out = []
    for repo, (package, _) in PAIR.items():
        old, new = state.current[repo], approved[repo]
        for spec, count in state.specs.items():
            if spec[0] != package:
                continue
            previous = spec[1]
            target = (
                previous.replace("@" + old, "@" + new)
                if previous.startswith("@ git+")
                else "==" + new.removeprefix("v")
            )
            if previous == target:
                continue
            for _ in range(count):
                out.append(
                    {
                        "manager": "pep621",
                        "file": MANIFEST,
                        "dep": package,
                        "pkg": package,
                        "datasource": "github-tags",
                        "depType": "",
                        "cur": previous,
                        "new": target,
                        "curDigest": "",
                        "newDigest": "",
                        "updateType": "",
                        "path": os.path.join(root, MANIFEST),
                    }
                )
    return out, ""


def managed(row: dict[str, str], state: PairState) -> bool:
    """A native or regex update whose whole pair is governed by this projection."""
    return (
        state.active
        and row["file"] == MANIFEST
        and (
            (row["manager"] == "regex" and row["dep"] in PAIR)
            or (
                row["manager"] == "pep621"
                and row["dep"] in {package for package, _ in PAIR.values()}
            )
        )
    )


def _pair_edit(plan_path: str) -> bool:
    with open(plan_path, encoding="utf-8") as fh:
        steps = json.load(fh)
    return any(
        step.get("manager") == "pep621"
        and step.get("file") == MANIFEST
        and step.get("dep") in {package for package, _ in PAIR.values()}
        and (step.get("cur") or "").startswith("@ git+https://github.com/pytorch/")
        for step in steps
    )


def _manifest_tag(struct: object, repo: str) -> str:
    source = renovate_audit.decl_pep621_git(struct, repo)
    tags = {d.leaf[d.start : d.end] for d in source}
    if len(tags) != 1:
        raise ValueError(f"{repo} has no single PEP Git tag after the edit")
    return tags.pop()


def _lock_source(item: dict[str, Any], repo: str, package: str, tag: str) -> str:
    source = item.get("source")
    if not isinstance(source, dict):
        raise TypeError(f"uv.lock {package} has no parsed source")
    bare = tag.removeprefix("v")
    version = item.get("version") or ""
    if "git" in source:
        git_url = re.compile(
            r"https://github\.com/"
            + re.escape(repo)
            + r"\.git\?rev="
            + re.escape(tag)
            + r"#[0-9a-fA-F]{40}$"
        )
        if not git_url.fullmatch(source["git"]) or not re.match(
            re.escape(bare) + r"(?:$|[A-Za-z+])", version
        ):
            raise ValueError(f"uv.lock {package} Git source does not match {tag}")
        return "git"
    if "registry" in source:
        if version != bare and not version.startswith(bare + "+"):
            raise ValueError(f"uv.lock {package} wheel version does not match {tag}")
        return "registry"
    raise ValueError(f"uv.lock {package} has an unsupported source")


def _lock_package(lock: object, repo: str, package: str, tag: str) -> None:
    if not isinstance(lock, dict) or not isinstance(lock.get("package"), list):
        raise TypeError("uv.lock has no package array")
    entries = [
        item
        for item in lock["package"]
        if isinstance(item, dict) and item.get("name") == package
    ]
    if not entries:
        raise ValueError(f"uv.lock has no {package} package")
    kinds = collections.Counter(
        _lock_source(item, repo, package, tag) for item in entries
    )
    git_count, registry_count = kinds["git"], kinds["registry"]
    if git_count != 1 or registry_count < 1:
        raise ValueError(f"uv.lock {package} needs one Git source and registry wheels")


def lock_gap(root: str, plan_path: str, phase: str) -> str:
    """Require the parsed uv lock to carry every source and wheel in a pair edit."""
    try:
        if not _pair_edit(plan_path):
            return ""
        if phase not in ("before", "after"):
            raise ValueError("pair lock phase must be before or after")
        with open(os.path.join(root, MANIFEST), encoding="utf-8") as fh:
            manifest = renovate_audit.parse("pep621", fh.read())
        with open(os.path.join(root, "uv.lock"), encoding="utf-8") as fh:
            lock = renovate_audit.parse("pep621", fh.read())
        approved = _approved(root) if phase == "after" else {}
        for repo, (package, _) in PAIR.items():
            tag = _manifest_tag(manifest, repo)
            if phase == "after" and tag != approved[repo]:
                raise ValueError(
                    f"{package} manifest tag differs from the hub-approved pair"
                )
            _lock_package(lock, repo, package, tag)
    except (OSError, ValueError, KeyError, TypeError, renovate_audit.Unreadable) as exc:
        return str(exc)
    return ""
