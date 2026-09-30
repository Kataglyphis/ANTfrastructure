#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Every COPY/ADD source and bind-mount source in every Dockerfile resolves inside its build context.

docs/code-quality-tooling.md#dockerfile-context-paths-context-paths
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Build contexts other than the repo root, each as its named caller passes it.
CONTEXTS: dict[str, str] = {
    # windows/Build-Buildkit.ps1 passes -Context 'windows', so windows/.dockerignore applies.
    "windows/Dockerfile.nvidia": "windows",
    # linux/webserver/build-and-run.sh solves from linux/, hence the ./webserver/... sources.
    "linux/webserver/Dockerfile": "linux",
    # llm-stack's compose/build solves in place, next to entrypoint.sh.
    "linux/llm-stack/Dockerfile": "linux/llm-stack",
}

# Dockerfiles whose whole context is generated at run time, so they are off-subject.
GENERATED_CONTEXT: dict[str, str] = {
    # Test-BuildCopy.ps1 solves both with `--local context=$probeDir`, a temp dir it fills.
    "windows/scripts/diagnostics/probe-build-copy/Dockerfile": "Test-BuildCopy.ps1",
    "windows/scripts/diagnostics/probe-build-copy/Dockerfile.heavy": "Test-BuildCopy.ps1",
}

# Sources a named producer writes into the context before the build, per Dockerfile.
GENERATED: dict[str, dict[str, str]] = {
    "linux/llm-stack/Dockerfile": {
        "ollama-binary.tar.zst": "linux/llm-stack/scripts/download-ollama.sh",
    },
}

# A floor under `git ls-files`, which reports nothing in a checkout git refuses.
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
    """The line-continuation character, from a `# escape=` directive (Windows Dockerfiles use a backtick)."""
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
    """(1-based line number, whole instruction) pairs, continuations folded and interior comments dropped."""
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
    """Host paths a line's bind mounts read; `from=` mounts name a stage or image and are skipped."""
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
    """Does `source` name a path under the context? ${VAR} becomes a wildcard, since its value is not static."""
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
    """Every path git tracks, or None outside a work tree."""
    try:
        listing = subprocess.run(["git", "-C", str(ROOT), "ls-files"], check=True,
                                 capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return set(listing.split("\n"))


def dockerfiles() -> list[tuple[Path, str]]:
    """Every tracked Dockerfile as (path, rel); Dockerfile.X.Tests.ps1 is a test about one, not one."""
    known = tracked()
    out = []
    for path in sorted(ROOT.rglob("Dockerfile*")):
        rel = path.relative_to(ROOT).as_posix()
        if not path.is_file() or set(rel.split("/")[:-1]) & SKIP_DIRS:
            continue
        if path.name != "Dockerfile" and not re.fullmatch(r"Dockerfile\.[A-Za-z0-9_-]+", path.name):
            continue
        # Without a work tree (the suites' throwaway roots) grade everything: erring wide drops nothing.
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
