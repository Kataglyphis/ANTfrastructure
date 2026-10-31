#!/usr/bin/env bash
# lib/code-quality.sh's compile-database pair is consumer API with no caller here; these cases pin its paths, status and output.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/lib-contract-fixture.sh
source "${TESTS_DIR}/lib-contract-fixture.sh"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare _work
t_fixture_workspace_init _work || exit 1
lc_init "${_work}" || exit 1
LIB="${TESTS_DIR}/../lib/code-quality.sh"
declare out rc
# Prints the two globals the pair hands its caller, then the database the caller would read.
SHOW='printf "dir=%s tmp=%s\n" "${CODE_QUALITY_COMPILE_DB_DIR}" "${CODE_QUALITY_COMPILE_DB_TEMP_DIR}"; cat "${CODE_QUALITY_COMPILE_DB_DIR}/compile_commands.json"'
GCC='/opt/gcc-16.2.0'

_db() {
  mkdir -p "${_work}/build"
  printf '%s\n' "$@" > "${_work}/build/compile_commands.json"
}

t_case "a missing database fails, naming the path and the caller's hint"
lc_expect 1 "Missing absent/compile_commands.json. Run CMake configure first. Run ci-configure.sh." \
  "${LIB}" 'CODE_QUALITY_COMPILE_DB_HINT="Run ci-configure.sh." code_quality_prepare_compile_db absent'

t_case "a host database is used where it lies"
_db '[{"file": "/proj/src/a.cpp", "command": "c++ -c a.cpp"}]'
lc_call out rc "${LIB}" "code_quality_prepare_compile_db build && ${SHOW}"
t_assert_eq "0" "${rc}"
t_assert_eq 'dir=build tmp=
[{"file": "/proj/src/a.cpp", "command": "c++ -c a.cpp"}]' "${out}"

t_case "container paths are remapped onto the project root in a temporary copy"
_db '[{"directory": "/workspace/build", "file": "/workspace/src/a.cpp"}]'
lc_call out rc "${LIB}" "CODE_QUALITY_PROJECT_ROOT=/proj code_quality_prepare_compile_db build && ${SHOW}"
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" "Remapping container paths in compile_commands.json..."
t_assert_contains "${out}" '[{"directory": "/proj/build", "file": "/proj/src/a.cpp"}]'
_dirs="$(printf '%s\n' "${out}" | sed -n 's/^dir=\(.*\) tmp=\(.*\)$/\1 \2/p')"
t_assert_eq "${_dirs#* }" "${_dirs% *}" "the caller reads the copy"
t_assert_contains "${_dirs#* }" "${_work}/tmp/" "the copy is a mktemp directory"
t_assert_contains "$(cat "${_work}/build/compile_commands.json")" '/workspace/src/a.cpp' "the original is untouched"

t_case "an empty CODE_QUALITY_CONTAINER_WORKSPACE turns the remap off"
lc_call out rc "${LIB}" "CODE_QUALITY_CONTAINER_WORKSPACE= code_quality_prepare_compile_db build && ${SHOW}"
t_assert_eq "0" "${rc}"
t_assert_contains "${out}" 'dir=build tmp='

t_case "container-only GCC toolchain flags go when the probed toolchain is absent here"
_flags="--gcc-toolchain=${GCC} -Wl,-rpath,${GCC}/lib64 -L${GCC}/lib64"
_db "[{\"command\": \"clang++ ${_flags} -c /workspace/a.cpp\"}]"
lc_call out rc "${LIB}" "CODE_QUALITY_PROJECT_ROOT=/proj CODE_QUALITY_GCC_TOOLCHAIN_PROBE_DIR=/nonexistent/gcc code_quality_prepare_compile_db build && ${SHOW}"
t_assert_contains "${out}" '[{"command": "clang++  -c /workspace/a.cpp"}]' "the flags go; a path inside a command string is not remapped (BACKLOG CON209)"
lc_call out rc "${LIB}" "CODE_QUALITY_PROJECT_ROOT=/proj CODE_QUALITY_GCC_TOOLCHAIN_PROBE_DIR=$(printf '%q' "${_work}") code_quality_prepare_compile_db build && ${SHOW}"
t_assert_contains "${out}" "${_flags}" "a toolchain present here keeps its flags"

t_case "cleanup removes the temporary copy and forgets it, and is a no-op without one"
lc_call out rc "${LIB}" 'code_quality_prepare_compile_db build; t="${CODE_QUALITY_COMPILE_DB_TEMP_DIR}"; code_quality_cleanup_compile_db; printf "[%s] " "${CODE_QUALITY_COMPILE_DB_TEMP_DIR}"; if [ -e "$t" ]; then echo kept; else echo gone; fi'
t_assert_eq "[] gone" "$(printf '%s\n' "${out}" | tail -1)" "the copy is gone and the variable cleared"
lc_call out rc "${LIB}" 'CODE_QUALITY_COMPILE_DB_TEMP_DIR=; code_quality_cleanup_compile_db; echo rc=$?'
t_assert_eq "rc=0" "${out}"

t_summary
