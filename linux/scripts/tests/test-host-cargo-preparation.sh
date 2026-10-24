#!/usr/bin/env bash
# Stubbed providers expose host publication and strict failures without creating compiler wrappers or running Cargo.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/host_cargo_preparation_tests.py" "${1:-${TESTS_DIR}/..}"
