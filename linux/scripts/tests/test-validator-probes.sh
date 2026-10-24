#!/usr/bin/env bash
# Fake compiler fixtures cover command order and source failures, not sanitizer or libFuzzer runtime correctness.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "validator source fixtures and version fallbacks preserve caller policy"
t_assert_ok python3 "${TESTS_DIR}/validator_probe_tests.py" "${1:-${TESTS_DIR}/../06-packaging/validate-compilers.sh}"
t_summary
