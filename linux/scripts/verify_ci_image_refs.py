#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Every CI lane in the family runs in the SAME two images, and this proves it.

versions.env owns the convention (IMAGE_REGISTRY_PREFIX + CI_IMAGE_LINUX_TAG /
CI_IMAGE_WINDOWS_TAG). Each language has exactly ONE way to ask it for the
composed ref: YAML omits the `image:` input and inherits the four container
composite actions' DEFAULT, Bash calls linux/scripts/ci-image-ref.sh, PowerShell
calls Get-CiImageReference. Anything that spells the ref out instead is a COPY,
and a copy is frozen at the tag it was written on. These four checks are what
make a copy, or a default that stopped matching, visible:

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
  D. No COPY of a currently-canonical ref: not in a tracked *.sh / *.ps1 /
     *.psm1 anywhere under the root, and not as the whole value of a YAML
     mapping key other than `default:`. A/B/C were all blind to this, which is
     how three copies survived a green verdict: they were CANONICAL, so B waved
     them through, and C only ever compared platforms. `default:` is the one
     exemption because it is the OWNER of the value -- an action input's
     default (graded by A) or a `workflow_call` input's, which has nowhere else
     to come from. Everything else has an owner to ask.

Deliberate overrides are not forbidden, they are declared: add a row to EXCUSED
with the reason. A stale row (the tag no longer appears) fails too, so the list
can only shrink by being true. D has no such route on purpose: a lane that
means to pin an OLDER image writes a non-canonical tag and is judged by B, so
"I must spell today's ref out here" has no case left to make.

Usage:
    python3 linux/scripts/verify_ci_image_refs.py           # this repo
    python3 linux/scripts/verify_ci_image_refs.py <root>    # a consumer repo

The consumer root exists for the same reason lint-workflows.sh takes one: a
submodule checkout puts this script INSIDE the consumer, where the default root
resolves to ANTfrastructure and the gate would report green over the wrong tree.
versions.env always comes from THIS repo regardless of the root.

A/B/C read <root>/.github/ by glob; D's script half reads the git INDEX through
gate_scope (its rule 3), because a walk of a working tree picks up .venv/,
build-*/ and .pub-cache/ -- measured 38 such files in one consumer against 21
tracked ones -- and cannot see that third_party/ is a separate root with its own
run. The wrong-root case is caught before that by A/B/C's "no workflow or action
YAML" refusal.
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

# D's script half. .psm1 is in the list because Get-CiImageReference lives in
# one and a module is exactly where a "shared" copy would be parked.
SCRIPT_PATTERNS = ("*.sh", "*.ps1", "*.psm1")

REF_RE = re.compile(r"kataglyphis_beschleuniger:([A-Za-z0-9][A-Za-z0-9._-]*)")
USES_RE = re.compile(r"^(\s*)(?:-\s+)?uses:\s*(\S+)")
# D's YAML half: a mapping line whose VALUE is the whole ref. A ref inside a
# `run:` block or an expression is not this shape, and is judged by B and C.
YAML_ENTRY_RE = re.compile(r"^\s*(?:-\s+)?([A-Za-z_][A-Za-z0-9_.-]*):\s*(.*?)\s*$")
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


def script_files(root: Path) -> list[Path]:
    """Tracked shell and PowerShell under the root. gate_scope owns the rules."""
    return [root / rel for rel in gate_scope.tracked(str(root), SCRIPT_PATTERNS)]


def frozen_ref_re(refs: dict[str, str]) -> re.Pattern:
    """Matches a currently-canonical ref, and only when it is the WHOLE tag.

    The trailing guard is what keeps the per-arch children of the manifest out
    of it: `...:latest-cross-arm64` in smoke-runtime-image.sh is a real tag the
    build chain produces, not a copy of the CI ref that starts the same way.

    `.` is deliberately NOT in that guard, though a tag may contain one. Every
    derived tag this repo builds separates with `-` (tag-naming.sh: cross-sdk-,
    runtime-package-, ...), so excluding `.` bought nothing -- and it cost the
    commonest prose shape there is, a sentence ending "runs in <ref>.", which
    is precisely where two of the three surviving copies were found. A dotted
    tag that starts with a canonical one would be a loud false positive; a copy
    hidden behind a full stop is a silent false negative, and this gate exists
    because the silent kind is what got through.
    """
    return re.compile(
        "(?:%s)(?![A-Za-z0-9_-])"
        % "|".join(re.escape(ref) for ref in sorted(set(refs.values()))))


def ask_instead(path: Path) -> str:
    """The owner THIS file's language has, named in the finding.

    Keyed on the suffix rather than a lookup table: git's pathspec matching is
    case-insensitive wherever core.ignorecase is on, so a `Build.PS1` must not
    be able to turn a finding into a KeyError.
    """
    if path.suffix.lower() == ".sh":
        return "bash <ANTfrastructure>/linux/scripts/ci-image-ref.sh [--windows]"
    return "Get-CiImageReference [-Windows] (WindowsContainerImage.Common.psm1)"


def check_script_copies(root: Path, files: list[Path], frozen: re.Pattern) -> int:
    """D, script half: a script must ASK for the ref, never spell it out."""
    bad = 0
    for path in files:
        rel = path.relative_to(root).as_posix()
        # Strict decoding, like every other reader here: errors="replace" would
        # turn a file this gate cannot read into a silent green, which is the
        # exact failure mode it was written to end.
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

    # Only after the wrong-root refusal above: gate_scope needs a checkout, and
    # "you pointed me at a tree with no workflows" is the more useful message.
    try:
        scripts = script_files(root)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    # A repo may legitimately have no shell or PowerShell at all (ANThology has
    # none), so an empty script set is allowed -- and SAID, not assumed.
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
