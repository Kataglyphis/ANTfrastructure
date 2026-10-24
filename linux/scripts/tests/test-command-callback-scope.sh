#!/usr/bin/env bash
# Provided command functions retain user variables without starting installers or packaging real wheels.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/command_callback_scope_tests.py" "${1:-${TESTS_DIR}/..}"
