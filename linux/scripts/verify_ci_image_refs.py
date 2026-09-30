#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Every CI lane runs in the images versions.env composes; a spelled-out copy of the ref is a finding.

Usage: verify_ci_image_refs.py [<consumer root>]  (versions.env always comes from this repo)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HUB_ROOT = HERE.parent.parent
VERSIONS_ENV = HERE / "01-core" / "versions.env"

sys.path.insert(0, str(HERE))
import gate_scope  # noqa: E402

# Action (under <root>/.github/actions/) -> image input -> canonical ref; `target-arch: arm64` selects `image-arm64`.
CONTAINER_ACTIONS = {
    "prepare-linux-ci-host": {"image": "linux"},
    "run-in-linux-container": {"image": "linux"},
    "prepare-windows-container-host": {"image": "windows", "image-arm64": "windows-arm64"},
    "run-in-windows-container": {"image": "windows", "image-arm64": "windows-arm64"},
}

# "<path>::<tag>" -> reason for a deliberate non-canonical tag; a row whose tag is gone is STALE and fails.
EXCUSED: dict[str, str] = {}

# .psm1 included: a module is exactly where a "shared" copy would be parked.
SCRIPT_PATTERNS = ("*.sh", "*.ps1", "*.psm1")

REF_RE = re.compile(r"kataglyphis_beschleuniger:([A-Za-z0-9][A-Za-z0-9._-]*)")
USES_RE = re.compile(r"^(\s*)(?:-\s+)?uses:\s*(\S+)")
# A mapping line whose whole value is the ref; refs inside `run:` or expressions are B's and C's.
YAML_ENTRY_RE = re.compile(r"^\s*(?:-\s+)?([A-Za-z_][A-Za-z0-9_.-]*):\s*(.*?)\s*$")
IMAGE_RE = re.compile(r"^\s*(image|image-arm64):\s*(.*?)\s*$")
LIST_ITEM_RE = re.compile(r"^(\s*)-\s")
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


# Each canonical ref's name and the versions.env key holding its tag.
TAG_KEYS = {
    "linux": "CI_IMAGE_LINUX_TAG",
    "windows": "CI_IMAGE_WINDOWS_TAG",
    "windows-arm64": "CI_IMAGE_WINDOWS_ARM64_TAG",
}


def canonical_refs() -> dict[str, str]:
    versions = load_versions(VERSIONS_ENV)
    missing = [k for k in ("IMAGE_REGISTRY_PREFIX", *TAG_KEYS.values()) if not versions.get(k)]
    if missing:
        raise SystemExit("FAIL: %s: missing %s" % (VERSIONS_ENV, ", ".join(missing)))
    prefix = versions["IMAGE_REGISTRY_PREFIX"]
    return {name: "%s:%s" % (prefix, versions[key]) for name, key in TAG_KEYS.items()}


def yaml_files(root: Path) -> list[Path]:
    gh = root / ".github"
    found = sorted(gh.glob("workflows/*.yml")) + sorted(gh.glob("workflows/*.yaml"))
    return found + sorted(gh.glob("actions/*/action.yml")) + sorted(gh.glob("actions/*/action.yaml"))


def script_files(root: Path) -> list[Path]:
    """Tracked shell and PowerShell under the root. gate_scope owns the rules."""
    return [root / rel for rel in gate_scope.tracked(str(root), SCRIPT_PATTERNS)]


def frozen_ref_re(refs: dict[str, str]) -> re.Pattern:
    """A canonical ref as a whole tag; `.` is not a continuation, so a ref ending a sentence still counts."""
    return re.compile(
        "(?:%s)(?![A-Za-z0-9_-])"
        % "|".join(re.escape(ref) for ref in sorted(set(refs.values()))))


def ask_instead(path: Path) -> str:
    """The ref owner for this file's language, by lower-cased suffix since pathspecs may ignore case."""
    if path.suffix.lower() == ".sh":
        return "bash <ANTfrastructure>/linux/scripts/ci-image-ref.sh [--windows|--windows-arm64]"
    return "Get-CiImageReference [-Windows [-TargetArch arm64]] (WindowsContainerImage.Common.psm1)"


def check_script_copies(root: Path, files: list[Path], frozen: re.Pattern) -> int:
    """D, script half: a script must ASK for the ref, never spell it out."""
    bad = 0
    for path in files:
        rel = path.relative_to(root).as_posix()
        # Strict decoding: errors="replace" would turn an unreadable file into a silent green.
        text = path.read_text(encoding="utf-8")
        for n, line in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
            if not frozen.search(line):
                continue
            fail("%s:%d: a spelled-out copy of the family CI image ref, frozen at "
                 "today's tag. Ask the owner instead: %s\n      %s"
                 % (rel, n, ask_instead(path), line.strip()))
            bad += 1
    return bad


def check_yaml_copies(root: Path, files: list[Path], frozen: re.Pattern) -> int:
    """D, YAML half: `KEY: <the family ref>` is a copy; `default:` is the owner."""
    bad = 0
    for path in files:
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        for n, line in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
            entry = YAML_ENTRY_RE.match(line)
            if not entry:
                continue
            key, value = entry.group(1), entry.group(2).strip().strip("'\"")
            if key == "default" or not frozen.fullmatch(value):
                continue
            fail("%s:%d: `%s:` is a copy of the family CI image ref. The four "
                 "container actions carry it as their `image:` input default -- "
                 "omit the input rather than hoisting the ref into YAML.\n      %s"
                 % (rel, n, key, line.strip()))
            bad += 1
    return bad


def image_input_default(text: str, name: str = "image") -> str | None:
    """The `default:` of top-level input `name`, or None; hand-parsed because the gate runs on the stdlib alone."""
    # The input NAME inside an action's `inputs:` block, not a value.
    input_key = re.compile(r"^  %s:\s*$" % re.escape(name))
    lines = text.replace("\r\n", "\n").split("\n")
    for i, line in enumerate(lines):
        if not input_key.match(line):
            continue
        for follow in lines[i + 1:]:
            if follow.strip() and not follow.startswith("    "):
                return None  # next input reached, no default
            m = DEFAULT_RE.match(follow)
            if m:
                return m.group(1).strip().strip("'\"")
    return None


def check_action_defaults(root: Path, refs: dict[str, str]) -> tuple[int, int]:
    """A: every image input default is present and equals its composed ref."""
    bad = seen = 0
    for name, inputs in sorted(CONTAINER_ACTIONS.items()):
        path = root / ".github" / "actions" / name / "action.yml"
        if not path.is_file():
            continue
        rel = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8")
        for input_name, platform in sorted(inputs.items()):
            seen += 1
            value = image_input_default(text, input_name)
            if value is None:
                fail("%s: the `%s` input has no `default:` -- callers would have to "
                     "re-type the tag, which is the drift this gate exists to stop." % (rel, input_name))
                bad += 1
            elif value != refs[platform]:
                fail("%s: `%s` default is %s, versions.env composes %s"
                     % (rel, input_name, value, refs[platform]))
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
    """B: every literal tag under .github/ is one of the canonical ones."""
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


def action_inputs(uses: str) -> dict[str, str] | None:
    """The image inputs of a `uses:` reference to one of the four container actions."""
    ref = uses.strip().strip("'\"").split("@", 1)[0].rstrip("/")
    for name, inputs in CONTAINER_ACTIONS.items():
        if ref.endswith(".github/actions/" + name):
            return inputs
    return None


def check_call_sites(root: Path, files: list[Path], refs: dict[str, str]) -> int:
    """C: a literal handed to one of the four actions matches that input's ref, a canonical-but-wrong tag B cannot see."""
    bad = 0
    for path in files:
        rel = path.relative_to(root).as_posix()
        pending = None  # (the action's image inputs, indent of the `uses:` line)
        for lineno, line in enumerate(
                path.read_text(encoding="utf-8").replace("\r\n", "\n").split("\n"), 1):
            uses = USES_RE.match(line)
            if uses:
                inputs = action_inputs(uses.group(2))
                pending = (inputs, len(uses.group(1))) if inputs else None
                continue
            if pending is None:
                continue
            item = LIST_ITEM_RE.match(line)
            if item and len(item.group(1)) <= pending[1]:
                pending = None  # next step; this one passed no image literal
                continue
            image = IMAGE_RE.match(line)
            # An image input this action does not have is actionlint's to report.
            if not image or image.group(1) not in pending[0]:
                continue
            platform = pending[0][image.group(1)]
            found = REF_RE.search(image.group(2))
            # No literal resolves through the action default; literals in expressions were check_literals'.
            if found and found.group(1) != refs[platform].rsplit(":", 1)[1]:
                fail("%s:%d: `%s:` of a %s action is handed ':%s'; it must run %s"
                     % (rel, lineno, image.group(1), platform.split("-")[0], found.group(1), refs[platform]))
                bad += 1
    return bad


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HUB_ROOT
    refs = canonical_refs()
    print("== CI image refs under %s ==" % root)
    for name, ref in refs.items():
        print("   %-13s %s" % (name, ref))

    files = yaml_files(root)
    if not files:
        # A gate that checks nothing must not report green.
        fail("no workflow or action YAML under %s/.github -- wrong root?" % root)
        return 1

    # After the wrong-root refusal, whose message is more useful than gate_scope's.
    try:
        scripts = script_files(root)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    # A repo may legitimately have no scripts at all, so an empty set is allowed but reported.
    gate_scope.assert_non_empty(scripts, root, SCRIPT_PATTERNS, "allow", "ci-image-refs")

    bad, checked = check_action_defaults(root, refs)
    lit_bad, used_excuses = check_literals(root, files, refs)
    bad += lit_bad
    bad += check_call_sites(root, files, refs)
    frozen = frozen_ref_re(refs)
    bad += check_yaml_copies(root, files, frozen)
    bad += check_script_copies(root, scripts, frozen)

    for stale in sorted(set(EXCUSED) - used_excuses):
        fail("EXCUSED row is stale (that tag no longer appears): %s -- delete it" % stale)
        bad += 1

    if bad:
        sys.stderr.write("CI IMAGE REF GATE FAILED (%d finding(s))\n" % bad)
        return 1
    print("CI IMAGE REFS OK (%d YAML file(s), %d script(s), %d container action default(s))"
          % (len(files), len(scripts), checked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
