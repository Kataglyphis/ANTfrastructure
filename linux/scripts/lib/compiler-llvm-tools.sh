#!/usr/bin/env bash
# Another LLVM refuses a tree's profiles and PCMs; sets no shell options. docs/shared-script-libraries.md#compiler-llvm-toolssh--the-llvm-tools-of-the-compiler-that-built-a-tree

[ -n "${_COMPILER_LLVM_TOOLS_SH_LOADED:-}" ] && return 0
_COMPILER_LLVM_TOOLS_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# <build-dir> <tool>; a relative -print-prog-name answer means no sibling binary, so it fails.
compiler_llvm_tool() {
  local build_dir="$1" tool="$2" cxx="" path=""
  if [[ -f "${build_dir}/CMakeCache.txt" ]]; then
    cxx="$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' "${build_dir}/CMakeCache.txt" | head -n 1)"
  fi
  path="$("${cxx:-clang++}" -print-prog-name="${tool}" 2>/dev/null)" || return 1
  [[ "${path}" == /* && -x "${path}" ]] || return 1
  printf '%s\n' "${path}"
}

# <build-dir> <tool>...; use a subshell when that dir holds a tool you must not swap, like clang-format.
use_compiler_llvm_tools() {
  local build_dir="$1" path dir tool
  shift
  if ! path="$(compiler_llvm_tool "${build_dir}" "$1")"; then
    warn "The compiler of '${build_dir}' names no $1 of its own; using PATH's $*, which must read what that compiler wrote."
    return 0
  fi
  dir="$(dirname "${path}")"
  for tool in "$@"; do
    if [[ ! -x "${dir}/${tool}" ]]; then
      warn "${dir} has no ${tool} beside $1; using PATH's $*, which must read what that compiler wrote."
      return 0
    fi
  done
  PATH="${dir}:${PATH}"
  export PATH
  hash -r
  info "LLVM tools matching the compiler of '${build_dir}': ${dir} ($*)"
}
