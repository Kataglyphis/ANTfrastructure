#!/usr/bin/env bash
# Real shared libraries for the private-LLVM checks; see docs/linux-cross-builds.md#tvm-links-a-private-static-llvm

# <dir>: libLLVM.so.99, plus shared.so that needs it and private.so that needs no LLVM.
t_llvm_elf_fixture() {
  local dir="$1"
  c++ -shared -fPIC -Wl,-soname,libLLVM.so.99 -o "${dir}/libLLVM.so.99" -x c++ - <<< 'int llvm_fixture() { return 1; }' || return 1
  c++ -shared -fPIC -o "${dir}/private.so" -x c++ - \
    <<< 'namespace llvm { __attribute__((visibility("hidden"))) int hidden() { return 1; } } int tvm_entry() { return llvm::hidden(); }' || return 1
  c++ -shared -fPIC -o "${dir}/shared.so" -x c++ - -L"${dir}" -l:libLLVM.so.99 \
    <<< 'int llvm_fixture(); int tvm_entry() { return llvm_fixture(); }' || return 1
  return 0
}
