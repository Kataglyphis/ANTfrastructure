#!/usr/bin/env python3
"""Prepare require-removal recipes from top-level functions; canonical merge, parse checks and real mutation runs remain required."""

from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path


def recipes(root: Path, target: str, test: str, prefix: str, why: str) -> list[dict[str, str]]:
    source = (root / target).read_text()
    entries: list[dict[str, str]] = []
    for function in ast.parse(source).body:
        if not isinstance(function, ast.FunctionDef):
            continue
        count = 0
        for node in ast.walk(function):
            if not isinstance(node, ast.Expr) or not isinstance(node.value, ast.Call):
                continue
            if not isinstance(node.value.func, ast.Name) or node.value.func.id != 'require':
                continue
            count += 1
            entries.append({'id':prefix + '.' + function.name.replace('_', '-') + '-' + str(count),
                            'target':target, 'find':ast.get_source_segment(source, node) or '', 'replace':'pass',
                            'test':test, 'why':why})
    if not entries:
        raise ValueError('No require expressions in top-level functions')
    return entries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    for name in ['target', 'test', 'prefix', 'why']:
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    entries = recipes(args.root, args.target, args.test, args.prefix, args.why)
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(entries, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
