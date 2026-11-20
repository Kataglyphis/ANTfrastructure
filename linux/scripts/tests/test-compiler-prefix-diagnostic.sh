#!/usr/bin/env bash
# Synthetic prefix and failed-unit fixtures do not prove a compiled image, linker repair or hardware result.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/compiler_prefix_diagnostic_tests.py" "$@"
