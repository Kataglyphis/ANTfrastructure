#!/usr/bin/env bash
# compiler-llvm-tools.sh - the LLVM tools that belong to the compiler that built a tree.
#
# A raw profile or a module PCM records the LLVM that wrote it, and another LLVM's
# llvm-profdata ("no profile can be merged") or clang-tidy ("uses a newer format that
# cannot be read") refuses it. The images put a source-built clang behind clang/clang++
# while bare llvm-profdata, llvm-cov and clang-tidy on PATH can be an older distro LLVM.
# Moved up from AccelerANTgine's scripts/linux/ci-common.sh on 2026-09-24, when
# BeschleunigerBallett's coverage lane hit the same "no profile can be merged".
# Like its siblings it sets no shell options; info/warn come from log-bootstrap.sh.

[ -n "${_COMPILER_LLVM_TOOLS_SH_LOADED:-}" ] && return 0
_COMPILER_LLVM_TOOLS_SH_LOADED=1

# shellcheck source=./log-bootstrap.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-bootstrap.sh"

# compiler_llvm_tool <build-dir> <tool> - prints the absolute path of <tool> from
# the LLVM install of the C++ compiler that configured <build-dir> (its
# CMakeCache.txt CMAKE_CXX_COMPILER, else clang++), or fails printing nothing.
# -print-prog-name answers with the compiler's sibling binary, or with the bare
# name when it has none - which is why a relative answer is a failure.
compiler_llvm_tool() {
  local build_dir="$1" tool="$2" cxx="" path=""
  if [[ -f "${build_dir}/CMakeCache.txt" ]]; then
    cxx="$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' "${build_dir}/CMakeCache.txt" | head -n 1)"
  fi
  path="$("${cxx:-clang++}" -print-prog-name="${tool}" 2>/dev/null)" || return 1
  [[ "${path}" == /* && -x "${path}" ]] || return 1
  printf '%s\n' "${path}"
}

# use_compiler_llvm_tools <build-dir> <tool>... - puts the directory holding the
# compiler's own copy of EVERY named tool first on PATH, for functions that call
# them by bare name (coverage.sh, code-quality.sh). Warns and leaves PATH alone
# when the compiler has no such set; the caller's require_tools decides. Scope it
# (a subshell) when that directory holds a tool the caller must not swap:
# clang-format's version is a format verdict of its own.
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
