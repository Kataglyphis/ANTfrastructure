#!/usr/bin/env bash
# Executable fixtures cover pins, PATH and copied module failures, not interpreter ABI compatibility or Android builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "shared host interpreter selection retains caller policies"
t_assert_ok python3 "${TESTS_DIR}/host_python_pin_tests.py" "${1:-${TESTS_DIR}/..}"
t_summary
