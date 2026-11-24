#!/usr/bin/env bash
# TVM must link a private static LLVM; see docs/linux-cross-builds.md#tvm-links-a-private-static-llvm
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=linux/scripts/tests/llvm-elf-fixture.sh
source "${TESTS_DIR}/llvm-elf-fixture.sh"
TVM_SH="${TESTS_DIR}/../05-frameworks/tvm.sh"
log() { :; }
die() { printf 'DIE:%s\n' "$*" >&2; exit 97; }

eval "$(t_fn_src "${TVM_SH}" _tvm_source_unpatched)" || exit 1
eval "$(t_fn_src "${TVM_SH}" _tvm_insert_after_anchor)" || exit 1
eval "$(t_fn_src "${TVM_SH}" patch_tvm_compiler_llvm_symbols_local)" || exit 1
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
  t_assert_contains "$( (patch_tvm_findllvm_private_static) 2>&1)" "DIE:TVM FindLLVM.cmake: expected one line '    llvm_map_components_to_libnames(LLVM_LIBS \"all\")'"
}

# A missing host compiler is a failed case, never a silent skip.
_host_tools() {
  command -v c++ >/dev/null && command -v readelf >/dev/null && return 0
  t_assert_eq "c++ and readelf" "missing" "host compiler"
  return 1
}


_section_elf() {
  _host_tools || return
  t_llvm_elf_fixture "${root}" || { t_assert_eq 0 1 "the host compiler could not build the ELF fixture"; return; }
  c++ -shared -fPIC -o "${root}/exported.so" -x c++ - <<< 'namespace llvm { int leaked() { return 1; } } int tvm_entry() { return llvm::leaked(); }'

  t_case "a library with LLVM inside and nothing of it exported passes"
  t_assert_eq "0" "$( (assert_tvm_private_llvm "${root}/private.so") >/dev/null 2>&1; echo $?)"
  t_case "a NEEDED shared libLLVM fails"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/shared.so") 2>&1)" "DIE:TVM private LLVM: ${root}/shared.so needs a shared libLLVM"
  t_case "an exported llvm:: symbol fails"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/exported.so") 2>&1)" "exports 1 llvm:: symbol(s): _ZN4llvm6leakedEv"
  t_case "a library that was never built fails"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/absent.so") 2>&1)" "was not built"
}

_section_map() {
  _host_tools || return
  t_case "libtvm_compiler links with a version script that keeps llvm:: local, added once"
  # shellcheck disable=SC2034  # ref is read by the lifted patch through dynamic scope
  local tvm_dir="${root}/map" ref=fixture out inline='namespace llvm { template <class T> struct Manager { ~Manager() {} T value; }; } void tvm_entry() { llvm::Manager<int> m; (void)m; }'
  mkdir -p "${tvm_dir}"
  printf '%s\n' 'add_library(tvm_compiler SHARED)' 'set_property(TARGET tvm_compiler APPEND PROPERTY LINK_OPTIONS "${TVM_VISIBILITY_FLAG}")' \
    'set_property(TARGET tvm_compiler APPEND PROPERTY LINK_OPTIONS "-Wl,--no-relax")' > "${tvm_dir}/CMakeLists.txt"
  ( patch_tvm_compiler_llvm_symbols_local && patch_tvm_compiler_llvm_symbols_local ) || t_assert_eq 0 1 "patch failed"
  out="$(cat "${tvm_dir}/CMakeLists.txt")"
  t_assert_eq 'set_property(TARGET tvm_compiler APPEND PROPERTY LINK_OPTIONS "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/private-llvm.map")' \
    "$(printf '%s\n' "${out}" | sed -n 3p)" "the version script must follow the visibility line"
  t_assert_eq 1 "$(printf '%s\n' "${out}" | grep -c -e 'private-llvm.map' || true)" "a second run must not patch again"

  t_case "the generated map hides inline llvm:: members a TVM object instantiates"
  printf '%s\n' "${inline}" > "${root}/inline.cc"
  c++ -shared -fPIC -O0 -o "${root}/inline-open.so" "${root}/inline.cc"
  c++ -shared -fPIC -O0 -Wl,--version-script="${tvm_dir}/private-llvm.map" -o "${root}/inline-local.so" "${root}/inline.cc"
  t_assert_contains "$( (assert_tvm_private_llvm "${root}/inline-open.so") 2>&1)" "llvm:: symbol(s): _ZN4llvm7ManagerIiED"
  t_assert_eq "0" "$( (assert_tvm_private_llvm "${root}/inline-local.so") >/dev/null 2>&1; echo $?)"
  t_assert_contains "$(readelf --dyn-syms -W "${root}/inline-local.so")" "tvm_entry"

  t_case "a changed upstream layout refuses instead of exporting llvm:: symbols"
  tvm_dir="${root}/map-moved"
  mkdir -p "${tvm_dir}"
  printf '%s\n' 'add_library(tvm_compiler SHARED)' > "${tvm_dir}/CMakeLists.txt"
  t_assert_contains "$( (patch_tvm_compiler_llvm_symbols_local) 2>&1)" "DIE:TVM CMakeLists.txt: expected one line 'set_property(TARGET tvm_compiler APPEND PROPERTY LINK_OPTIONS \"\${TVM_VISIBILITY_FLAG}\")'"
}

_section_smoke() {
  t_case "the build asserts the private LLVM whenever TVM uses LLVM"
  t_assert_contains "$(cat "${TVM_SH}")" '[ "$llvm_cmake_value" = "OFF" ] || assert_tvm_private_llvm "$build_dir/lib/libtvm_compiler.so"'
  t_assert_contains "$(t_fn_src "${TVM_SH}" main)" $'patch_tvm_findllvm_dylib_fallback\n  patch_tvm_findllvm_private_static\n  patch_tvm_compiler_llvm_symbols_local\n  resolve_tvm_llvm'
}

t_sections _section_patch _section_elf _section_map _section_smoke -- "$@"
t_summary
