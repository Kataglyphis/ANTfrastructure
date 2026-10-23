#!/usr/bin/env bash
# Frozen original receipts cover source scope and argv; lint execution remains in the driver suites.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/lint_scope_init_tests.py"
