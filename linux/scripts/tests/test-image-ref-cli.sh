#!/usr/bin/env bash
# Offline receipts cover argument and source closures, not real container or registry execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "image-ref CLI policies and required companion closures"
t_assert_ok python3 "${TESTS_DIR}/image_ref_cli_tests.py" "${1:-${TESTS_DIR}/../01-core}"
t_summary
