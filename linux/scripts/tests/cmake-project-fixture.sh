#!/usr/bin/env bash
# Compiler-less CMake projects exercise module policies without finding or invoking a compiler.
_CMAKE_PROJECT_FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CMAKE_PROJECT_FIXTURE_DIR}/test-harness.sh"

cmake_fixture_module_root() {
  (cd "${_CMAKE_PROJECT_FIXTURE_DIR}/../../../cmake" && {
    if [ "${1:-}" = --native ]; then pwd -W 2>/dev/null || pwd; else pwd; fi
  })
}

_cmake_project() {
  local dir
  if [ "$#" -gt 1 ]; then dir="$(mktemp -d "$2")"; else dir="$(mktemp -d)"; fi
  printf 'cmake_minimum_required(VERSION 3.20)\nproject(p NONE)\n%s\n' "$1" > "${dir}/CMakeLists.txt"
  printf '%s' "${dir}"
}

# cmake_fixture_output <cmake body> [cmake args...]: configures the body in a throwaway project and prints everything cmake said.
cmake_fixture_output() {
  local proj rc=0
  proj="$(_cmake_project "$1")" || return
  shift
  cmake -S "${proj}" -B "${proj}/b" "$@" 2>&1 || rc=$?
  rm -rf "${proj}"
  return "${rc}"
}
