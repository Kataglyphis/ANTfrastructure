#!/usr/bin/env bash
# media_jobs, both definitions of it. The name has TWO owners on purpose -- one
# assumes media_common_init pre-loaded parallelism.sh, the other sources it on
# demand -- so what has to hold is that they take the SAME argument and mean the
# same thing by it. The android gstreamer lane's 1500 MB was a fourth copy of the
# block until the cap became a parameter.
# docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/.."

_common_src="$(t_fn_src "${SCRIPTS}/03-media/core/common.sh" media_jobs)" || exit 1
_preamble_src="$(t_fn_src "${SCRIPTS}/03-media/android-build-preamble.sh" media_jobs)" || exit 1

# _jobs <definition source> <helper stub> [cap] -- runs one media_jobs in its own
# shell. The helper stub decides which branch is reachable: a compute_jobs_with_mem_cap
# that records its cap, or nothing at all for the nproc fallback.
_jobs() {
  bash -c '
    nproc() { printf "NPROC\n"; }
    '"$2"'
    '"$1"'
    media_jobs '"${3:-}"'' 2>&1
}
_CAP_STUB='compute_jobs_with_mem_cap() { printf "CAP %s\n" "$2"; }'
_run_common()      { _jobs "${_common_src}"   "${_CAP_STUB}" "${1:-}"; }
_run_common_bare() { _jobs "${_common_src}"   ""             "${1:-}"; }
# The on-demand copy reads /opt/scripts/core/parallelism.sh -- an absolute
# container path no host fixture can stand in for -- so its cap branch is asserted
# on the SOURCE and its fallback is driven for real.
_run_preamble()    { _jobs "${_preamble_src}" ""             "${1:-}"; }

t_case "the default cap is 2000 MB in BOTH definitions"
t_assert_eq "CAP 2000" "$(_run_common)"
t_assert_contains "${_preamble_src}" 'compute_jobs_with_mem_cap "" "${1:-2000}"' \
  "two owners that disagree about the default are two different functions wearing one name"

t_case "an explicit cap reaches compute_jobs_with_mem_cap unchanged"
t_assert_eq "CAP 1500" "$(_run_common 1500)" "1500 is the android gstreamer lane's own budget"
t_assert_eq "CAP 4096" "$(_run_common 4096)"

t_case "the on-demand copy falls back to nproc when the container path is absent"
t_assert_eq "NPROC" "$(_run_preamble)"
t_assert_eq "NPROC" "$(_run_preamble 1500)" "a cap must not change what happens without the helper"

t_case "without the helper it falls back to nproc, cap or no cap"
t_assert_eq "NPROC" "$(_run_common_bare)"
t_assert_eq "NPROC" "$(_run_common_bare 1500)" \
  "a cap must not turn an absent helper into an error"

t_case "the android gstreamer lane calls it instead of re-implementing it"
_lane="${SCRIPTS}/03-media/build/gstreamer/android/build-android-from-source.sh"
t_assert_contains "$(grep -e 'JOBS=' "${_lane}")" 'media_jobs "${PER_JOB_MB}"' \
  "the configurable cap is the whole reason media_jobs takes an argument"
t_assert_eq "0" "$(grep -c -e 'compute_jobs_with_mem_cap' "${_lane}" || true)" \
  "a fourth copy of the on-demand load is what this closed"

t_summary
