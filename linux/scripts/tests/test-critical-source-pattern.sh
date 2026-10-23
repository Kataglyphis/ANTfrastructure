#!/usr/bin/env bash
# Local source fixtures cover grep verdicts and failure aggregation, not compiled artifacts or runtime behavior.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../06-packaging/smoke-common.sh"
GATE="${1:-${TESTS_DIR}/../verify-critical-fixes.sh}"
t_source_functions "${GATE}" _critical_source_verdict _critical_source_pattern _critical_source_all_grep _critical_source_no_match _critical_source_patterns || exit 1
w="$(mktemp -d)"
trap 'rm -rf "${w}"' EXIT
printf 'literal [value]\nsecond row\n' > "${w}/source with spaces"
FAILURES=0

for probe in literal-match missing-pattern missing-file invalid-expression later-match; do
  t_case "source verdict: ${probe}"
  probe_file="${w}/source with spaces"
  expected_out='' expected_err=''
  case "${probe}" in
    literal-match)
      probe_args=(-qF 'literal [value]'); expected_count=0
      expected_out='  PASS fixture accepted' ;;
    missing-pattern)
      probe_args=(-qF absent); expected_count=1
      expected_err='  FAIL fixture rejected' ;;
    missing-file)
      probe_args=(-qF literal); probe_file="${w}/absent"; expected_count=2
      expected_err='  FAIL fixture rejected' ;;
    invalid-expression)
      probe_args=(-qE '['); expected_count=3
      expected_err='  FAIL fixture rejected' ;;
    later-match)
      probe_args=(-qE '^second row$'); expected_count=3
      expected_out='  PASS fixture accepted' ;;
  esac
  _critical_source_pattern 'fixture accepted' 'fixture rejected' "${probe_args[@]}" "${probe_file}" > "${w}/out" 2> "${w}/err"
  t_assert_eq "${expected_out}" "$(cat "${w}/out")"
  t_assert_eq "${expected_err}" "$(cat "${w}/err")"
  t_assert_eq "${expected_count}" "${FAILURES}"
done

t_case "compound checks require every match and preserve their diagnostic policy"
FAILURES=0
for diagnostics in quiet loud; do
  for probe in all-match first-missing last-missing missing-file invalid-expression; do
    probe_args=(-qF 'literal [value]' "${w}/source with spaces" -qE '^second row$' "${w}/source with spaces")
    case "${probe}" in
      first-missing) probe_args[1]=absent ;;
      last-missing) probe_args[4]=absent ;;
      missing-file) probe_args[5]="${w}/absent" ;;
      invalid-expression) probe_args[4]='[' ;;
    esac
    before="${FAILURES}"
    _critical_source_verdict accepted rejected "${diagnostics}" _critical_source_all_grep "${probe_args[@]}" > "${w}/out" 2> "${w}/err"
    if [ "${probe}" = all-match ]; then
      t_assert_eq "${before}" "${FAILURES}"
      t_assert_eq '  PASS accepted' "$(cat "${w}/out")"
      t_assert_eq '' "$(cat "${w}/err")"
    else
      t_assert_eq "$((before + 1))" "${FAILURES}"
      t_assert_eq '' "$(cat "${w}/out")"
      t_assert_contains "$(cat "${w}/err")" '  FAIL rejected'
      if [ "${diagnostics}" = quiet ]; then
        t_assert_eq '  FAIL rejected' "$(cat "${w}/err")"
      elif [ "${probe}" = missing-file ]; then
        t_assert_contains "$(cat "${w}/err")" "${w}/absent"
      fi
    fi
  done
done

t_case "compound failure short-circuits later probes"
_critical_source_verdict accepted rejected loud _critical_source_all_grep \
  -q absent "${w}/source with spaces" -qE '[' "${w}/source with spaces" > "${w}/out" 2> "${w}/err"
t_assert_eq '  FAIL rejected' "$(cat "${w}/err")"

t_case "negative probes keep absent matches successful and present matches failing"
FAILURES=0
_critical_source_verdict absent present quiet _critical_source_no_match -qF absent "${w}/source with spaces" > "${w}/out" 2> "${w}/err"
t_assert_eq 0 "${FAILURES}"
t_assert_eq '  PASS absent' "$(cat "${w}/out")"
_critical_source_verdict absent present quiet _critical_source_no_match -qF literal "${w}/source with spaces" > "${w}/out" 2> "${w}/err"
t_assert_eq 1 "${FAILURES}"
t_assert_eq '  FAIL present' "$(cat "${w}/err")"

t_case "batched positive checks retain independent verdicts after an earlier failure"
FAILURES=0
_critical_source_patterns first-ok first-bad -qF absent "${w}/source with spaces" \
  second-ok second-bad -qF literal "${w}/source with spaces" > "${w}/out" 2> "${w}/err"
t_assert_eq 1 "${FAILURES}"
t_assert_eq '  FAIL first-bad' "$(cat "${w}/err")"
t_assert_eq '  PASS second-ok' "$(cat "${w}/out")"

t_case "the accumulated verdict reaches a failing final summary"
t_assert_rc 1 bash -c 'source "$1"; FAILURES=3; smoke_summary' _ "${TESTS_DIR}/../06-packaging/smoke-common.sh"
t_summary
