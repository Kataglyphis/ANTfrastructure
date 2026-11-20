#!/usr/bin/env bash
# Policy, live-VM and fake-HIP fixtures cannot establish an installed bridge, real ORT ABI, Windows loading or GPU inference.
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
t_case 'loaded module lookup uses the actual file and preserves path bytes'
rustc --edition=2021 --deny warnings --test "${ROOT}/shared/rust/loaded_module.rs" -o "${work}/module-tests"
"${work}/module-tests" --nocapture > "${work}/module.log" 2>&1
cat "${work}/module.log"
t_assert_grep "${work}/module.log" '^test result: ok\. 10 passed; 0 failed; 0 ignored;'
t_case 'actual fresh-child status, descriptor isolation and timeout reaping'
rustc --edition=2021 --deny warnings --test "${ROOT}/shared/rust/bounded_process.rs" -o "${work}/process-tests"
"${work}/process-tests" --nocapture >"${work}/process.log" 2>&1
cat "${work}/process.log"
t_assert_grep "${work}/process.log" '^test result: ok\. 10 passed; 0 failed; 0 ignored;'
# shellcheck source=linux/scripts/lib/isolated-helper-compile.sh
source "${ROOT}/linux/scripts/lib/isolated-helper-compile.sh"
t_case 'isolated worker status survives supervisor ownership and concurrent callers'
compile_isolated_helper_object "${ROOT}" "${work}"
rustc --edition=2021 --deny warnings --test "${ROOT}/shared/rust/isolated_helper.rs" \
  -C "link-arg=${work}/isolated-helper.o" -o "${work}/isolated-tests"
declare isolated_output isolated_status
t_capture_command isolated_output isolated_status "${work}/isolated-tests" --nocapture
printf '%s\n' "${isolated_output}" | tee "${work}/isolated.log"
t_assert_eq 0 "${isolated_status}"
t_assert_grep "${work}/isolated.log" '^test result: ok\. 12 passed; 0 failed; 0 ignored;'
t_case 'actual Dart reaper cannot consume the worker status'
declare dart_output dart_status
t_capture_command dart_output dart_status bash "${ROOT}/linux/scripts/probe-rust-child-under-dart.sh" "${work}/dart with spaces"
printf '%s\n' "${dart_output}"
t_assert_eq 0 "${dart_status}"
t_assert_contains "${dart_output}" '17 byte(s) leaked'
t_case 'matching exit86 without real sanitizer teardown is refused'
t_capture_command dart_output dart_status bash "${ROOT}/linux/scripts/probe-rust-child-under-dart.sh" "${work}/early-exit" --teardown-negative-control
printf '%s\n' "${dart_output}"
t_assert_eq 1 "${dart_status}"
t_assert_contains "${dart_output}" '"hip_fixture_control":0'
t_assert_contains "${dart_output}" '"accepted":true'
t_assert_contains "${dart_output}" 'Expected exactly one real 17-byte sanitizer teardown report'
t_case 'wrong module identity is refused after a relative load and changed working directory'
t_capture_command dart_output dart_status bash "${ROOT}/linux/scripts/probe-rust-child-under-dart.sh" "${work}/wrong module" --module-owner-negative-control
printf '%s\n' "${dart_output}"
t_assert_eq 1 "${dart_status}"
t_assert_contains "${dart_output}" '"module_owner_control":22'
t_assert_contains "${dart_output}" '"accepted":false'
t_summary
