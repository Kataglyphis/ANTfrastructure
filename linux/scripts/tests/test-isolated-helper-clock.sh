#!/usr/bin/env bash
# Injected clocks and real children prove clock failure/reaping and optimized compilation, not HIP or package delivery.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare ROOT work clock_output clock_status
t_fixture_workspace_init work ROOT || exit 1
source "${ROOT}/linux/scripts/lib/isolated-helper-compile.sh" || exit
t_case 'optimized helper and clock fixtures compile with fatal warnings'
compile_isolated_helper_object "${ROOT}" "${work}" || exit
compile_isolated_clock_fixture "${ROOT}" "${work}" || exit
t_case 'initial and elapsed clock failures preserve errors and reap actual children'
t_capture_command clock_output clock_status timeout --kill-after=5s 20s "${work}/clock-fixture"
printf '%s\n' "${clock_output}" > "${work}/clock.log"
cat "${work}/clock.log"
t_assert_eq 0 "${clock_status}"
for call in 1 2; do
  t_assert_grep "${work}/clock.log" "^clock error call=${call} errno=0 preserved=5 cleanup=passed$"
done
t_assert_grep "${work}/clock.log" '^clock error call=1 errno=13 preserved=13 cleanup=passed$'
t_assert_grep "${work}/clock.log" '^clock error call=2 errno=34 preserved=34 cleanup=passed$'
t_assert_grep "${work}/clock.log" '^clock timeout killed-and-reaped=passed$'
t_case 'failed fixture compilation cannot link a stale object or hide its raw status'
t_capture_command clock_output clock_status bash -c '
  source "$1"
  _ih_c_object() { return 43; }
  cc() { printf "unexpected clock link\n"; }
  compile_isolated_clock_fixture "$2" "$3"
' _ "${ROOT}/linux/scripts/lib/isolated-helper-compile.sh" "${ROOT}" "${work}"
t_assert_eq 43 "${clock_status}"
t_assert_eq '' "${clock_output}"
t_summary
