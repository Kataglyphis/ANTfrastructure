#!/usr/bin/env bash
# Keeps the Windows argument-limit proof independent of a native ShellCheck binary.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

t_case "Windows ShellCheck batches stay bounded and retain all findings"
out="$("${PREFLIGHT_PYTHON:-python3}" "${TESTS_DIR}/shellcheck_batch_tests.py")"
t_assert_eq "4 bounded runs; 4 findings merged" "${out}"
t_summary
