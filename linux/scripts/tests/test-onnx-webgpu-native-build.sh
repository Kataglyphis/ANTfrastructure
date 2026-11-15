#!/usr/bin/env bash
# Stub tools test producer dispatch, cache pins and raw failures; no real target compiler or ORT build runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
common="${1:-${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh}"
t_source_functions "${common}" build_onnx_webgpu_factory_probe || exit 1
t_private_tmpdir
work="$(t_mktemp -d)"
_ONNX_LIB_DIR="${common%/*}"
cache_pin_before="${CMAKE_COMPILER_CACHE_PIN+x}:${CMAKE_COMPILER_CACHE_PIN-}"
_record() { printf '%s\n' "$1" >> "${work}/steps"; if [ "${failure}" = "$1" ]; then return "$2"; fi; return 0; }
append_cmake_cache_linker_args() {
  local -n arguments="$1"
  CMAKE_COMPILER_CACHE_PIN='fixture launcher'
  arguments+=('-DCMAKE_C_COMPILER_LAUNCHER=fixture launcher')
  _record cache 17
}
cmake() {
  printf '<%s>' "$@" >> "${work}/arguments"
  printf '\n' >> "${work}/arguments"
  if [ "$1" = --install ]; then _record install 31; else _record configure 19; fi
}
cmake_assert_compiler_cache_pin() {
  t_assert_eq 'configured parent/webgpu-factory-probe' "$1"
  t_assert_eq 'fixture launcher' "$2"
  _record gate 23
}
run_cmake_build_with_fallback() {
  t_assert_eq 'configured parent/webgpu-factory-probe' "$1"
  t_assert_eq 1 "$2"
  _record build 29
}
for case in success:0 cache:17 configure:19 gate:23 build:29 install:31; do
  failure="${case%:*}"
  : > "${work}/steps"; : > "${work}/arguments"
  status=0
  if build_onnx_webgpu_factory_probe 'configured parent' 'installed prefix'; then status=0; else status=$?; fi
  t_assert_eq "${case#*:}" "${status}" 'conditional callers retain raw phase failures'
  steps="$(cat "${work}/steps")"
  if [ "${failure}" = success ]; then
    t_assert_eq $'cache\nconfigure\ngate\nbuild\ninstall' "${steps}"
    t_assert_contains "$(cat "${work}/arguments")" '<-DORT_CONFIG_DIR=configured parent><-DORT_INCLUDE_DIR=installed prefix/include><-DCMAKE_C_COMPILER_LAUNCHER=fixture launcher>'
    t_assert_contains "$(cat "${work}/arguments")" '<--install><configured parent/webgpu-factory-probe><--prefix><installed prefix>'
  else
    t_assert_eq "${failure}" "$(tail -n 1 "${work}/steps")" 'no phase runs after failure'
  fi
done
t_assert_eq "${cache_pin_before}" "${CMAKE_COMPILER_CACHE_PIN+x}:${CMAKE_COMPILER_CACHE_PIN-}" 'cache callback writes the helper-local output slot without leaking caller state'
for helper in append_cmake_cache_linker_args cmake_assert_compiler_cache_pin run_cmake_build_with_fallback; do
  saved="$(declare -f "${helper}")"
  unset -f "${helper}"
  : > "${work}/steps"
  status=0
  build_onnx_webgpu_factory_probe 'configured parent' 'installed prefix' > "${work}/missing" 2>&1 || status=$?
  t_assert_eq 1 "${status}"
  t_assert_contains "$(cat "${work}/missing")" "requires ${helper}"
  t_assert_eq '' "$(cat "${work}/steps")" 'missing API fails before selected tools'
  eval "${saved}"
done
failure=success
_cache_slot_case() (
  case "$1" in
    absent) unset CMAKE_COMPILER_CACHE_PIN ;;
    empty) CMAKE_COMPILER_CACHE_PIN='' ;;
    existing) CMAKE_COMPILER_CACHE_PIN='outer pin with spaces' ;;
  esac
  before="${CMAKE_COMPILER_CACHE_PIN+x}:${CMAKE_COMPILER_CACHE_PIN-}"
  build_onnx_webgpu_factory_probe 'configured parent' 'installed prefix' || exit $?
  test "${before}" = "${CMAKE_COMPILER_CACHE_PIN+x}:${CMAKE_COMPILER_CACHE_PIN-}"
)
for cache_state in absent empty existing; do
  t_assert_ok _cache_slot_case "${cache_state}"
done
_empty_probe_case() (build_onnx_webgpu_factory_probe "$@")
for empty_arg in config prefix; do
  : > "${work}/steps"
  if [ "${empty_arg}" = config ]; then
    t_assert_fails _empty_probe_case '' 'installed prefix'
  else
    t_assert_fails _empty_probe_case 'configured parent' ''
  fi
  t_assert_eq '' "$(cat "${work}/steps")" 'empty paths fail before selecting tools'
done
for producer in 30-build-native.sh 30-build-native-nvidia.sh; do
  for failure in 0 11; do
    source="${common%/*}/../${producer}"
    tail="$(sed -n '/^build_onnx_webgpu_factory_probe /,$p' "${source}")"
    output='' status=0
    t_capture_command output status env PROBE_FAILURE="${failure}" bash -c '
      set -euo pipefail
      NATIVE_CPU_BUILD_DIR="CPU build"; NATIVE_GPU_BUILD_DIR="GPU build"
      NATIVE_CPU_OUTPUT_DIR="CPU prefix"; NATIVE_GPU_OUTPUT_DIR="GPU prefix"; NATIVE_CPU_CONFIG=Release
      build_onnx_webgpu_factory_probe() { printf "PROBE <%s> <%s>\n" "$@"; return "$PROBE_FAILURE"; }
      record_onnx_webgpu_build_products() { echo RECORD; }
      onnx_build_free_threaded_wheel() { echo FT; }
      err() { printf "ERR %s\n" "$*"; exit 37; }
      eval "$1"
    ' fixture "${tail}"
    if [ "${failure}" = 0 ]; then
      t_assert_eq 0 "${status}"
      t_assert_contains "${output}" $'\nRECORD\nFT'
      case "${producer}" in
        30-build-native.sh) t_assert_contains "${output}" 'PROBE <CPU build/Release> <CPU prefix>' ;;
        *) t_assert_contains "${output}" 'PROBE <GPU build/Release> <GPU prefix>' ;;
      esac
    else
      t_assert_eq 37 "${status}"
      [[ "${output}" != *RECORD* ]] || t_fail 'failed probe build reached receipt publication'
      [[ "${output}" != *$'\nFT'* ]] || t_fail 'failed probe build reached FT reconfiguration'
    fi
  done
done
t_summary
