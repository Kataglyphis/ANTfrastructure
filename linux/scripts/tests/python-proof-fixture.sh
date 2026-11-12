# shellcheck shell=bash
# Share module/test transport while retaining independent production oracles in each fixture.
# shellcheck source=./test-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-harness.sh" || return $?

t_python_fixture_suite() {
  local _tpf_module="$1" _tpf_fixture="$2" _tpf_output='' _tpf_status=125 _tpf_count_status=0 _tpf_summary_status=0
  T_PYTHON_FIXTURE="${_tpf_fixture}" t_capture_command _tpf_output _tpf_status t_gate_probe "${_tpf_module}" <<'PY'
import os
import pathlib
import runpy
import sys

fixture = pathlib.Path(os.environ['T_PYTHON_FIXTURE'])
sys.path.insert(0, str(fixture.resolve().parent))
runpy.run_path(str(fixture), init_globals={'g': globals()['g']}, run_name='__main__')
PY
  printf '%s\n' "${_tpf_output}"
  grep -E -q '^Ran [1-9][0-9]* tests? in ' <<<"${_tpf_output}" || _tpf_count_status=$?
  grep -F -x -q OK <<<"${_tpf_output}" || _tpf_summary_status=$?
  t_assert_eq 0 "${_tpf_status}" 'the Python fixture must return raw success'
  t_assert_eq 0 "${_tpf_count_status}" 'the Python fixture must execute tests'
  t_assert_eq 0 "${_tpf_summary_status}" 'the Python fixture must report a passing summary'
  if [ "${_tpf_status}" -ne 0 ] || [ "${_tpf_count_status}" -ne 0 ] || [ "${_tpf_summary_status}" -ne 0 ]; then return 1; fi
  return 0
}
