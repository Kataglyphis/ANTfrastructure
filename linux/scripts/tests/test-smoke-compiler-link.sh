#!/usr/bin/env bash
# Fake compiler and filesystem failures cover link verdicts; no real ELF, SDK or target execution is proved.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
subject="${1:-${TESTS_DIR}/../06-packaging/smoke-common.sh}"
source "${TESTS_DIR}/../06-packaging/smoke-common.sh"
t_source_functions "${subject}" validate_compiler_for_target || exit 1
t_private_tmpdir
work="$(t_mktemp -d)"
mkdir -p "${work}/scratch"
TMPDIR="${work}/scratch"
export TMPDIR
smoke_uname_name() { printf x86_64; }
smoke_elf_machine_grep() { printf X86-64; }
_cc_check_dumpmachine() { return 0; }
_cc_check_binary_elf() { printf 'binary\n' >> "${work}/checks"; }
_cc_check_object() { printf 'object\n' >> "${work}/checks"; }
_cc_check_loader() { printf 'loader\n' >> "${work}/checks"; }
_cc_check_qemu_exec() { printf 'qemu\n' >> "${work}/checks"; }
fixture_compiler() {
  printf '%s\n' "$*" >> "${work}/invoked"
  cat > "${work}/program"
  printf '%s\n' 'fixture linker diagnostic' >&2
  [ "${compiler_mode}" = success ] || return 19
  printf executable > "${@: -1}"
}
for mode in native cross; do
  for compiler_mode in success failure; do
    t_case "${mode} link ${compiler_mode} preserves diagnostics and aggregate verdict"
    : > "${work}/checks"
    FAILURES=0
    status=0
    validate_compiler_for_target fixture_compiler amd64 fixture "${mode}" > "${work}/stdout" 2> "${work}/stderr" || status=$?
    expected=0
    [ "${compiler_mode}" = success ] || expected=1
    t_assert_eq "${expected}" "${FAILURES}"
    t_assert_eq 0 "${status}"
    t_assert_contains "$(cat "${work}/stderr")" 'fixture linker diagnostic'
    t_assert_eq 'int main(void){return 0;}' "$(cat "${work}/program")"
    t_assert_eq 0 "$(ls -A "${TMPDIR}" | wc -l | tr -d ' ')"
    t_assert_contains "$(cat "${work}/checks")" object
    if [ "${compiler_mode}" = failure ]; then
      t_assert_contains "$(cat "${work}/stderr")" 'link smoke FAILED (rc=19)'
      t_assert_no_grep "${work}/checks" 'loader|qemu'
    else
      t_assert_contains "$(cat "${work}/checks")" loader
      if [ "${mode}" = cross ]; then
        t_assert_contains "$(cat "${work}/checks")" qemu
      else
        t_assert_no_grep "${work}/checks" qemu
      fi
    fi
  done
done

t_case 'failed directory cleanup retains its raw status and cannot pass'
compiler_mode=success
FAILURES=0
rm() { return 73; }
status=0
validate_compiler_for_target fixture_compiler amd64 fixture cross > "${work}/stdout" 2> "${work}/stderr" || status=$?
unset -f rm
t_assert_eq 73 "${status}"
t_assert_eq 1 "${FAILURES}"
t_assert_contains "$(cat "${work}/stderr")" 'cannot remove link smoke directory (rc=73)'
command rm -rf -- "${TMPDIR:?}"/*

t_case 'invalid allocation never invokes the compiler or linked checks'
mktemp() { t_failed_temp_allocation "${allocation_mode}" "${work}/absent"; }
for allocation_mode in failed empty missing; do
  FAILURES=0
  : > "${work}/invoked"
  : > "${work}/checks"
  status=0
  validate_compiler_for_target fixture_compiler amd64 fixture cross > "${work}/stdout" 2> "${work}/stderr" || status=$?
  t_assert_eq 1 "${status}" "${allocation_mode} allocation must fail"
  t_assert_eq 1 "${FAILURES}"
  t_assert_eq '' "$(cat "${work}/invoked")"
  t_assert_no_grep "${work}/checks" 'loader|qemu'
done
unset -f mktemp
t_summary
