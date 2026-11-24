#!/usr/bin/env bash
# TVM must link a private static LLVM; see docs/linux-cross-builds.md#tvm-links-a-private-static-llvm
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
TVM_SH="${TESTS_DIR}/../05-frameworks/tvm.sh"
log() { :; }
die() { printf 'DIE:%s\n' "$*" >&2; exit 97; }

eval "$(t_fn_src "${TVM_SH}" _tvm_findllvm_unpatched)" || exit 1
eval "$(t_fn_src "${TVM_SH}" patch_tvm_findllvm_private_static)" || exit 1
eval "$(t_fn_src "${TVM_SH}" assert_tvm_private_llvm)" || exit 1
root="$(t_mktemp -d)" || exit 1

# The upstream lines around the anchor at the pinned TVM commit.
_findllvm() {
  mkdir -p "$1/cmake/utils"
  printf '%s\n' '    find_package(LLVM ${llvm_version_required} REQUIRED CONFIG)' \
    '    llvm_map_components_to_libnames(LLVM_LIBS "all")' '    if (NOT LLVM_LIBS)' > "$1/cmake/utils/FindLLVM.cmake"
}

_section_patch() {
  t_case "the patch keeps only static LLVM targets right after the component map, once"
  # shellcheck disable=SC2034  # ref is read by the lifted patch through dynamic scope
  local tvm_dir="${root}/tvm" ref=fixture out
  _findllvm "${tvm_dir}"
  ( patch_tvm_findllvm_private_static && patch_tvm_findllvm_private_static ) || t_assert_eq 0 1 "patch failed"
  out="$(cat "${tvm_dir}/cmake/utils/FindLLVM.cmake")"
  t_assert_eq 1 "$(printf '%s\n' "${out}" | grep -c -e 'private static LLVM' || true)" "a second run must not patch again"
  t_assert_eq '    # private static LLVM: an installed package maps "all" to nothing, so pick its static targets' \
    "$(printf '%s\n' "${out}" | sed -n 3p)" "the selection must follow the map line"
  t_assert_contains "${out}" $'    if(NOT LLVM_LIBS)\n      set(LLVM_LIBS ${LLVM_AVAILABLE_LIBS})'
  t_assert_contains "${out}" 'if(_tvm_llvm_type STREQUAL "STATIC_LIBRARY")'
  t_assert_contains "${out}" $'    endforeach()\n    set(LLVM_LIBS ${_tvm_llvm_static})'

  t_case "a changed upstream layout refuses instead of building against the shared LLVM"
  tvm_dir="${root}/moved"
  mkdir -p "${tvm_dir}/cmake/utils"
  printf '%s\n' '  llvm_map_components_to_libnames(LLVM_LIBS all)' > "${tvm_dir}/cmake/utils/FindLLVM.cmake"
  t_assert_contains "$( (patch_tvm_findllvm_private_static) 2>&1)" "DIE:TVM FindLLVM.cmake: expected one LLVM component map line"
}

# _lib <name> <soname-of-dependency|-> <source>: a real shared library built by the host compiler.
_lib() {
  local name="$1" dep="$2" source="$3"
  printf '%s\n' "${source}" > "${root}/${name}.cc"
  if [ "${dep}" = - ]; then
    c++ -shared -fPIC -o "${root}/${name}" "${root}/${name}.cc"
  else
    c++ -shared -fPIC -o "${root}/${name}" "${root}/${name}.cc" -L"${root}" -l:"${dep}"
  fi
}

_section_elf() {
  command -v c++ >/dev/null && command -v readelf >/dev/null || { t_assert_eq "c++ and readelf" "missing" "host compiler"; return; }
  c++ -shared -fPIC -Wl,-soname,libLLVM.so.99 -o "${root}/libLLVM.so.99" -x c++ - <<< 'int llvm_fixture() { return 1; }'
  _lib private.so - 'namespace llvm { __attribute__((visibility("hidden"))) int hidden() { return 1; } } int tvm_entry() { return llvm::hidden(); }'
  _lib shared.so libLLVM.so.99 'int llvm_fixture(); int tvm_entry() { return llvm_fixture(); }'
  _lib exported.so - 'namespace llvm { int leaked() { return 1; } } int tvm_entry() { return llvm::leaked(); }'

  t_case "a library with LLVM inside and nothing of it exported passes"
  t_assert_eq "0" "$( (assert_tvm_private_llvm "${root}/private.so") >/dev/null 2>&1; echo $?)"
  t_case "a NEEDED shared libLLVM fails"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/shared.so") 2>&1)" "DIE:TVM private LLVM: ${root}/shared.so needs a shared libLLVM"
  t_case "an exported llvm:: symbol fails"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/exported.so") 2>&1)" "exports 1 llvm:: symbol(s)"
  t_case "a library that was never built fails"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/absent.so") 2>&1)" "was not built"
}

_section_smoke() {
  t_case "the runtime codegen smoke refuses a process that mapped a shared LLVM"
  local body
  body="$(sed -n '/^assert_tvm_codegen() {/,/^}/p' "${TESTS_DIR}/../06-packaging/smoke-torch-venv.sh")"
  t_assert_contains "${body}" 'if "/libLLVM" in line'
  t_assert_contains "${body}" 'TVM-CODEGEN FAIL: tvm loaded a shared LLVM'
  t_case "the build asserts the private LLVM whenever TVM uses LLVM"
  t_assert_contains "$(cat "${TVM_SH}")" '[ "$llvm_cmake_value" = "OFF" ] || assert_tvm_private_llvm "$build_dir/lib/libtvm_compiler.so"'
  t_assert_contains "$(t_fn_src "${TVM_SH}" main)" $'patch_tvm_findllvm_dylib_fallback\n  patch_tvm_findllvm_private_static'
}

t_sections _section_patch _section_elf _section_smoke -- "$@"
t_summary
