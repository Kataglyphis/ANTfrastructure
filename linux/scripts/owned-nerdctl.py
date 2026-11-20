#!/usr/bin/env python3
"""Exec the real engine with invocation labels so bounded runtime cleanup can reap every owned probe."""

import os
import sys
from pathlib import Path
from typing import NoReturn

from owned_nerdctl_args import owned_engine_command


def main() -> NoReturn:
    command = owned_engine_command(sys.argv[1:], os.environ['ANT_RUNTIME_ENGINE'], os.environ['ANT_RUNTIME_OWNER_LABEL'], os.environ['ANT_RUNTIME_RUN_ID'])
    assert Path(command[0]).resolve() != Path(__file__).resolve(), 'The runtime engine cannot recurse into its wrapper'
    os.execv(command[0], command)


if __name__ == '__main__':
    main()
