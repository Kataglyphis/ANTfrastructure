#!/usr/bin/env bash
# Stubbed metadata and ELF probes check verdict policy; real compilers and shipped-image contents are outside this suite.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
VALIDATOR="${1:-${TESTS_DIR}/../06-packaging/validate-compilers.sh}"
t_source_functions "${VALIDATOR}" validate_fail _cc_target_dumpmachine _cc_target_elf_check \
  _artifact_source_check_native_gcc _artifact_source_check_llvm || exit 1
for helper in _cc_target_failure _artifact_source_check_target_elf _vc_elf_machine_header _vc_elf_header_matches _vc_gcc_version_matches; do
  if grep -Eq "^${helper}\(\)" "${VALIDATOR}"; then eval "$(t_fn_src "${VALIDATOR}" "${helper}")"; fi
done
run_probe() {
  local probe="$1" mode="$2" fixture_machine="$3" dump="$4" status=0 output
  output="$(
    set -e
    _VALIDATE_ERRORS=0
    _VCS_TARGET_ARCH=arm64; _VCS_GCC_PREFIX=/fixture/gcc
    _VCS_CC_TARGET_ARCH=arm64; _VCS_CC_MODE="${mode}"; _VCS_CC_PATH=/fixture/cc
    _VCS_CC_EXPECTED_PATTERN=aarch64; _VCS_CC_PATTERN=AArch64
    export GCC_VERSION=fixture LLVM_RELEASE=fixture VALIDATE_CC_STATIC_ONLY=0
    function [ {
      case "${1:-}:${2:-}:${3:-}" in
        !:-e:/opt/llvm-target) return 1 ;;
        -d:/opt/gcc-* | -x:/opt/gcc-* | -e:/opt/llvm-target:* | -x:/opt/llvm-target/bin/clang:*) return 0 ;;
        *) builtin [ "$@" ;;
      esac
    }
    cc() { printf '%s' "${dump}"; }
    elf_machine_name() { printf '%s' "${fixture_machine}"; }
    arch_to_elf_machine() { printf '%s' AArch64; }
    readelf() { printf '  Machine: %s\n' "${fixture_machine}"; }
    _vc_clang_embedded_version() { printf '%s' wrong-version; }
    "${probe}"
    printf 'ERRORS=%s\n' "${_VALIDATE_ERRORS}"
  )" 2>&1 || status=$?
  printf 'STATUS=%s\n%s\n' "${status}" "${output}"
}
for probe in _cc_target_dumpmachine _cc_target_elf_check; do
  t_case "${probe}: successful architecture probe"
  result="$(run_probe "${probe}" smoke AArch64 aarch64-linux-gnu)"
  t_assert_contains "${result}" STATUS=0
  t_assert_contains "${result}" ERRORS=0
  t_assert_contains "${result}" Verified
  for bad in wrong ''; do
    for mode in smoke hard-fail; do
      t_case "${probe}: ${mode} rejects '${bad}' metadata"
      result="$(run_probe "${probe}" "${mode}" "${bad}" "${bad}" 2>&1)"
      if [ "${mode}" = hard-fail ]; then
        t_assert_contains "${result}" STATUS=1
        t_assert_contains "${result}" 'ERROR:'
      else
        t_assert_contains "${result}" STATUS=0
        t_assert_contains "${result}" ERRORS=1
        t_assert_contains "${result}" 'COMPILER FAIL ['
      fi
    done
  done
done
for probe in _artifact_source_check_native_gcc _artifact_source_check_llvm; do
  for machine in AArch64 wrong ''; do
    t_case "${probe}: target ELF fallback '${machine}'"
    result="$(run_probe "${probe}" smoke "${machine}" '' 2>&1)"
    t_assert_contains "${result}" STATUS=0
    if [ "${machine}" = AArch64 ]; then
      t_assert_contains "${result}" 'cross-built ELF for arm64'
      t_assert_contains "${result}" ERRORS=0
    else
      t_assert_contains "${result}" 'COMPILER FAIL ['
      t_assert_contains "${result}" ERRORS=1
      t_assert_contains "${result}" '--version:'
    fi
  done
done
t_summary
