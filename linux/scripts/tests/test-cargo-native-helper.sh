#!/usr/bin/env bash
# Header/selection fixtures do not prove actual target execution or finished package inference.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare work
t_fixture_workspace_init work
source "${TESTS_DIR}/synthetic-elf-fixture.sh"
t_write_synthetic_elf python3 --strsz "${work}/module.so" '' ''
TEST_CARGO_NATIVE_ELF="${work}/module.so" python3 -I "${TESTS_DIR}/cargo_native_helper_tests.py"
