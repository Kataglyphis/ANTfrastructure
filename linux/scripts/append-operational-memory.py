#!/usr/bin/env python3
"""Append reviewed operational notes after controller and exact-prefix checks; no concurrent-writer authentication."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from operational_memory import append_memory


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--memory', type=Path, required=True)
    parser.add_argument('--expected-bytes', type=int, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--append-file', type=Path, required=True)
    parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    try:
        proof = append_memory(args.memory, args.expected_bytes, args.expected_sha256, args.append_file, args.directory)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'FAIL: {error}\n')
    print(json.dumps({'status': proof['status'], 'directory': str(args.directory),
                      'after_bytes': proof['after_bytes'], 'after_sha256': proof['after_sha256']}))


if __name__ == '__main__':
    main()
