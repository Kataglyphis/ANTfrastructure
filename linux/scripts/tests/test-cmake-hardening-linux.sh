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

# _linux_gnu <cmake tail>: what cmake says for a GNU target on Linux with Hardening.cmake loaded.
_linux_gnu() { cmake_fixture_output "set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_CXX_COMPILER_ID GNU)
$(cmake_fixture_hardening_module)
$1"; }
# _scoped <add_library args>: a function hardens that one target (CON297).
_scoped() { _linux_gnu "add_library($1)
function(local_hardening target)
  myproject_enable_hardening(\${target} OFF OFF)
endfunction()
local_hardening(t)
get_target_property(_p t POSITION_INDEPENDENT_CODE)
message(STATUS \"PROP=[\${_p}] PIC=[\${CMAKE_POSITION_INDEPENDENT_CODE}]\")"; }

t_case "a real target hardened from a function is PIE itself, as the variable stays in that function"
_out="$(_scoped 't STATIC x.c')"
t_assert_contains "${_out}" "PROP=[ON] PIC=[]" "the target must carry POSITION_INDEPENDENT_CODE whatever the scope"
t_assert_eq 0 "$(grep -c 'reaches no target' <<< "${_out}")" "a real target needs no warning"

t_case "an INTERFACE target hardened from a function warns: its PIE reaches no target"
t_assert_contains "$(_scoped 't INTERFACE')" "its PIE stays in that" "the lost PIE must be named, not silent"

t_case "at the project's scope an INTERFACE target sets the variable and warns of nothing"
_out="$(_linux_gnu "add_library(t INTERFACE)
myproject_enable_hardening(t OFF OFF)")"
t_assert_eq 0 "$(grep -c 'reaches no target' <<< "${_out}")" "the project scope keeps the variable"

t_summary
