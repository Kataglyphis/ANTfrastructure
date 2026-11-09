#!/usr/bin/env bash
# Child environment and cleanup assertions cover Unix cache separation, not .NET's cache file parser.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_case "mutation child caches stay private through success, failure and timeout"
t_needs "POSIX Python process groups" t_posix_python
t_assert_ok python3 "${TESTS_DIR}/mutation_cache_tests.py" "${TESTS_DIR}/../../../docs/scripts/verify_mutations.py"
t_summary
