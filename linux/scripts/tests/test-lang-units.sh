#!/usr/bin/env bash
# lang_units.py's report-only readers against hand-counted Rust, Dart, C/C++ and Python fixtures.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/lang_units_tests.py" "$@"
