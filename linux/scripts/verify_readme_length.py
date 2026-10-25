#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""The README rule: a repository's root README.md stays at 100 lines or fewer, badges included.
docs/code-quality-tooling.md#readme-length-readme-length"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_scope

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
LIMIT = 100
RULE = "https://github.com/Kataglyphis/ANTfrastructure/blob/develop/docs/repository-family.md#the-readme-rule"


def count_lines(path: str) -> int:
    """Lines as an editor numbers them: a last line without a newline still counts."""
    with open(path, "rb") as fh:
        data = fh.read()
    return data.count(b"\n") + (1 if data and not data.endswith(b"\n") else 0)


def main() -> int:
    ap = argparse.ArgumentParser(description="Hold the root README.md to the family's README rule.")
    ap.add_argument("--root", default=None, help="the repository to grade (default: this repo)")
    args = ap.parse_args()
    try:
        root = gate_scope.resolve_root(args.root, ROOT)
    except gate_scope.ScopeError as exc:
        return gate_scope.die(exc)
    readme = os.path.join(root, "README.md")
    print(f"=== README length (at most {LIMIT} lines) ===", flush=True)
    if not os.path.isfile(readme):
        sys.stderr.write(f"FAIL: no README.md at {root}; every repository has one (the README rule: {RULE})\n")
        return 1
    count = count_lines(readme)
    if count > LIMIT:
        sys.stderr.write(
            f"FAIL: README.md is {count} lines, over the {LIMIT} the README rule allows, badges included.\n"
            f"      Move procedures, tables and history to docs/ and link them: {RULE}\n"
        )
        return 1
    print(f"OK: README.md is {count} lines")
    return 0


if __name__ == "__main__":
    sys.exit(main())
