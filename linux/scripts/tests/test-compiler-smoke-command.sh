#!/usr/bin/env bash
# Stubbed cc checks command shape, failure propagation and cleanup; real compiler/linker correctness is outside this suite.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
VALIDATE="${TESTS_DIR}/../06-packaging/validate-compilers.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
t_source_functions "${VALIDATE}" \
  _cc_target_run_smoke _cc_target_compile_smoke _cc_target_link_smoke || exit 1
run_smoke() {
  local kind="$1" mode="$2" compiler_rc="$3" status=0
  rm -rf "${WORK}/probe"
  (
    _VCS_CC_TARGET_ARCH=arm64; _VCS_CC_MODE="${mode}"; _VCS_CC_PATTERN=AArch64
    mktemp() { mkdir -p "${WORK}/probe"; printf '%s\n' "${WORK}/probe"; }
    cc() {
      printf '%s\n' "$@" > "${WORK}/args"
      cat > "${WORK}/source"
      printf 'compiler diagnostic\n' >&2
      return "${compiler_rc}"
    }
    validate_fail() { printf 'FAIL [%s]: %s\n' "$1" "$2"; }
    _cc_target_object_elf_check() { printf 'ELF [%s]\n' "${_VCS_CC_OBJ}"; }
    "_cc_target_${kind}_smoke"
  ) > "${WORK}/output" 2>&1 || status=$?
  printf '%s' "${status}"
}
for kind in compile link; do
  t_case "${kind}: successful command cleans its temporary directory"
  t_assert_eq 0 "$(run_smoke "${kind}" smoke 0)"
  t_assert_fails test -e "${WORK}/probe"
  args="$(cat "${WORK}/args")"
  t_assert_contains "${args}" $'-x\nc\n-'
  if [ "${kind}" = compile ]; then
    t_assert_contains "${args}" $'-c\n-o'
    t_assert_contains "$(cat "${WORK}/source")" 'int answer(void){return 42;}'
    t_assert_contains "$(cat "${WORK}/output")" "ELF [${WORK}/probe/cc1smoke.o]"
  else
    t_assert_rc 1 grep -Eq '^-c$' "${WORK}/args"
    t_assert_contains "$(cat "${WORK}/source")" 'int main(void){return 0;}'
    t_assert_rc 1 grep -Fq 'ELF' "${WORK}/output"
  fi
  t_case "${kind}: advisory failure reports its own gate and cleans up"
  t_assert_eq 0 "$(run_smoke "${kind}" smoke 7)"
  t_assert_contains "$(cat "${WORK}/output")" 'FAIL ['
  t_assert_fails test -e "${WORK}/probe"
  t_case "${kind}: mandatory failure exits with diagnostics and cleans up"
  t_assert_eq 1 "$(run_smoke "${kind}" hard-fail 7)"
  t_assert_contains "$(cat "${WORK}/output")" 'compiler diagnostic'
  t_assert_contains "$(cat "${WORK}/output")" 'FAILED for arm64'
  t_assert_fails test -e "${WORK}/probe"
done
t_summary
