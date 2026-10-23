#!/usr/bin/env bash
# Raw pin states and copied API initialization are tested without installer downloads or execution.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/raw_pin_reader_tests.py" \
  "${1:-${TESTS_DIR}/../02-toolchain}" "${2:-${TESTS_DIR}/../01-core/load-versions-env.sh}"
