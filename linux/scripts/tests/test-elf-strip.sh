#!/usr/bin/env bash
# Stubbed file/strip tools cover selection, parallelism and best-effort failures; real ELF mutation is outside this suite.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
REAL_XARGS="$(command -v xargs)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/tree" "${WORK}/minimal" "${WORK}/empty"
cp "${TESTS_DIR}/../02-toolchain/bootstrap.sh" "${WORK}/minimal/"
if [ -f "${TESTS_DIR}/../01-core/elf-strip.sh" ]; then cp "${TESTS_DIR}/../01-core/elf-strip.sh" "${WORK}/minimal/"; fi
printf 'elf\n' > "${WORK}/tree/binary"
printf 'text\n' > "${WORK}/tree/plain"
printf 'elf\n' > "${WORK}/tree/binary with spaces"
cat > "${WORK}/bin/file" <<'STUB'
#!/bin/sh
for path do
  case "$path" in */binary|*/binary\ with\ spaces) printf '%s: ELF shared object\n' "$path" ;; *) printf '%s: ASCII text\n' "$path" ;; esac
done
STUB
cat > "${WORK}/bin/strip-fixture" <<'STUB'
#!/bin/sh
printf '<%s>\n' "$@" >> "${STRIP_CALLS}"
printf 'ignored strip diagnostic\n' >&2
exit "${STRIP_STATUS:-0}"
STUB
cat > "${WORK}/bin/xargs" <<'STUB'
#!/bin/sh
printf '<%s>' "$@" > "${XARGS_CALLS}"
exec "${XARGS_REAL}" "$@"
STUB
chmod +x "${WORK}/bin/file" "${WORK}/bin/strip-fixture" "${WORK}/bin/xargs"
run_strip() {
  local mode="$1" tree="$2" status="$3" output result=0
  : > "${WORK}/calls"
  output="$(PATH="${WORK}/bin:${PATH}" STRIP_CALLS="${WORK}/calls" XARGS_REAL="${REAL_XARGS}" XARGS_CALLS="${WORK}/xargs" STRIP_STATUS="${status}" \
    bash -c 'set -euo pipefail
      if [ "$1" = full ]; then
        source "$2/../01-core/build-helpers.sh"
      else
        source "$3/minimal/bootstrap.sh"
        source_toolchain_build_helpers_or_fallback "$3/minimal"
      fi
      strip_elf_tree "$4" 2 strip-fixture' _ "${mode}" "${TESTS_DIR}" "${WORK}" "${tree}" 2>&1)" || result=$?
  printf 'STATUS=%s\n%s' "${result}" "${output}"
}
for mode in full minimal; do
  t_case "${mode}: strip only ELF files with the requested tool"
  t_assert_eq 'STATUS=0' "$(run_strip "${mode}" "${WORK}/tree" 0)"
  t_assert_eq '<--strip-all>' "$(head -1 "${WORK}/calls")"
  t_assert_eq "$(printf '<%s>\n' "${WORK}/tree/binary" "${WORK}/tree/binary with spaces" | LC_ALL=C sort)" \
    "$(tail -n +2 "${WORK}/calls" | LC_ALL=C sort)"
  t_assert_eq '<-0><-r><-P2><strip-fixture><--strip-all>' "$(cat "${WORK}/xargs")"
  t_case "${mode}: a strip failure stays quiet and best-effort"
  t_assert_eq 'STATUS=0' "$(run_strip "${mode}" "${WORK}/tree" 7)"
  t_assert_contains "$(cat "${WORK}/calls")" "${WORK}/tree/binary"
  t_case "${mode}: an absent tree is a no-op"
  t_assert_eq 'STATUS=0' "$(run_strip "${mode}" "${WORK}/missing" 0)"
  t_assert_eq '' "$(cat "${WORK}/calls")"
  t_case "${mode}: an empty tree does not invoke strip with an empty filename"
  t_assert_eq 'STATUS=0' "$(run_strip "${mode}" "${WORK}/empty" 0)"
  t_assert_eq '' "$(cat "${WORK}/calls")"
done

cat > "${WORK}/bin/strip" <<'STUB'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "${STRIP_CALLS}"
STUB
cp "${WORK}/bin/strip" "${WORK}/bin/fixture-strip"
chmod +x "${WORK}/bin/strip" "${WORK}/bin/fixture-strip" "${WORK}/tree/binary" "${WORK}/tree/binary with spaces"
: > "${WORK}/calls"
t_case "GCC keeps host and target strip passes over executable/shared ELF files"
status=0
output="$(PATH="${WORK}/bin:${PATH}" STRIP_CALLS="${WORK}/calls" XARGS_REAL="${REAL_XARGS}" XARGS_CALLS="${WORK}/xargs" bash -c '
  set -euo pipefail
  source "$3/../01-core/elf-strip.sh"
  eval "$1"
  SUDO=""; PREFIX="$2/tree"; JOBS=2; TARGET_TRIPLET=fixture
  _gcc_strip_binaries' _ "$(t_fn_src "${TESTS_DIR}/../02-toolchain/build-gcc.sh" _gcc_strip_binaries)" "${WORK}" "${TESTS_DIR}" 2>&1)" || status=$?
t_assert_eq 0 "${status}" "${output}"
t_assert_eq 2 "$(wc -l < "${WORK}/calls")"
t_assert_contains "$(cat "${WORK}/calls")" 'strip --strip-all'
t_assert_contains "$(cat "${WORK}/calls")" 'fixture-strip --strip-all'
t_assert_fails grep -q '/plain' "${WORK}/calls"
t_summary
