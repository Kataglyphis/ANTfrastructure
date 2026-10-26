#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""A ${VAR} inside an ENV instruction reads the value VAR held BEFORE it, so a key
set two lines up in the SAME instruction expands EMPTY. Dockerfile.android shipped
PATH=/cmdline-tools/latest/bin:/platform-tools:/build-tools/36.0.0:: that way -- three
dead entries and an empty one, which POSIX reads as the working directory.
docs/code-quality-tooling.md#env-instruction-ordering-dockerfile-lint"""
import os
import re
import sys
from collections.abc import Iterator
from os import PathLike

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONT = re.compile(r"\\\s*$")
REF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=")
HEREDOC = re.compile(r"<<-?(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def instructions(path: str | PathLike[str]) -> Iterator[tuple[int, str]]:
    """(line, text) per instruction, continuations joined and interior comments
    dropped the way BuildKit drops them."""
    buf, start, heredoc = [], 0, ""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for num, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if heredoc:
                heredoc = "" if line.strip() == heredoc else heredoc
                continue
            if line.lstrip().startswith("#"):
                continue
            if not buf:
                if not line.strip():
                    continue
                start = num
            more = bool(CONT.search(line))
            buf.append(CONT.sub("", line).strip())
            if not more:
                text = " ".join(t for t in buf if t)
                # A heredoc body belongs to its instruction; its lines are not instructions of their own.
                match = HEREDOC.search(text)
                heredoc = match.group(2) if match else ""
                yield start, text
                buf = []
    if buf:
        yield start, " ".join(t for t in buf if t)


def tokens(body: str) -> list[str]:
    """Whitespace-split, honouring double quotes so a quoted PATH stays one token."""
    out, cur, quoted = [], "", False
    for char in body:
        if char == '"':
            quoted = not quoted
            cur += char
        elif char.isspace() and not quoted:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += char
    if cur:
        out.append(cur)
    return out


def env_offenders(body: str, args: set[str]) -> list[tuple[str, str]]:
    """(key, ref) for every value reading a key assigned EARLIER in this instruction.
    A key reading ITSELF is the inherit-and-extend idiom and is fine; a name that is
    also an ARG in scope resolves from the ARG, so it is fine too."""
    seen, bad = [], []
    for token in tokens(body):
        match = ASSIGN.match(token)
        if not match:
            continue
        key = match.group(1)
        for ref in REF.findall(token[match.end():]):
            if ref in seen and ref != key and ref not in args:
                bad.append((key, ref))
        seen.append(key)
    return bad


def scan(path: str | PathLike[str]) -> list[tuple[int, str, str]]:
    """Findings for one Dockerfile; ARG scope resets at every FROM, as BuildKit does."""
    args, out = set(), []
    for line, text in instructions(path):
        parts = text.split(None, 1)
        head = parts[0].upper()
        body = parts[1] if len(parts) > 1 else ""
        if head == "FROM":
            args = set()
        elif head == "ARG":
            args.update(t.split("=")[0] for t in tokens(body))
        elif head == "ENV":
            out.extend((line, k, r) for k, r in env_offenders(body, args))
    return out


def main(argv: list[str]) -> int:
    targets = argv[1:]
    if not targets:
        sys.stderr.write("usage: verify_dockerfile_env_order.py <Dockerfile>...\n")
        return 2
    bad = 0
    for rel in targets:
        path = rel if os.path.isabs(rel) else os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            sys.stderr.write(f"FAIL: not a file: {rel}\n")
            bad += 1
            continue
        for line, key, ref in scan(path):
            sys.stderr.write(
                f"{rel}:{line}: ENV {key} reads ${{{ref}}}, set in the SAME instruction -- it expands to "
                "the value before the instruction (empty here). Split the ENV in two.\n"
            )
            bad += 1
    if bad:
        sys.stderr.write(f"\nENV-ORDER LINT FAILED ({bad} finding(s))\n")
        return 1
    print(f"  ok: ENV ordering ({len(targets)} Dockerfile(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
