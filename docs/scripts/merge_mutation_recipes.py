#!/usr/bin/env python3
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""Merge reviewed mutation recipes without silently replacing or weakening existing entries.

Preview is the default; --write persists a validated merge. Existing IDs may only
change when named with --replace. This verifies the edit anchors, not that mutants bite.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

from verify_mutations import MutationEntry, load, relative_file_path


def validate_anchor(root: Path, recipe: MutationEntry) -> None:
    relative = relative_file_path(recipe["target"], "mutation target")
    target = (root / relative).resolve(strict=True)
    if not target.is_relative_to(root):
        raise ValueError(f"mutation target leaves root: {relative}")
    find = recipe["find"]
    if not isinstance(find, str) or not find:
        raise ValueError(f"{recipe['id']}: find must be nonempty text")
    count = target.read_text(encoding="utf-8").count(find)
    if count != 1:
        raise ValueError(f"{recipe['id']}: expected one anchor, found {count}")


def merge(root: Path, current: list[MutationEntry], incoming: list[MutationEntry], updates: set[str]) -> list[MutationEntry]:
    positions = {recipe["id"]: index for index, recipe in enumerate(current)}
    seen: set[str] = set()
    used: set[str] = set()
    result = list(current)
    for recipe in incoming:
        name = recipe["id"]
        if name in seen:
            raise ValueError(f"duplicate incoming mutation: {name}")
        seen.add(name)
        validate_anchor(root, recipe)
        if name not in positions:
            result.append(recipe)
        elif result[positions[name]] != recipe:
            if name not in updates:
                raise ValueError(f"existing mutation differs; pass --replace {name}")
            result[positions[name]] = recipe
            used.add(name)
    if updates - used:
        raise ValueError(f"unused --replace IDs: {', '.join(sorted(updates - used))}")
    return result


def save_atomic(path: Path, records: list[MutationEntry]) -> None:
    mode = path.stat().st_mode
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=path.parent, delete=False) as output:
            temporary = output.name
            json.dump(records, output, indent=1, ensure_ascii=False)
            output.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifests", nargs="+", type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--registry", type=Path, default=Path("docs/scripts/mutations.json"))
    parser.add_argument("--replace", action="append", default=[])
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        registry = args.registry if args.registry.is_absolute() else root / args.registry
        current = load(str(registry))
        incoming = [entry for manifest in args.manifests for entry in load(str(manifest))]
        result = merge(root, current, incoming, set(args.replace))
        if args.write:
            save_atomic(registry, result)
    except (OSError, TypeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"{'WROTE' if args.write else 'PREVIEW'}: {len(incoming)} recipe(s), registry {len(current)} -> {len(result)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
