#!/usr/bin/env bash
# test-lib-smoke.sh — cheap smoke tests for every consumer-facing module in
# linux/scripts/lib/ (refactoring backlog item A2, docs/refactoring-backlog.md).
#
# These libraries are sourced STANDALONE by external repos, which is exactly
# how they rot: app-runner.sh's bootstrap comment (lib/app-runner.sh:33-40)
# records that it was "the drifted copy" — no re-source guard, never loading
# the real 01-core/logging.sh — and nothing noticed for a long time. This
# suite guards the whole class:
#   (1) every module parses (bash -n),
#   (2) every module sources cleanly under `set -euo pipefail` (a strict-mode
#       consumer must not be killed by an unbound var / failing top-level cmd),
#   (3) sourcing actually DEFINES functions (a gutted or early-returning module
#       that exports nothing is a drifted copy, not a library),
#   (4) cmake-build.sh's cmake_build_parse_args works in isolation.
# No network, no cmake execution — pure parse/source checks.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB_DIR="${TESTS_DIR}/../lib"

for mod in "${LIB_DIR}"/*.sh; do
  name="$(basename "${mod}")"

  t_case "${name}: parses (bash -n)"
  t_assert_ok bash -n "${mod}"

  t_case "${name}: sources cleanly under set -euo pipefail"
  t_assert_ok bash -c "set -euo pipefail; source '${mod}'"

  t_case "${name}: sourcing defines at least one function"
  # Count the function delta inside ONE shell so exported functions inherited
  # from the test environment cannot fake a nonzero count.
  fn_delta="$(bash -c "set -euo pipefail
    pre=\$(declare -F | wc -l)
    source '${mod}'
    post=\$(declare -F | wc -l)
    echo \$((post - pre))" 2>/dev/null || echo -1)"
  t_assert_ok test "${fn_delta}" -gt 0
done

# ── cmake-build.sh: drive the argument parser in isolation ────────────────────
# cmake_build_parse_args needs no heavy env (only variables with defaults), so
# exercise the documented precedence: CLI flags win, positional falls through
# to CMAKE_BUILD_POSITIONAL (and becomes the preset only when --preset absent).

t_case "cmake_build_parse_args: explicit flags are parsed into their variables"
_out="$(bash -c "set -euo pipefail
  source '${LIB_DIR}/cmake-build.sh'
  cmake_build_parse_args --preset linux-release --build-dir bld \
    --parallel 7 --mb-per-job 1234 --skip-configure --allow-prebuild-failure \
    extra-positional
  printf '%s|%s|%s|%s|%s|%s|%s' \
    \"\${PRESET}\" \"\${BUILD_DIR}\" \"\${PARALLEL_JOBS}\" \"\${MB_PER_JOB}\" \
    \"\${SKIP_CONFIGURE}\" \"\${ALLOW_PREBUILD_FAILURE}\" \
    \"\${CMAKE_BUILD_POSITIONAL[0]}\"")"
t_assert_eq "linux-release|bld|7|1234|true|true|extra-positional" "${_out}"

t_case "cmake_build_parse_args: no args yields the documented defaults"
_out="$(bash -c "set -euo pipefail
  source '${LIB_DIR}/cmake-build.sh'
  cmake_build_parse_args
  printf '%s|%s|%s|%s|%s' \
    \"\${BUILD_DIR}\" \"\${MB_PER_JOB}\" \"\${CLEAN_BUILD_DIR}\" \
    \"\${SKIP_CONFIGURE}\" \"\${ALLOW_PREBUILD_FAILURE}\"")"
t_assert_eq "build|4000|false|false|false" "${_out}"

t_case "cmake_build_parse_args: a bare positional is accepted as the preset"
_out="$(bash -c "set -euo pipefail
  source '${LIB_DIR}/cmake-build.sh'
  cmake_build_parse_args my-preset
  printf '%s' \"\${PRESET}\"")"
t_assert_eq "my-preset" "${_out}"

t_summary
