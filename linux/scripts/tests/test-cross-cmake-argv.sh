#!/usr/bin/env bash
# A stub isolates the argv regression from unavailable cross compilers and libraries.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK}"' EXIT
eval "$(t_fn_src "${TESTS_DIR}/../01-core/cross-env.sh" cross_compile_cmake_lib_from_source)"

cross_target_triplet() { printf aarch64-linux-gnu; }
cross_target_arch() { printf arm64; }
_cross_fetch_cmake_source() { printf 'project(fixture)\n' > "$3/CMakeLists.txt"; }
cmake() {
  if [ "$1" = -S ]; then printf '%s\n' "$@" > "${WORK}/cmake-argv"; fi
  return 0
}

t_case "policy value and caller options remain single CMake arguments"
export CMAKE_POLICY_VERSION_MINIMUM='3.5 SPECIAL'
TMPDIR="${WORK}" cross_compile_cmake_lib_from_source fixture fixture-url "${WORK}/install tree" \
  "${WORK}/missing-sentinel" '-DOTHER=value with spaces' >/dev/null
t_assert_ok grep -Fx -- '-DCMAKE_POLICY_VERSION_MINIMUM=3.5 SPECIAL' "${WORK}/cmake-argv"
t_assert_ok grep -Fx -- '-DOTHER=value with spaces' "${WORK}/cmake-argv"
t_assert_eq 1 "$(t_rc grep -Fx -- SPECIAL "${WORK}/cmake-argv")"

t_summary
