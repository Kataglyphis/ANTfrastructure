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
