#!/usr/bin/env python3
"""Control one bounded runtime storage watcher; it cannot start, stop or accept the watched build."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import runtime_storage_guard as guard


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['launch', 'worker', 'seal'])
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--runtime-invocation', type=Path)
    parser.add_argument('--unit')
    parser.add_argument('--authorization', type=Path)
    args = parser.parse_args()
    guard.require(Path(guard.__file__).resolve() == Path(__file__).resolve().with_name('runtime_storage_guard.py'), 'Storage watcher companion belongs to another checkout')
    if args.action == 'launch':
        if args.runtime_invocation is None or args.unit is None or args.authorization is None:
            parser.error('launch requires runtime-invocation, unit and authorization')
        guard.launch(args.runtime_invocation, args.directory, args.unit, args.authorization)
    elif args.action == 'worker':
        return guard.worker(args.directory)
    else:
        guard.seal(args.directory)
    return 0


if __name__ == '__main__':
    sys.exit(main())
