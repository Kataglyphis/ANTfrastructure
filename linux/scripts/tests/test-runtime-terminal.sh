#!/usr/bin/env bash
# Synthetic sealed-unit and journal controls do not prove a real runtime, source authenticity or GPU inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/runtime_terminal_tests.py" "$@"
