#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""verify_dockerfile_context_paths.py -- every COPY/ADD source and every
`--mount=type=bind,source=` in EVERY Dockerfile resolves inside that
Dockerfile's build context.

The class: a file moves or is deleted, the Dockerfile that names it is not
touched, and nothing complains until someone runs that build -- where BuildKit
fails during context checksum, before the first instruction, so the message
names a path and not the lane that died. Two live instances stood for weeks:
Dockerfile.sccache-write-probe mounted a script an archive sweep had moved into
diagnostics/archive/, and Dockerfile.probe mounted windows/upstream/
sccache-nvcc-quote-fix after #137 deleted it -- the second killed EVERY probe
solve, live probes included. Both are static facts about the tree.

linux/scripts/verify_script_copy_coverage.py is the sibling gate and answers a
different question: it asks whether a path referenced INSIDE the image was
provided (/opt/scripts only, Linux only). This one asks whether the host-side
source exists at all, for every Dockerfile in the repo and both platforms.
docs/code-quality-tooling.md#dockerfile-context-paths-context-paths

Scope / limits, chosen so a false red is impossible without a table entry:
  - `--from=` COPYs and `from=` mounts name a stage or image, not the context;
    they are out of scope by construction.
  - A `${VAR}` segment becomes a glob wildcard, so a build-arg templated path
    passes when SOME concrete value exists (the arg is not knowable statically).
  - Absolute and URL sources are not context paths and are skipped.
  - CONTEXTS holds every Dockerfile whose context is not the repo root, and
    GENERATED the few sources a documented step produces before the build.
    Both are per-Dockerfile, so an entry can never widen to another image.

Exit status: non-zero iff any source does not resolve.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# The build context each Dockerfile is solved with, repo-relative, for the ones
# that are NOT solved from the repo root. Every value is the context its caller
# actually passes -- the caller is named so a drift is checkable, not assumed.
CONTEXTS: dict[str, str] = {
    # windows/Build-Buildkit.ps1 solves this one with -Context 'windows'
    # (windows/.dockerignore, not the root one, applies to it).
    "windows/Dockerfile.nvidia": "windows",
    # linux/webserver/build-and-run.sh solves from linux/ -- the COPY sources
    # are spelled ./webserver/... , which only resolves one level up.
    "linux/webserver/Dockerfile": "linux",
    # llm-stack's compose/build solves in place, next to entrypoint.sh.
    "linux/llm-stack/Dockerfile": "linux/llm-stack",
}

# Dockerfiles whose context is a directory GENERATED at run time, so no path in
# this checkout can stand in for it. Not an allowlist for missing files: the
# whole Dockerfile is off-subject because its context is not in the repo.
GENERATED_CONTEXT: dict[str, str] = {
    # Test-BuildCopy.ps1 mints a temp probe dir, writes hello.txt into it and
    # solves both files with `--local context=$probeDir`.
    "windows/scripts/diagnostics/probe-build-copy/Dockerfile": "Test-BuildCopy.ps1",
    "windows/scripts/diagnostics/probe-build-copy/Dockerfile.heavy": "Test-BuildCopy.ps1",
}

# Sources a documented step produces INTO the context before the build runs, so
# they are legitimately absent from a fresh checkout. Keyed by Dockerfile; the
# value names the producer, which is what makes the entry auditable.
GENERATED: dict[str, dict[str, str]] = {
    "linux/llm-stack/Dockerfile": {
        "ollama-binary.tar.zst": "linux/llm-stack/scripts/download-ollama.sh",
    },
}

# A FLOOR under the git answer below, not a substitute for it: `git ls-files`
# reports nothing in a checkout git refuses (dubious ownership, a bind-mounted
# tree, a mirror with no .git), and the gate then grades somebody's `external/`
# scratch clone and buries this repo's own findings. Both answers, always.
SKIP_DIRS = {".git", "external", "out", "logs", "node_modules", "__pycache__", ".venv", "third_party"}
NOT_A_CONTEXT_PATH = re.compile(r"^(?:[A-Za-z]:[\\/]|/|https?://|git@|github\.com/)")
VAR = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*")
LEADING_DOT = re.compile(r"^(?:\./)+")
DIRECTIVE = re.compile(r"^#\s*escape\s*=\s*(\S)", re.IGNORECASE)
BIND_MOUNT = re.compile(r"--mount=type=bind,\S+")
MOUNT_KV = re.compile(r"([A-Za-z_]+)=([^,\s]+)")
INSTRUCTION = re.compile(r"^\s*(COPY|ADD)\s+(.*)$", re.IGNORECASE)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def escape_char(text: str) -> str:
    """The line-continuation character. Windows Dockerfiles open with
    `# escape=\\`` because their paths are full of backslashes -- reading them
    with the default rule joins nothing and every COPY goes unseen."""
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("#"):
            break
        found = DIRECTIVE.match(stripped)
        if found:
            return found.group(1)
    return "\\"


def logical_lines(text: str) -> list[tuple[int, str]]:
    """(1-based line number of the instruction, whole instruction) pairs, with
    continuations folded in and comment lines between them dropped."""
    joiner = escape_char(text)
    out: list[tuple[int, str]] = []
    pending: list[str] = []
    origin = 0
    for number, raw in enumerate(text.splitlines(), start=1):
        body = raw.rstrip()
        if pending and body.lstrip().startswith("#"):
            continue
        if not pending:
            origin = number
        if body.endswith(joiner):
            pending.append(body[:-1])
            continue
        out.append((origin, " ".join(pending + [body])))
        pending = []
    if pending:
        out.append((origin, " ".join(pending)))
    return out


def mount_sources(line: str) -> list[str]:
    """Host paths a line's bind mounts read. `from=` names a stage or an image,
    whose contents this gate cannot and must not judge."""
    out = []
    for mount in BIND_MOUNT.findall(line):
        fields = dict(MOUNT_KV.findall(mount))
        if "from" in fields:
            continue
        source = fields.get("source") or fields.get("src")
        if source:
            out.append(source)
    return out


def copy_sources(line: str) -> list[str]:
    """Context paths one COPY/ADD reads, or [] when it copies from a stage."""
    found = INSTRUCTION.match(line)
    if not found:
        return []
    rest = found.group(2)
    if rest.lstrip().startswith("["):
        rest = rest.strip().strip("[]").replace('"', " ").replace(",", " ")
    tokens = rest.split()
    if any(t.lower().startswith("--from=") for t in tokens):
        return []
    operands = [t for t in tokens if not t.startswith("--")]
    return operands[:-1] if len(operands) >= 2 else []


def resolves(context: Path, source: str) -> bool:
    """Does `source` name at least one path under the context? A ${VAR} segment
    becomes a wildcard: the build arg picks one of several real paths, and which
    one is not a static fact."""
    pattern = LEADING_DOT.sub("", VAR.sub("*", source.replace("\\", "/"))).rstrip("/")
    if not pattern:
        return context.is_dir()
    return any(context.glob(pattern))


def check(path: Path, rel: str) -> list[tuple[int, str]]:
    """[(line number, unresolved source)] for one Dockerfile."""
    if rel in GENERATED_CONTEXT:
        return []
    context = ROOT / CONTEXTS.get(rel, ".")
    produced = GENERATED.get(rel, {})
    missing = []
    for number, line in logical_lines(read(path)):
        for source in mount_sources(line) + copy_sources(line):
            if source in produced or NOT_A_CONTEXT_PATH.match(source):
                continue
            if not resolves(context, source):
                missing.append((number, source))
    return missing


def tracked() -> set[str] | None:
    """Every path git tracks, or None outside a work tree. An `external/` or
    `out/` checkout is somebody's scratch copy with its own build contract; the
    subject of this gate is what the repo ships."""
    try:
        listing = subprocess.run(["git", "-C", str(ROOT), "ls-files"], check=True,
                                 capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return set(listing.split("\n"))


def dockerfiles() -> list[tuple[Path, str]]:
    """Every tracked Dockerfile, as (path, repo-relative path). A name like
    Dockerfile.ProbeShell.Tests.ps1 is a test ABOUT a Dockerfile, not one."""
    known = tracked()
    out = []
    for path in sorted(ROOT.rglob("Dockerfile*")):
        rel = path.relative_to(ROOT).as_posix()
        if not path.is_file() or set(rel.split("/")[:-1]) & SKIP_DIRS:
            continue
        if path.name != "Dockerfile" and not re.fullmatch(r"Dockerfile\.[A-Za-z0-9_-]+", path.name):
            continue
        # No work tree (the suites' throwaway roots): grade everything found.
        # Erring wide adds subjects, never drops one.
        if known is not None and rel not in known:
            continue
        out.append((path, rel))
    return out


def main() -> int:
    subjects = dockerfiles()
    if not subjects:
        print("no Dockerfiles found", file=sys.stderr)
        return 1
    broken = 0
    for path, rel in subjects:
        missing = check(path, rel)
        if not missing:
            print(f"\033[0;32m[ OK ]\033[0m {rel}")
            continue
        broken += len(missing)
        print(f"\033[0;31m[FAIL]\033[0m {rel}: {len(missing)} source(s) not in the build context "
              f"({CONTEXTS.get(rel, '<repo root>')}):")
        for number, source in missing:
            print(f"    L{number}: {source}")
    if broken:
        print(f"\n{broken} unresolvable Dockerfile source(s). Repair the path, or -- if a "
              f"documented step produces it -- add it to GENERATED with its producer.")
        return 1
    print(f"\n{len(subjects)} Dockerfile(s): every COPY and bind-mount source resolves.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
