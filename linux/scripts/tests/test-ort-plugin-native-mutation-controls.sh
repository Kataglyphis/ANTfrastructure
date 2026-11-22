#!/usr/bin/env bash
# Compile-valid mutants prove fixture semantics; fake ORT callbacks do not prove native ABI or GPU inference.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
work="$(t_mktemp -d)" || exit 1
result="${work}/native-controls.log"
status=0
python3 "${TESTS_DIR}/ort_plugin_native_tests.py" --mutation-controls >"${result}" 2>&1 || status=$?
cat "${result}"
t_assert_eq 0 "${status}"
t_assert_grep "${result}" '^native mutation controls: 9 semantic cases$'
t_summary
