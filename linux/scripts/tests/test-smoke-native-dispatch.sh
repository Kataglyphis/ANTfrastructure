#!/usr/bin/env bash
# Private fake tools cover dispatch, output and cleanup, not media decoding, camera hardware or containers.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "native media dispatch preserves tool verdict and failure contexts"
t_assert_ok python3 "${TESTS_DIR}/smoke_native_dispatch_tests.py" "${1:-${TESTS_DIR}/../06-packaging}"
t_summary
