#!/usr/bin/env bash
# Cache.cmake hands sccache to CMake through the guarded launcher off Windows, so a dead server compiles directly.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
HUB_CMAKE="$(cd "${TESTS_DIR}/../../../cmake" && pwd)"
GUARDED="$(cd "${TESTS_DIR}/../01-core" && pwd)/sccache-launcher.sh"

t_skip_unless "a Linux cmake (WIN32 keeps the bare sccache)" sh -c '[ "$(uname -s)" = Linux ] && command -v cmake'

_w="$(mktemp -d)"
trap 'rm -rf "${_w}"' EXIT
mkdir -p "${_w}/bin"
for _t in sccache ccache; do
  printf '#!/bin/sh\nexec "$@"\n' > "${_w}/bin/${_t}"
  chmod +x "${_w}/bin/${_t}"
done

# _launcher <COMPILER_CACHE>: the CXX launcher a compiler-less project ends up with.
_launcher() {
  local proj
  proj="$(mktemp -d "${_w}/p.XXXXXX")"
  printf 'cmake_minimum_required(VERSION 3.20)\nproject(p NONE)\ninclude("%s/Cache.cmake")\nmyproject_enable_cache()\nmessage(STATUS "LAUNCHER=[${CMAKE_CXX_COMPILER_LAUNCHER}]")\n' \
    "${HUB_CMAKE}" > "${proj}/CMakeLists.txt"
  PATH="${_w}/bin:${PATH}" cmake -S "${proj}" -B "${proj}/b" -DCOMPILER_CACHE="$1" 2>&1 | sed -n 's/^-- LAUNCHER=\[\(.*\)\]$/\1/p'
}

t_case "sccache goes through the hub's guarded launcher"
t_assert_eq "${GUARDED}" "$(_launcher sccache)"

t_case "the guarded launcher is executable, since CMake runs it directly"
t_assert_ok test -x "${GUARDED}"

t_case "ccache keeps its own binary"
t_assert_eq "${_w}/bin/ccache" "$(_launcher ccache)"

t_case "no cache, no launcher"
t_assert_eq "" "$(_launcher "")"

t_summary
