#!/usr/bin/env bash
# Private source and destination trees cover guarded links and copied closures, not system installation or SDK builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "GCC and Vulkan link policies preserve guards, flags and source closures"
t_assert_ok python3 "${TESTS_DIR}/guarded_link_tests.py" "${1:-${TESTS_DIR}/..}"
t_summary
