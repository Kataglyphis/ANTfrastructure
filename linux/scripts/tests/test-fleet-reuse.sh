#!/usr/bin/env bash
# The fleet report is advisory on overlap and fatal on incomplete repository evidence.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/fleet_reuse_tests.py"
