#!/usr/bin/env bash
# Help receipts and isolated env contracts cover documentation and runtime-only consumption, not builds or image contents.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "SDK and runtime help preserve exact bytes and independent env-contract scope"
t_assert_ok python3 "${TESTS_DIR}/runtime_sdk_help_tests.py" "${1:-${TESTS_DIR}/..}"
t_summary
