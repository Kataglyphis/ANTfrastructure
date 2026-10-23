#!/usr/bin/env bash
# run-tests.sh runs suites side by side but reports them as a serial run would: in name order, with the same totals.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT
mkdir -p "${_WORK}/tests"
cp "${TESTS_DIR}/test-harness.sh" "${TESTS_DIR}/run-tests.sh" "${TESTS_DIR}/meet.sh" "${_WORK}/tests/"
cp "${TESTS_DIR}/../lib-ordered-jobs.sh" "${_WORK}/"

# _suite <name> <peers> <assertion>: a fixture suite that, given peers, waits for them under ${MEET} (MEET_SECS) and says met or alone.
_suite() {
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/test-harness.sh"\nsource "$(dirname "$0")/meet.sh"\n[ %s = 0 ] || meet_peers "${MEET}" %s %s "${MEET_SECS}" >> "${MEET}/said"\nt_case one\n%s\nt_assert_ok true\nt_summary\n' \
    "$2" "$1" "$2" "$3" > "${_WORK}/tests/$1"
}
# _runner [VAR=VAL...]: rc and what the peers said, one per line, then the output of the copied runner.
_runner() {
  local out rc bound=120
  if [ "${1:-}" = --timeout ]; then bound="$2"; shift 2; fi
  rm -rf "${_WORK}/meet"; mkdir -p "${_WORK}/meet"; : > "${_WORK}/meet/said"
  # A runner that never ends is a verdict too: rc 124.
  out="$(env MEET="${_WORK}/meet" MEET_SECS=20 "$@" timeout "$bound" bash "${_WORK}/tests/run-tests.sh" 2>&1)"; rc=$?
  printf 'RC=%s\nSAID=%s\n%s\n' "${rc}" "$(sort "${_WORK}/meet/said" | tr '\n' ' ' | sed 's/ $//')" "${out}"
}
_blocks() { printf '%s\n' "$1" | sed -n 's/^== \(.*\) ==$/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
_said() { printf '%s\n' "$1" | sed -n 's/^SAID=//p'; }

# a and c wait for each other, so b ends first: completion order differs from name order (a, b, c).
_suite test-a.sh 2 't_assert_ok true'
_suite test-b.sh 0 't_assert_ok false'
_suite test-c.sh 2 't_assert_ok true'

# A rendezvous, never a wall-clock comparison: a loaded host slows both runs unevenly.
t_case "RUN_TESTS_JOBS=1 runs them in turn"
# a waits 5 s: long enough that a c started beside it would be met, so an uncapped runner says met met.
ser="$(_runner RUN_TESTS_JOBS=1 MEET_SECS=5)"
t_assert_eq "alone met" "$(_said "${ser}")" "in turn, a ends before c starts"

t_case "side by side, the blocks still print in name order and a red suite fails the run"
par="$(_runner RUN_TESTS_JOBS=3)"
t_assert_contains "${par}" "RC=1"
t_assert_eq "test-a.sh test-b.sh test-c.sh" "$(_blocks "${par}")"
t_assert_contains "${par}" "1 suite(s) failed: test-b.sh"
t_assert_eq "met met" "$(_said "${par}")"
t_assert_eq "$(printf '%s\n' "${ser}" | sed 1,2d)" "$(printf '%s\n' "${par}" | sed 1,2d)" "the report must not depend on the job count"

t_case "the default runs one suite per CPU, not one at a time"
t_needs "a second CPU" test "$(nproc 2>/dev/null || echo 1)" -ge 2
t_assert_eq "met met" "$(_said "$(_runner)")"

t_case "the totals add up across suites that finished out of order"
_suite test-b.sh 0 't_assert_ok true'
out="$(_runner RUN_TESTS_JOBS=2)"
t_assert_contains "${out}" "RC=0"
t_assert_contains "${out}" "All linux script test suites passed (3 suites, 6 assertions)."

t_case "a suite still receives SIGINT, which a background job would ignore"
mv "${_WORK}/tests/test-a.sh" "${_WORK}/tests/test-a.off"
mv "${_WORK}/tests/test-c.sh" "${_WORK}/tests/test-c.off"
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/test-harness.sh"\nt_case int\ntrap "t_assert_ok true; t_summary" INT\nkill -INT $$\nsleep 3\nt_assert_ok false\nt_summary\n' \
  > "${_WORK}/tests/test-b.sh"
t_assert_contains "$(_runner RUN_TESTS_JOBS=2)" "RC=0"

t_case "a jobs value that is not a positive integer is a usage error"
for _bad in 0 x -1; do
  t_assert_contains "$(_runner --timeout 10 RUN_TESTS_JOBS="${_bad}")" "RC=2"
done

t_summary
