#!/usr/bin/env bash
# Help and forwarding receipts cover text, argument preservation and dependency scope, not builds or images.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "SDK and runtime help preserve exact bytes and independent env-contract scope"
t_assert_ok python3 "${TESTS_DIR}/runtime_sdk_help_tests.py" "${1:-${TESTS_DIR}/..}"
t_summary
