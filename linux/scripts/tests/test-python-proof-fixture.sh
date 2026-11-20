#!/usr/bin/env bash
# Transport controls reject lost statuses and empty suites; they do not prove the loaded gate's own assertions.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
work="$(t_mktemp -d)"
printf 'value = 1\n' > "${work}/module.py"
cat > "${work}/suite.py" <<'PY'
import os, sys, unittest
class Fixture(unittest.TestCase):
    def test_module(self):
        self.assertEqual(g.value, 1)
mode = os.environ.get('FIXTURE_MODE', 'good')
if mode == 'failed':
    g.value = 2
if mode != 'silent':
    unittest.main(argv=[__file__], exit=False, defaultTest='Fixture' if mode != 'empty' else None)
sys.exit(42 if mode == 'status' else 0)
PY
printf 'print("Ran 0 tests in 0.000s\\n\\nOK")\n' > "${work}/empty.py"
for mode in good silent empty status failed; do
  t_case "${mode}: only a nonempty passing suite with raw zero may pass"
  suite="${work}/suite.py"
  [ "${mode}" != empty ] || suite="${work}/empty.py"
  expected=1
  [ "${mode}" != good ] || expected=0
  t_assert_rc "${expected}" env FIXTURE_MODE="${mode}" bash -c 'source "$1"; t_python_fixture_suite "$2" "$3"; t_summary' \
    _ "${TESTS_DIR}/python-proof-fixture.sh" "${work}/module.py" "${suite}"
done
for mode in status empty failed; do
  t_case "${mode}: the function returns failure before the final summary"
  suite="${work}/suite.py"
  [ "${mode}" != empty ] || suite="${work}/empty.py"
  report='' raw=0
  t_capture_command report raw env FIXTURE_MODE="${mode}" bash -c '
  source "$1"
  t_python_fixture_suite "$2" "$3"
  printf "function-result=%s\n" "$?"
  t_summary
' _ "${TESTS_DIR}/python-proof-fixture.sh" "${work}/module.py" "${suite}"
  t_assert_eq 1 "${raw}"
  t_assert_contains "${report}" 'function-result=1'
done
for state in absent empty existing; do
  for mode in good status; do
    t_case "${state}/${mode}: temporary fixture transport restores its caller environment"
    expected=0
    [ "${mode}" != status ] || expected=1
    t_assert_rc "${expected}" bash -c '
    source "$1"
    case "$4" in absent) unset T_PYTHON_FIXTURE ;; empty) export T_PYTHON_FIXTURE="" ;; existing) export T_PYTHON_FIXTURE=preserved ;; esac
    FIXTURE_MODE="$5" t_python_fixture_suite "$2" "$3"
    case "$4" in absent) [[ ! -v T_PYTHON_FIXTURE ]] ;; empty) [[ -v T_PYTHON_FIXTURE && -z "$T_PYTHON_FIXTURE" ]] ;; existing) [[ "$T_PYTHON_FIXTURE" == preserved ]] ;; esac
    [[ "$?" == 0 ]] || exit 92
    t_summary
  ' _ "${TESTS_DIR}/python-proof-fixture.sh" "${work}/module.py" "${work}/suite.py" "${state}" "${mode}"
  done
done
t_summary
