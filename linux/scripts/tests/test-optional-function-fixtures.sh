#!/usr/bin/env bash
# Live function emission checks ordered optional workers, not source parsing or production module loading.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
fixture_first() { printf 'first:%s\n' "$1"; }
fixture_last() { printf 'last:%s\n' "$1"; return 23; }
t_case 'missing middle and last names are skipped without changing order or status'
status=0
definitions="$(t_emit_optional_functions fixture_first absent_middle fixture_last absent_last)" || status=$?
t_assert_eq 0 "${status}"
t_assert_eq $'fixture_first\nfixture_last' "$(printf '%s\n' "${definitions}" | sed -n 's/^\(fixture_[a-z]*\) () */\1/p')"
t_case 'emitted definitions are usable by a fresh worker with original arguments and status'
status=0
output="$(bash -c "${definitions}"$'\nfixture_first "a b"\nfixture_last "c d"' 2>&1)" || status=$?
t_assert_eq $'first:a b\nlast:c d' "${output}"
t_assert_eq 23 "${status}"
for mode in none missing; do
  t_case "${mode}: an empty selection emits nothing and succeeds"
  status=0
  if [ "${mode}" = none ]; then
    output="$(t_emit_optional_functions)" || status=$?
  else
    output="$(t_emit_optional_functions absent_first absent_last)" || status=$?
  fi
  t_assert_eq 0 "${status}"
  t_assert_eq '' "${output}"
done
t_summary
