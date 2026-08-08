#!/usr/bin/env bash
# run-tests.sh — discover and run every linux/scripts/tests/test-*.sh in its
# own bash process (full isolation: a test cannot leak env/functions into the
# next). Non-zero exit iff any suite fails. Wired into preflight.sh (slug
# script-tests) and `make test-linux-scripts`.
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
  # Capture output to aggregate the per-suite assertion count (the harness
  # prints "N assertion(s) passed"); still stream it for the reader.
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
# The aggregate makes a silent coverage collapse visible in every log line
# ("24 suites, 3 assertions" reads as the alarm it is).
printf '\nAll linux script test suites passed (%d suites, %d assertions).\n' "${SUITES}" "${TOTAL_ASSERTS}"
