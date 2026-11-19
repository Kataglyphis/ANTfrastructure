#!/usr/bin/env python3
"""Preview or remove reviewed, unused QA venvs; this grants no build or runtime acceptance."""

from __future__ import annotations

import argparse
import importlib
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('review', 'root', 'directory'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--protect', type=Path, action='append', required=True)
    parser.add_argument('--authorization', type=Path)
    parser.add_argument('--engine', default='nerdctl')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
    worker = importlib.import_module('qa_venv_cleanup')
    result = worker.cleanup(args.review, args.root, args.protect, args.directory,
                            args.engine, args.authorization, args.apply)
    print(json.dumps({'status': result['status'], 'selected': len(result['candidates']),
                      'removed': len(result['removed']), 'directory': str(args.directory)}))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f'QA cleanup refused: {error}', file=sys.stderr)
        raise SystemExit(1) from error
