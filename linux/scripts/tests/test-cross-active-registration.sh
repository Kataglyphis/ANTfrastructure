#!/usr/bin/env bash
# Captured bindings and cold copied libraries do not exercise apt, compilers or real image builds.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${TESTS_DIR}/cross_active_registration_tests.py" \
  "${1:-${TESTS_DIR}/../01-core}" \
  "${2:-${TESTS_DIR}/cross-active-registration-receipts.json}" \
  "${3:-${TESTS_DIR}/../..}"
