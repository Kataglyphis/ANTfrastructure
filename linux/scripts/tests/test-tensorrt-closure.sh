#!/usr/bin/env bash
# Callback fixtures check target-loader selection and failure accounting, not real ELF resolution, registration or inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BUILD="${TESTS_DIR}/../03-media/build/onnxruntime/build"
eval "$(t_fn_src "${BUILD}/37-build-tensorrt-plugin-ep.sh" trtep_closure_report)"
eval "$(t_fn_src "${BUILD}/37-build-tensorrt-plugin-ep.sh" trtep_closure_ok)"
eval "$(t_fn_src "${BUILD}/35-build-migraphx-plugin-ep.sh" mgxep_closure_ok)"
WORK="$(t_mktemp -d)"
mkdir -p "${WORK}/runtime space"
: > "${WORK}/runtime space/loader"
: > "${WORK}/runtime space/libstdc++.so.6"

closure_fixture() (
  mode="$1"
  export TRTEP_ORT_DIR=/chain
  export CUDA_CROSS_TARGET_ARCH=arm64 CUDA_CROSS_TARGET_TRIPLET=aarch64-linux-gnu
  export CUDA_CROSS_TARGET_ROOT=/cuda CUDA_CROSS_TENSORRT_HOME=/tensorrt
  export CC=fixture_cc CXX=fixture_cxx
  cuda_cross_active() { [ "${mode}" != native ]; }
  cuda_cross_load() { [ "${mode}" != setup-fail ] || return 37; }
  cross_target_qemu_runner() { [ "${mode}" != runner-fail ] || return 38; printf fixture_qemu; }
  fixture_cc() { [ "${mode}" != cc-fail ] || return 39; printf '%s' "${WORK}/runtime space/loader"; }
  fixture_cxx() {
    [ "${mode}" != cxx-fail ] || return 40
    if [ "${mode}" = missing ]; then printf libstdc++.so.6; else printf '%s' "${WORK}/runtime space/libstdc++.so.6"; fi
  }
  timeout() { printf 'timeout <%s> <%s>\n' "$1" "$2"; shift 2; "$@"; }
  fixture_qemu() {
    printf 'qemu'; printf ' <%s>' "$@"; printf '\n'
    [ "${mode}" != loader-fail ] || return 41
    printf '\tlibnvinfer.so.11 => /tensorrt/lib/libnvinfer.so.11\n'
    [ "${mode}" != missing-soname ] || printf '\tlibz.so.1 => not found\n'
  }
  ldd() { printf 'native-ldd <%s>\n' "$1"; }
  readelf() { printf '0x1 (NEEDED) Shared library: [libnvinfer.so.11]\n'; }
  case "${mode}" in foreign) CUDA_CROSS_TARGET_ARCH=riscv64 ;; esac
  if [ "${2:-report}" = closure ]; then
    TENSORRT_VERSION=11.4.0 trtep_closure_ok /plugin.so
  else
    trtep_closure_report /plugin.so
  fi
)

t_case 'native closure retains ldd without entering the cross callbacks'
t_assert_eq 'native-ldd </plugin.so>' "$(closure_fixture native)"

t_case 'cross closure keeps the timeout, target loader, explicit SDK paths and argument boundaries'
out="$(closure_fixture cross)"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" 'timeout <--kill-after=5s> <60s>'
t_assert_contains "${out}" "qemu <${WORK}/runtime space/loader> <--inhibit-cache> <--library-path>"
t_assert_contains "${out}" "</chain/lib:/tensorrt/lib:/cuda/lib:${WORK}/runtime space:/usr/aarch64-linux-gnu/lib:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu> <--list> </plugin.so>"

t_case 'a failed descriptor, runner or compiler lookup preserves its raw status'
for row in setup-fail:37 runner-fail:38 cc-fail:39 cxx-fail:40 loader-fail:41; do
  out="$(closure_fixture "${row%:*}" 2>&1)"; rc=$?
  t_assert_eq "${row#*:}" "${rc}"
done

t_case 'unsupported targets and unresolved runtime files refuse before invoking QEMU'
for mode in missing foreign; do
  out="$(closure_fixture "${mode}" 2>&1)"; rc=$?
  t_assert_eq 1 "${rc}"
  t_assert_eq 1 "$(t_rc grep -F 'qemu <' <<< "${out}")"
done

t_case 'the real TensorRT gate uses the callback and retains both transport and missing-library failures'
t_assert_eq 0 "$(t_rc closure_fixture cross closure)"
for mode in loader-fail missing-soname; do
  out="$(closure_fixture "${mode}" closure 2>&1)"; rc=$?
  t_assert_eq 1 "${rc}"
done
t_assert_contains "${out}" 'cannot resolve: libz.so.1'

t_summary
