#!/usr/bin/env bash
# A real CMake configure of a subproject that FORCEs its launchers, as pthreadpool and XNNPACK do; not covered: a real compile through sccache.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
LIB="${TESTS_DIR}/../01-core/cmake-cache-linker.sh"

t_skip_unless "cmake" command -v cmake

_w="$(mktemp -d)"
trap 'rm -rf "${_w}"' EXIT
mkdir -p "${_w}/bin"
printf '#!/bin/sh\nexec "$@"\n' > "${_w}/bin/ccache"
chmod +x "${_w}/bin/ccache"
LAUNCHER=/opt/scripts/core/sccache-launcher.sh

# pthreadpool's CMakeLists.txt, lines 15-20 at the commit ONNX Runtime 1.31 pins.
_forcing_project() {
  local proj
  proj="$(_cmake_project 'add_subdirectory(sub)' "${_w}/p.XXXXXX")"
  mkdir -p "${proj}/sub"
  cat > "${proj}/sub/CMakeLists.txt" <<'EOF'
project(sub NONE)
FIND_PROGRAM(CCACHE_BINARY "ccache")
IF(CCACHE_BINARY)
  SET(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_BINARY}" CACHE STRING "CXX compiler launcher" FORCE)
  SET(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_BINARY}" CACHE STRING "C compiler launcher" FORCE)
ENDIF()
EOF
  printf '%s' "${proj}"
}

# _configure <project> <cmake args...>: the build dir after a configure with the stub ccache on PATH.
_configure() {
  local proj="$1"
  shift
  PATH="${_w}/bin:${PATH}" cmake -S "${proj}" -B "${proj}/b" "$@" >/dev/null 2>&1 || return 1
  printf '%s' "${proj}/b"
}

_gate() { bash -c 'source "$1"; cmake_assert_compiler_cache_pin "$2" "$3"' _ "${LIB}" "$@"; }

t_case "the pin keeps the launcher through a subproject that FORCEs ccache"
pin="$(bash -c 'source "$1"; a=(); append_cmake_compiler_cache_pin a "$2"; printf "%s\n" "${a[@]}"' _ "${LIB}" "${LAUNCHER}")"
t_assert_eq "-DCMAKE_C_COMPILER_LAUNCHER=${LAUNCHER}
-DCMAKE_CXX_COMPILER_LAUNCHER=${LAUNCHER}
-DCCACHE_BINARY=${LAUNCHER}" "${pin}"
mapfile -t pin_args <<<"${pin}"
b="$(_configure "$(_forcing_project)" "${pin_args[@]}")"
t_assert_rc 0 _gate "${b}" "${LAUNCHER}"

t_case "the launchers alone lose to the FORCE, and the gate says so"
b="$(_configure "$(_forcing_project)" "-DCMAKE_C_COMPILER_LAUNCHER=${LAUNCHER}" "-DCMAKE_CXX_COMPILER_LAUNCHER=${LAUNCHER}")"
t_assert_rc 1 _gate "${b}" "${LAUNCHER}"
t_assert_contains "$(_gate "${b}" "${LAUNCHER}" 2>&1)" "CMAKE_CXX_COMPILER_LAUNCHER is ${_w}/bin/ccache, not ${LAUNCHER}"

t_case "the environment alone loses too"
proj="$(_forcing_project)"
b="$(CMAKE_C_COMPILER_LAUNCHER="${LAUNCHER}" CMAKE_CXX_COMPILER_LAUNCHER="${LAUNCHER}" _configure "${proj}")"
t_assert_rc 1 _gate "${b}" "${LAUNCHER}"

t_case "the bare form is what build.py's --cmake_extra_defines takes"
t_assert_eq "CCACHE_BINARY=x" "$(bash -c 'source "$1"; a=(); append_cmake_compiler_cache_pin a x ""; printf "%s\n" "${a[@]}"' _ "${LIB}" | tail -n 1)"

t_case "no launcher pins nothing and gates nothing; a missing cache fails"
t_assert_eq "0" "$(bash -c 'source "$1"; a=(); append_cmake_compiler_cache_pin a ""; printf "%s" "${#a[@]}"' _ "${LIB}")"
t_assert_rc 0 _gate "${_w}/nowhere" ""
t_assert_rc 1 _gate "${_w}/nowhere" "${LAUNCHER}"

t_case "append_cmake_cache_linker_args pins a launcher the environment already set"
args="$(PATH="${_w}/bin:${PATH}" CMAKE_C_COMPILER_LAUNCHER="${LAUNCHER}" CMAKE_CXX_COMPILER_LAUNCHER="${LAUNCHER}" USE_LLD=false \
  bash -c 'source "$1"; a=(); append_cmake_cache_linker_args a; printf "%s\n" "${a[@]}"; printf "PIN=%s\n" "${CMAKE_COMPILER_CACHE_PIN}"' _ "${LIB}")"
t_assert_contains "${args}" "-DCCACHE_BINARY=${LAUNCHER}"
t_assert_contains "${args}" "PIN=${LAUNCHER}"

t_case "ONNX Runtime's native build stops when a subproject replaced its launcher"
ORT_LIB="${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh"
_ort_run() {
  local dir="$1" recorded="$2"
  mkdir -p "${dir}/Release"
  printf 'CMAKE_C_COMPILER_LAUNCHER:STRING=%s\nCMAKE_CXX_COMPILER_LAUNCHER:STRING=%s\n' "${recorded}" "${recorded}" > "${dir}/Release/CMakeCache.txt"
  bash -c 'source "$1"; cross_build_is_active() { return 1; }; _ort_launcher="$3"
    eval "$4"; run_onnx_native_build "$2" Release "ORT failed" true && printf "PASSED\n"' \
    _ "${LIB}" "${dir}" "${LAUNCHER}" "$(t_fn_src "${ORT_LIB}" run_onnx_native_build)" 2>&1
}
t_assert_contains "$(_ort_run "${_w}/ort-ok" "${LAUNCHER}")" "PASSED"
_rc=0; _out="$(_ort_run "${_w}/ort-forced" /usr/bin/ccache)" || _rc=$?
t_assert_eq "1" "${_rc}" "${_out}"
t_assert_contains "${_out}" "a subproject replaced the compiler cache"

t_case "LiteRT gates both of its configures on the pin"
LITERT="${TESTS_DIR}/../03-media/build/litert/build-litert.sh"
t_assert_contains "$(cat "${LITERT}")" 'cmake --preset "${preset}" "${cmake_args[@]}"
    cmake_assert_compiler_cache_pin "${LITERT_SRC}/litert/$(litert_build_subdir)" "${CMAKE_COMPILER_CACHE_PIN:-}"'
t_assert_contains "$(cat "${LITERT}")" 'cmake_assert_compiler_cache_pin "${c_api_build}" "${CMAKE_COMPILER_CACHE_PIN:-}"'

t_summary
