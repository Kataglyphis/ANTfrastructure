#!/usr/bin/env bash
# Cross-wheel flags must preserve target headers, host tools and architecture tagging.
set -u
IFS=$'\n\t'
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../03-media/build/litert/litert-wheel.sh"
if [ "$#" -gt 0 ]; then eval "$(t_fn_src "$1" _litert_wheel_cross_args)"; fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/include" "${WORK}/arch-include"
info() { :; }
err() { local IFS=' '; printf '%s\n' "$*" >&2; exit 1; }
cross_target_arch() { printf arm64; }
host_python_major_minor() { printf 3.14; }
append_cmake_cross_args() { local -n _test_cmake_flags_ref="$1"; _test_cmake_flags_ref+=(-DCMAKE_SYSTEM_NAME=Linux); }
append_cmake_cross_archiver_args() { local -n _test_archiver_flags_ref="$1"; _test_archiver_flags_ref+=(-DCMAKE_AR=target-ar); }
resolve_litert_tflite_host_tools_dir() {
  if [ "${MISSING_TOOLS:-0}" = 0 ]; then printf /host-tools; fi
}
litert_cross_wheel_platform_tag() {
  if [ "${MISSING_PLATFORM:-0}" = 0 ]; then printf linux_aarch64; fi
}
cross_target_python_include_dir() { printf '%s/include' "${WORK}"; }
cross_target_python_arch_include_dir() { printf '%s/%s' "${WORK}" "${ARCH_INCLUDE:-arch-include}"; }
python_module_include() { printf '/host-headers/%s' "$2"; }

_cross_flags() {
  local extra_cmake_flags=seed python_major_minor="" tflite_host_tools_dir=""
  local wheel_platform_name="" target_python_include="" target_python_arch_include=""
  local PYTHON="${FIXTURE_PYTHON-/fixture/python}" TF_CXX_FLAGS=-DUSER=1
  _litert_wheel_cross_args
  [[ "${EXTRA_CMAKE_FLAGS}" = "${extra_cmake_flags}" && "${WHEEL_PLATFORM_NAME}" = "${wheel_platform_name}" \
     && "${PYTHON}" = "${FIXTURE_PYTHON-/fixture/python}" && "${TF_CXX_FLAGS}" = -DUSER=1 ]] || return 1
  [ "${tflite_host_tools_dir}" = /host-tools ] || return 1
  if [ -n "${target_python_include}" ]; then
    [ -d "${target_python_include}" ] && [ -d "${target_python_arch_include}" ] || return 1
  fi
  printf 'CMAKE=%s\nPLATFORM=%s\nFLAGS=%s\nPYTHON=%s\n' \
    "${EXTRA_CMAKE_FLAGS}" "${WHEEL_PLATFORM_NAME}" "${BUILD_FLAGS}" "${python_major_minor}"
}

_invoke_cross() { ( _cross_flags ); }

t_case "complete cross-wheel arguments retain their exact order and values"
out="$(_cross_flags)"
expected="CMAKE=seed -DCMAKE_SYSTEM_NAME=Linux"$'\n'"-DCMAKE_AR=target-ar -DTFLITE_HOST_TOOLS_DIR=/host-tools -DPYTHON_INCLUDE_DIR=${WORK}/include -DPYTHON_INCLUDE_PATH=${WORK}/include
PLATFORM=linux_aarch64
FLAGS=-idirafter /usr/include -DUSER=1 -I${WORK}/include -I${WORK}/arch-include -I/host-headers/pybind11 -I/host-headers/numpy
PYTHON=3.14"
t_assert_eq "${expected}" "${out}"

t_case "an incomplete target header pair emits neither target include flag"
out="$(ARCH_INCLUDE=missing _cross_flags)"
t_assert_eq 0 "$(printf '%s' "${out}" | grep -c -- '-DPYTHON_INCLUDE')"
t_assert_eq 0 "$(printf '%s' "${out}" | grep -c -- "-I${WORK}")"
t_assert_contains "${out}" '-I/host-headers/pybind11 -I/host-headers/numpy'

t_case "an absent build interpreter emits no host package include flags"
out="$(FIXTURE_PYTHON='' _cross_flags)"
t_assert_eq 0 "$(printf '%s' "${out}" | grep -c -- '-I/host-headers')"

t_case "missing host tools and an unknown wheel platform both fail before packaging"
t_assert_eq 1 "$(MISSING_TOOLS=1 t_rc _invoke_cross)"
t_assert_contains "$(MISSING_TOOLS=1 t_out _invoke_cross)" 'Could not resolve TFLite host tools directory'
t_assert_eq 1 "$(MISSING_PLATFORM=1 t_rc _invoke_cross)"
t_assert_contains "$(MISSING_PLATFORM=1 t_out _invoke_cross)" 'Could not resolve wheel platform tag'

t_summary
