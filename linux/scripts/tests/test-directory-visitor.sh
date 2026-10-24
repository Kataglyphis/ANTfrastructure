#!/usr/bin/env bash
# Original loop slots and raw path bytes are checked offline without compilers, engines or host library changes.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/directory_visitor_tests.py" \
  "${1:-${TESTS_DIR}/../01-core/platform.sh}" \
  "${2:-${TESTS_DIR}/../01-core/cross-env.sh}" \
  "${3:-${TESTS_DIR}/../02-toolchain/llvm.sh}"
