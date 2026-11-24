#!/usr/bin/env bash
# Tests the real patch asset's selection and drift, not a compiler, HIP kernel or torchvision wheel.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REPO_ROOT="$(cd "${TESTS_DIR}/../../.." && pwd)"
t_case 'Windows torchvision host CXX cache patch'
status=0
python3 "${TESTS_DIR}/torchvision_cache_patch_tests.py" "${REPO_ROOT}" || status=$?
t_assert_eq 0 "${status}" 'the actual patch preserves compiler routes and refuses source drift'
t_summary
