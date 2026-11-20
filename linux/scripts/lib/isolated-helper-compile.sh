#!/usr/bin/env bash
# One fixture compiler boundary retains the raw compiler verdict and cache statistics for both test drivers.
# shellcheck source=log-bootstrap.sh
source "${BASH_SOURCE[0]%/*}/log-bootstrap.sh" || return
_ih_c_object() {
  local _ih_root="$1" _ih_output="$2" _ih_stem="$3" _ih_source="$4" _ih_object="$5"
  bash "${_ih_root}/linux/scripts/capture-sccache-command.sh" "${_ih_output}/${_ih_stem}-cache" -- \
    sccache cc -std=c11 -O3 -Wall -Wextra -Werror -fPIC -c \
    "${_ih_root}/${_ih_source}" -o "${_ih_output}/${_ih_object}.o"
}

compile_isolated_helper_object() {
  _ih_c_object "$1" "$2" native shared/native/isolated_helper.c isolated-helper
}

compile_isolated_clock_fixture() {
  _ih_c_object "$1" "$2" clock-fixture shared/native/tests/isolated_helper_clock_test.c clock-fixture || return
  cc "$2/clock-fixture.o" "$2/isolated-helper.o" -pthread \
    -Wl,--wrap=clock_gettime,--wrap=waitpid -o "$2/clock-fixture"
}

_ih_asan_object() {
  local _ih_root="$1" _ih_output="$2" _ih_stem="$3" _ih_source="$4"
  bash "${_ih_root}/linux/scripts/capture-sccache-command.sh" "${_ih_output}/${_ih_stem}-cache" -- \
    sccache c++ -std=c++20 -Wall -Wextra -Werror -g -fno-omit-frame-pointer -fsanitize=address -fPIC \
    -c "${_ih_root}/${_ih_source}" -o "${_ih_output}/${_ih_stem}.o"
}

compile_isolated_hip_fixtures() {
  local _ih_root="$1" _ih_output="$2"
  c++ --version > "${_ih_output}/cxx-version.txt"
  _ih_asan_object "${_ih_root}" "${_ih_output}" hip-worker shared/native/hip_probe_main.cpp
  _ih_asan_object "${_ih_root}" "${_ih_output}" hip-runtime shared/native/tests/hip_runtime_fixture.cpp
  c++ -fsanitize=address "${_ih_output}/hip-worker.o" -ldl -o "${_ih_output}/hip-worker"
  c++ -shared -fsanitize=address "${_ih_output}/hip-runtime.o" -o "${_ih_output}/libhip-fixture.so"
}

# A matching exit code cannot substitute for the actual sanitizer teardown report.
require_isolated_hip_report() {
  local _ih_report="$1"
  [[ "$(grep -Fxc -e 'SUMMARY: AddressSanitizer: 17 byte(s) leaked in 1 allocation(s).' "${_ih_report}")" == 1 ]] || {
    printf 'Expected exactly one real 17-byte sanitizer teardown report\n' >&2
    return 1
  }
  return 0
}
