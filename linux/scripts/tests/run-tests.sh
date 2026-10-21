#!/usr/bin/env bash
# run-tests.sh — every test-*.sh in its own bash process, so no suite leaks env or functions into the next.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/lib-ordered-jobs.sh
source "${TESTS_DIR}/../lib-ordered-jobs.sh"

FAILED=()
SKIPPED=()
SUITES=0
TOTAL_ASSERTS=0
# Only a Git Bash host may skip (t_skip_unless, exit 77); on Linux, where CI runs, every suite must run.
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) SKIP_OK=1 ;; *) SKIP_OK=0 ;; esac
# Windows' python writes its code page, not UTF-8, into a pipe; the suites compare UTF-8 text.
[ "${SKIP_OK}" -eq 0 ] || export PYTHONUTF8="${PYTHONUTF8:-1}"
# RUN_TESTS_JOBS: suites at once, default one per CPU; 1 runs them in turn.
JOBS="$(oj_count RUN_TESTS_JOBS)" || exit 2

SUITE_NAMES=()
for suite in "${TESTS_DIR}"/test-*.sh; do
  [ -f "${suite}" ] || continue
  [ "$(basename "${suite}")" = "test-harness.sh" ] && continue   # the harness, not a suite
  SUITE_NAMES+=("$(basename "${suite}")")
  oj_add bash "${suite}"
done

# <i> <rc> <log>: one suite's block and verdict; ordered-jobs calls it in name order.
_report() {
  local name="${SUITE_NAMES[$1]}" _out _n
  _out="$(cat "$3")"
  printf '== %s ==\n' "${name}"
  SUITES=$((SUITES + 1))
  printf '%s\n' "${_out}"
  if [ "$2" -eq 77 ] && [ "${SKIP_OK}" -eq 1 ]; then
    SKIPPED+=("${name}")
  elif [ "$2" -ne 0 ]; then
    FAILED+=("${name}")
  else
    # Summed from the harness's "N assertion(s) passed" lines.
    _n="$(printf '%s\n' "${_out}" | sed -n 's/^  \([0-9][0-9]*\) assertion(s) passed$/\1/p' | tail -1)"
    TOTAL_ASSERTS=$((TOTAL_ASSERTS + ${_n:-0}))
  fi
}
oj_run "${JOBS}" _report

# Listed before the verdict, so a red run still says how much it never ran.
for suite in "${SKIPPED[@]}"; do
  printf '\nskipped on this host: %s (its SKIP line above names what the host lacks)' "${suite}"
done
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\n%d suite(s) failed: %s\n' "${#FAILED[@]}" "${FAILED[*]}" >&2
  exit 1
fi
# The aggregate makes a coverage collapse visible ("24 suites, 3 assertions" reads as the alarm it is).
printf '\nAll linux script test suites passed (%d suites, %d assertions).\n' "$((SUITES - ${#SKIPPED[@]}))" "${TOTAL_ASSERTS}"
