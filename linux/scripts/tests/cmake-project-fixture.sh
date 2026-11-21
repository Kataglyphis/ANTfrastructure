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

# cmake_fixture_hardening <preamble> [global]: Hardening.cmake on one target, probes stubbed; prints LINK= PIC= EXE=.
cmake_fixture_hardening() {
  cmake_fixture_output "$1
include(\"$(cmake_fixture_module_root --native)/Hardening.cmake\")
function(check_cxx_compiler_flag flag var)
  set(\${var} FALSE PARENT_SCOPE)
endfunction()
function(check_pie_supported)
endfunction()
add_library(t INTERFACE)
myproject_enable_hardening(t ${2:-OFF} OFF)
get_target_property(_o t INTERFACE_LINK_OPTIONS)
message(STATUS \"LINK=[\${_o}] PIC=[\${CMAKE_POSITION_INDEPENDENT_CODE}] EXE=[\${CMAKE_EXE_LINKER_FLAGS}]\")" |
    sed -n 's/^-- \(LINK=.*\)$/\1/p'
}
