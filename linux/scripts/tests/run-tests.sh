#!/usr/bin/env bash
# run-tests.sh — every test-*.sh in its own bash process, so no suite leaks env or functions into the next.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=()
SUITES=0
TOTAL_ASSERTS=0
for suite in "${TESTS_DIR}"/test-*.sh; do
  [ -f "${suite}" ] || continue
  [ "$(basename "${suite}")" = "test-harness.sh" ] && continue   # the harness, not a suite
  printf '== %s ==\n' "$(basename "${suite}")"
  SUITES=$((SUITES + 1))
  # Captured to sum the harness's "N assertion(s) passed" lines, then streamed.
  _out="$(bash "${suite}" 2>&1)"; _rc=$?
  printf '%s\n' "${_out}"
  if [ "${_rc}" -ne 0 ]; then
    FAILED+=("$(basename "${suite}")")
  else
    _n="$(printf '%s\n' "${_out}" | sed -n 's/^  \([0-9][0-9]*\) assertion(s) passed$/\1/p' | tail -1)"
    TOTAL_ASSERTS=$((TOTAL_ASSERTS + ${_n:-0}))
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\n%d suite(s) failed: %s\n' "${#FAILED[@]}" "${FAILED[*]}" >&2
  exit 1
fi
# The aggregate makes a coverage collapse visible ("24 suites, 3 assertions" reads as the alarm it is).
printf '\nAll linux script test suites passed (%d suites, %d assertions).\n' "${SUITES}" "${TOTAL_ASSERTS}"
