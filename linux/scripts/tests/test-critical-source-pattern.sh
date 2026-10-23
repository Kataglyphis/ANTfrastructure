#!/usr/bin/env bash
# Local source fixtures cover grep verdicts and failure aggregation, not compiled artifacts or runtime behavior.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../06-packaging/smoke-common.sh"
eval "$(t_fn_src "${TESTS_DIR}/../verify-critical-fixes.sh" _critical_source_pattern)"
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

t_case "the accumulated verdict reaches a failing final summary"
t_assert_rc 1 bash -c 'source "$1"; FAILURES=3; smoke_summary' _ "${TESTS_DIR}/../06-packaging/smoke-common.sh"
t_summary
