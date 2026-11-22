#!/usr/bin/env bash
# Hardening.cmake's Linux branch: PIE and -z relro -z now for GCC and Clang there, not on macOS (CON294). Compiler-less fixtures.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
# _hardening <CMAKE_SYSTEM_NAME> <compiler id> [global] -> "LINK=[...] PIC=[...] EXE=[...]" for one target.
_hardening() { cmake_fixture_hardening "set(CMAKE_SYSTEM_NAME \"$1\")
set(CMAKE_CXX_COMPILER_ID \"$2\")" "${3:-OFF}"; }

t_case "cmake is here: the cases below configure a real project"
t_assert_ok cmake --version

t_case "GCC and Clang on Linux link PIE with -z relro and -z now"
for _id in GNU Clang; do
  t_assert_eq "LINK=[-Wl,-z,relro;-Wl,-z,now] PIC=[ON] EXE=[]" "$(_hardening Linux "${_id}")" \
    "a ${_id} target on Linux must link PIE with RELRO and BIND_NOW"
done

t_case "macOS gets neither: ld64 knows no -z relro"
t_assert_eq "LINK=[_o-NOTFOUND] PIC=[] EXE=[]" "$(_hardening Darwin AppleClang)" "an Apple target links as before"

t_case "the global mode joins its flags with spaces: a semicolon would end the linker's command line"
t_assert_eq "LINK=[_o-NOTFOUND] PIC=[ON] EXE=[ -Wl,-z,relro -Wl,-z,now]" "$(_hardening Linux GNU ON)" \
  "the global flags must be one space-separated string"

t_summary
