#!/usr/bin/env bash
# Private profiles exercise source-time expansion and required imports, not compiler behavior or installed permissions.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "native GCC environment profiles and image closures"
t_assert_ok python3 "${TESTS_DIR}/native_gcc_env_tests.py" "${1:-${TESTS_DIR}/..}"
t_summary
