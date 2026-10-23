#!/usr/bin/env bash
# Compiler-name fixtures cover validation and wrapper inputs; no compiler, package manager or TVM build runs.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
TVM="${1:-${TESTS_DIR}/../05-frameworks/tvm.sh}"
for fn in require_toolchain_compilers select_tvm_compilers; do
  eval "$(t_fn_src "$TVM" "$fn")"
done
if grep -q '^_tvm_gcc_commands()' "$TVM"; then
  eval "$(t_fn_src "$TVM" _tvm_gcc_commands)"
fi
source "${TESTS_DIR}/../01-core/logging.sh"
_work=$(mktemp -d)
trap 'rm -rf "$_work"' EXIT
export GCC_WANTED=fixture
maybe_wrap_compiler_to_prefer_gcc_cxxabi_header() {
  printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4" > "$_work/wrapper"
  printf '%s %s' "$3" "$4"
}

_compiler_fixture() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local executable
  for executable in "$@"; do
    printf '#!/bin/sh\nexit 99\n' > "$dir/$executable"
    chmod +x "$dir/$executable"
  done
}

_probe() {
  local path="$1" cc="$2" cxx="$3" mode="$4"
  (
    PATH="$path"
    export CC="$cc" CXX="$cxx"
    if [[ "$mode" == require ]]; then
      require_toolchain_compilers
    else
      local desired_cc='' desired_cxx=''
      local -x llvm_config=fixture-llvm build_dir=fixture-build
      select_tvm_compilers
      printf '%s|%s' "$desired_cc" "$desired_cxx"
    fi
  )
}

for layout in pinned fallback mixed; do
  dir="$_work/$layout"
  case "$layout" in
    pinned) _compiler_fixture "$dir" gcc-fixture g++-fixture gcc g++; c=gcc-fixture; cxx=g++-fixture ;;
    fallback) _compiler_fixture "$dir" gcc g++; c=gcc; cxx=g++ ;;
    mixed) _compiler_fixture "$dir" gcc-fixture g++; c=gcc-fixture; cxx=g++ ;;
  esac
  t_case "$layout names are shared by toolchain validation and selection"
  t_assert_eq 0 "$(t_rc _probe "$dir" '' '' require)"
  t_assert_eq "$dir/$c|$dir/$cxx" "$(_probe "$dir" '' '' select)"
  t_assert_eq "fixture-llvm|fixture-build|$dir/$c|$dir/$cxx" "$(cat "$_work/wrapper")"
  _compiler_fixture "$dir" custom-c custom-cxx
  t_case "$layout selection respects independent CC and CXX overrides"
  t_assert_eq 0 "$(t_rc _probe "$dir" "$dir/custom-c" "$dir/custom-cxx" require)"
  t_assert_eq "$dir/custom-c|$dir/custom-cxx" "$(_probe "$dir" "$dir/custom-c" "$dir/custom-cxx" select)"
  t_assert_eq "$dir/custom-c|$dir/$cxx" "$(_probe "$dir" "$dir/custom-c" '' select)"
  t_assert_eq "$dir/$c|$dir/custom-cxx" "$(_probe "$dir" '' "$dir/custom-cxx" select)"
done

for missing in gcc g++ CC CXX; do
  t_case "missing $missing fails validation with its original diagnostic"
  dir="$_work/no-$missing"
  case "$missing" in
    gcc) _compiler_fixture "$dir" g++; cc=''; cxx=''; expected="Expected GCC from linux/Dockerfile.toolchain, but 'gcc' is unavailable" ;;
    g++) _compiler_fixture "$dir" gcc; cc=''; cxx=''; expected="Expected G++ from linux/Dockerfile.toolchain, but 'g++' is unavailable" ;;
    CC) _compiler_fixture "$dir" gcc g++; cc=absent; cxx=''; expected='CC=absent is set but not available' ;;
    CXX) _compiler_fixture "$dir" gcc g++; cc=''; cxx=absent; expected='CXX=absent is set but not available' ;;
  esac
  _rc=0
  _out=$(_probe "$dir" "$cc" "$cxx" require 2>&1) || _rc=$?
  t_assert_eq 1 "$_rc"
  t_assert_contains "$_out" "$expected"
done

t_case 'selection alone preserves unresolved explicit commands for the wrapper'
t_assert_eq 'missing-c|missing-cxx' "$(_probe "$_work/fallback" missing-c missing-cxx select)"
t_summary
