#!/usr/bin/env bash
# run-tests.sh — discover and run every linux/scripts/tests/test-*.sh in its
# own bash process (full isolation: a test cannot leak env/functions into the
# next). Non-zero exit iff any suite fails. Wired into preflight.sh (slug
# script-tests) and `make test-linux-scripts`.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=()
for suite in "${TESTS_DIR}"/test-*.sh; do
  [ -f "${suite}" ] || continue
  [ "$(basename "${suite}")" = "test-harness.sh" ] && continue   # the harness, not a suite
  printf '== %s ==\n' "$(basename "${suite}")"
  if ! bash "${suite}"; then
    FAILED+=("$(basename "${suite}")")
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\n%d suite(s) failed: %s\n' "${#FAILED[@]}" "${FAILED[*]}" >&2
  exit 1
fi
printf '\nAll linux script test suites passed.\n'
