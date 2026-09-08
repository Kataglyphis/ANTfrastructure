#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Every CI lane in the family runs in the SAME two images, and this proves it.

versions.env owns the convention (IMAGE_REGISTRY_PREFIX + CI_IMAGE_LINUX_TAG /
CI_IMAGE_WINDOWS_TAG). YAML cannot read that file, so the four container
composite actions carry the composed ref as their `image:` input DEFAULT and
callers omit the input. A default alone would be a lie waiting to happen: it
supplies the right value when the input is ABSENT and silently steps aside the
moment a caller passes a wrong one. These three checks are what make the wrong
value visible instead:

  A. Each of the four actions' `image` input still has a `default:` and that
     default equals the ref composed from versions.env. A tag bump therefore
     lands in one file and the four copies cannot drift away from it.
  B. Every `kataglyphis_beschleuniger:<tag>` literal anywhere under .github/
     names one of the two canonical tags. This is the drift detector: an
     arch-suffixed tag, a stale tag, or plain `:latest` (whose per-platform
     children were deleted and never restored) fails here rather than at
     `docker pull` time in someone else's lane.
  C. A step that `uses:` one of the four actions and passes an `image:`
     containing a literal must pass the canonical ref FOR THAT ACTION'S
     PLATFORM. B alone cannot catch a Linux lane handed `:winamd64` -- both
     tags are canonical, just not for the same action.

Deliberate overrides are not forbidden, they are declared: add a row to EXCUSED
with the reason. A stale row (the tag no longer appears) fails too, so the list
can only shrink by being true.

Usage:
    python3 linux/scripts/verify_ci_image_refs.py           # this repo
    python3 linux/scripts/verify_ci_image_refs.py <root>    # a consumer repo

The consumer root exists for the same reason lint-workflows.sh takes one: a
submodule checkout puts this script INSIDE the consumer, where the default root
resolves to ContainerHub and the gate would report green over the wrong tree.
versions.env always comes from THIS repo regardless of the root.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HUB_ROOT = HERE.parent.parent
VERSIONS_ENV = HERE / "01-core" / "versions.env"

# The four composite actions the whole family reaches its containers through,
# and the platform each one is for. Relative to <root>/.github/actions/.
CONTAINER_ACTIONS = {
    "prepare-linux-ci-host": "linux",
    "run-in-linux-container": "linux",
    "prepare-windows-container-host": "windows",
    "run-in-windows-container": "windows",
}

# Non-canonical `kataglyphis_beschleuniger:<tag>` literals that are correct
# anyway, keyed "<path relative to root>::<tag>" with the reason. A row whose
# tag no longer appears at that path is STALE and fails: this list may only
# shrink by becoming true.
EXCUSED: dict[str, str] = {}

REF_RE = re.compile(r"kataglyphis_beschleuniger:([A-Za-z0-9][A-Za-z0-9._-]*)")
USES_RE = re.compile(r"^(\s*)(?:-\s+)?uses:\s*(\S+)")
IMAGE_RE = re.compile(r"^\s*image:\s*(.*?)\s*$")
LIST_ITEM_RE = re.compile(r"^(\s*)-\s")
# `image:` inside an action's `inputs:` block, i.e. the input NAME, not a value.
INPUT_KEY_RE = re.compile(r"^  image:\s*$")
DEFAULT_RE = re.compile(r"^    default:\s*(.*?)\s*$")


def fail(msg: str) -> None:
    sys.stderr.write("FAIL: %s\n" % msg)


def load_versions(path: Path) -> dict[str, str]:
    """versions.env is inert KEY=value data -- parsed, never sourced."""
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == key and key[:1].isupper():
            out[key] = value.strip().strip("'\"")
    return out


def canonical_refs() -> dict[str, str]:
    versions = load_versions(VERSIONS_ENV)
    missing = [k for k in ("IMAGE_REGISTRY_PREFIX", "CI_IMAGE_LINUX_TAG",
                           "CI_IMAGE_WINDOWS_TAG") if not versions.get(k)]
    if missing:
        raise SystemExit("FAIL: %s: missing %s" % (VERSIONS_ENV, ", ".join(missing)))
    prefix = versions["IMAGE_REGISTRY_PREFIX"]
    return {
        "linux": "%s:%s" % (prefix, versions["CI_IMAGE_LINUX_TAG"]),
        "windows": "%s:%s" % (prefix, versions["CI_IMAGE_WINDOWS_TAG"]),
    }


def yaml_files(root: Path) -> list[Path]:
    gh = root / ".github"
    found = sorted(gh.glob("workflows/*.yml")) + sorted(gh.glob("workflows/*.yaml"))
    return found + sorted(gh.glob("actions/*/action.yml")) + sorted(gh.glob("actions/*/action.yaml"))


def image_input_default(text: str) -> str | None:
    """The `default:` of the top-level `image` input, or None when it has none.

    Hand-parsed on purpose: the gate must run with the stdlib alone (CI installs
    no PyYAML for it), and the shape it reads -- two-space input key, four-space
    key/value under it -- is the shape every action.yml in this repo is written
    in and the shape actionlint enforces.
    """
    lines = text.replace("\r\n", "\n").split("\n")
    for i, line in enumerate(lines):
        if not INPUT_KEY_RE.match(line):
            continue
        for follow in lines[i + 1:]:
            if follow.strip() and not follow.startswith("    "):
                return None  # next input reached, no default
            m = DEFAULT_RE.match(follow)
            if m:
                return m.group(1).strip().strip("'\"")
    return None


def check_action_defaults(root: Path, refs: dict[str, str]) -> tuple[int, int]:
    """A: the four `image` defaults are present and equal the composed ref."""
    bad = seen = 0
    for name, platform in sorted(CONTAINER_ACTIONS.items()):
        path = root / ".github" / "actions" / name / "action.yml"
        if not path.is_file():
            continue
        seen += 1
        rel = path.relative_to(root).as_posix()
        value = image_input_default(path.read_text(encoding="utf-8"))
        if value is None:
            fail("%s: the `image` input has no `default:` -- callers would have to "
                 "re-type the tag, which is the drift this gate exists to stop." % rel)
            bad += 1
        elif value != refs[platform]:
            fail("%s: `image` default is %s, versions.env composes %s"
                 % (rel, value, refs[platform]))
            bad += 1
    return bad, seen


def literal_refs(text: str) -> list[tuple[int, str, str]]:
    """(line number, tag, line) for every kataglyphis_beschleuniger:<tag> literal."""
    out = []
    for n, line in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
        for m in REF_RE.finditer(line):
            out.append((n, m.group(1), line.strip()))
    return out


def check_literals(root: Path, files: list[Path], refs: dict[str, str]) -> tuple[int, set]:
    """B: every literal tag under .github/ is one of the two canonical ones."""
    canonical_tags = {ref.rsplit(":", 1)[1] for ref in refs.values()}
    bad = 0
    used_excuses = set()
    for path in files:
        rel = path.relative_to(root).as_posix()
        for lineno, tag, line in literal_refs(path.read_text(encoding="utf-8")):
            if tag in canonical_tags:
                continue
            key = "%s::%s" % (rel, tag)
            if key in EXCUSED:
                used_excuses.add(key)
                continue
            fail("%s:%d: non-canonical image tag ':%s' (canonical: %s)\n      %s"
                 % (rel, lineno, tag, " / ".join(sorted(canonical_tags)), line))
            bad += 1
    return bad, used_excuses


def action_platform(uses: str) -> str | None:
    """The platform of a `uses:` reference to one of the four container actions."""
    ref = uses.strip().strip("'\"").split("@", 1)[0].rstrip("/")
    for name, platform in CONTAINER_ACTIONS.items():
        if ref.endswith(".github/actions/" + name):
            return platform
    return None


def check_call_sites(root: Path, files: list[Path], refs: dict[str, str]) -> int:
    """C: a literal handed to one of the four actions matches ITS platform.

    B cannot see this: `:winamd64` passed to run-in-linux-container is a
    perfectly canonical tag, for the wrong operating system.
    """
    bad = 0
    for path in files:
        rel = path.relative_to(root).as_posix()
        pending = None  # (platform, indent of the `uses:` line)
        for lineno, line in enumerate(
                path.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n"), 1):
            uses = USES_RE.match(line)
            if uses:
                platform = action_platform(uses.group(2))
                pending = (platform, len(uses.group(1))) if platform else None
                continue
            if pending is None:
                continue
            item = LIST_ITEM_RE.match(line)
            if item and len(item.group(1)) <= pending[1]:
                pending = None  # next step; this one passed no image literal
                continue
            image = IMAGE_RE.match(line)
            if not image:
                continue
            value = image.group(1)
            found = REF_RE.search(value)
            # No literal means an expression or the omitted input -- both resolve
            # through the action default, and any literal inside the expression
            # was already judged by check_literals.
            if found and found.group(1) != refs[pending[0]].rsplit(":", 1)[1]:
                fail("%s:%d: a %s action is handed ':%s'; it must run %s"
                     % (rel, lineno, pending[0], found.group(1), refs[pending[0]]))
                bad += 1
            pending = None
    return bad


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HUB_ROOT
    refs = canonical_refs()
    print("== CI image refs under %s ==" % root)
    print("   linux   %s" % refs["linux"])
    print("   windows %s" % refs["windows"])

    files = yaml_files(root)
    if not files:
        # A gate that checks nothing must not report green.
        fail("no workflow or action YAML under %s/.github -- wrong root?" % root)
        return 1

    bad, checked = check_action_defaults(root, refs)
    lit_bad, used_excuses = check_literals(root, files, refs)
    bad += lit_bad
    bad += check_call_sites(root, files, refs)

    for stale in sorted(set(EXCUSED) - used_excuses):
        fail("EXCUSED row is stale (that tag no longer appears): %s -- delete it" % stale)
        bad += 1

    if bad:
        sys.stderr.write("CI IMAGE REF GATE FAILED (%d finding(s))\n" % bad)
        return 1
    print("CI IMAGE REFS OK (%d YAML file(s), %d container action default(s))"
          % (len(files), checked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
