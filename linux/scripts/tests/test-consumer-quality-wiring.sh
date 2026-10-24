#!/usr/bin/env bash
# The Python fixture mutates live CI call arguments and the weekly inventory verdict.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/consumer_quality_wiring_tests.py"
