#!/usr/bin/env bash
# Compiled fake adapters prove Rust policy/concurrency, not a real ORT ABI, Windows loader or GPU inference.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-workspace-fixture.sh
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare ROOT work
t_fixture_workspace_init work ROOT
rustc --edition=2021 --deny warnings --test "${ROOT}/shared/rust/tests/ort_plugin_eps_test.rs" -o "${work}/policy"
ORT_PLUGIN_TEST_ROOT="${work}" "${work}/policy" --nocapture >"${work}/normal.log" 2>&1
cat "${work}/normal.log"
t_case 'compiled Rust assertions execute without skips'
t_assert_grep "${work}/normal.log" '^test result: ok\. [1-9][0-9]* passed; 0 failed; 0 ignored;'
t_case 'a planted false assertion fails independently of production policy'
status=0
ORT_PLUGIN_TEST_ROOT="${work}" ORT_PLUGIN_FAIL_CONTROL=1 "${work}/policy" --exact negative_control >"${work}/control.log" 2>&1 || status=$?
t_assert_eq 101 "${status}"
t_assert_grep "${work}/control.log" 'negative assertion control'
t_summary
