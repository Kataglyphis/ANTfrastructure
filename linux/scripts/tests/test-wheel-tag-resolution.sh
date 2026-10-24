#!/usr/bin/env bash
# Guard status and lookup ordering are tested without compiler, installer or engine execution.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/wheel_tag_resolution_tests.py" "${1:-${TESTS_DIR}/../../..}"
