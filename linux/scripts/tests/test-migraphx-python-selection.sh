#!/usr/bin/env bash
# Controlled CMake metadata proves selection and refusals, not a real extension build or GPU inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_python_selection_tests.py"
