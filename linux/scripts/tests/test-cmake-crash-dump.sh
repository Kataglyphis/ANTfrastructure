#!/usr/bin/env bash
# kataglyphis_add_crash_dump's wiring; the handler itself runs in windows/scripts/tests/CrashDump.Native.Tests.ps1.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
# shellcheck source=linux/scripts/lib/pe-icon-tools.sh
source "${TESTS_DIR}/../lib/pe-icon-tools.sh"
HUB_CMAKE="$(cmake_fixture_module_root --native)"
SOURCE="${HUB_CMAKE}/crash_dump/kataglyphis_crash_dump.cpp"

# _wiring <platform lines> <target lines>: configures a compiler-less project and prints what the call left behind.
_wiring() {
  cmake_fixture_output "$1
include(\"${HUB_CMAKE}/CrashDump.cmake\")
$2
kataglyphis_add_crash_dump(app)
get_target_property(_s app SOURCES)
get_target_property(_l app LINK_OPTIONS)
get_source_file_property(_o \"${SOURCE}\" TARGET_DIRECTORY app COMPILE_OPTIONS)
get_source_file_property(_k \"${SOURCE}\" TARGET_DIRECTORY app SKIP_LINTING)
get_source_file_property(_u \"${SOURCE}\" TARGET_DIRECTORY app SKIP_UNITY_BUILD_INCLUSION)
message(STATUS \"SOURCES=[\${_s}] LINK=[\${_l}] OPTIONS=[\${_o}] LINT=[\${_k}] UNITY=[\${_u}]\")" |
    sed -n -e 's/^-- \(SOURCES=.*\)$/\1/p' -e 's/^.*\(kataglyphis_add_crash_dump: .*\)$/\1/p'
}

t_case "cmake is here: the cases below configure a real project"
t_assert_ok cmake --version

t_case "an MSVC-like Windows executable compiles the handler and links a Release PDB"
_out="$(_wiring 'set(WIN32 TRUE)
set(MSVC TRUE)' 'add_executable(app)')"
t_assert_contains "${_out}" "SOURCES=[${SOURCE}]" "the handler joins the target's own sources"
t_assert_contains "${_out}" 'LINK=[$<$<CONFIG:Release,MinSizeRel>:/DEBUG;/OPT:REF;/OPT:ICF>]' \
  "a Release link writes the PDB and keeps /OPT:REF and /OPT:ICF, which /DEBUG would switch off"
t_assert_contains "${_out}" "OPTIONS=[/w] LINT=[ON] UNITY=[ON]" "the consumer's warning, lint and unity policies stay off it"

t_case "a non-Windows executable is left alone"
_out="$(_wiring '' 'add_executable(app)')"
t_assert_contains "${_out}" "SOURCES=[_s-NOTFOUND] LINK=[_l-NOTFOUND]" "Linux gets neither the source nor the link flags"
t_assert_eq "0" "$(grep -c -e 'gets no crash reporter' <<< "${_out}")" "Linux is not a Windows toolchain to warn about"

t_case "a Windows toolchain without the MSVC driver warns and adds nothing"
_out="$(_wiring 'set(WIN32 TRUE)' 'add_executable(app)')"
t_assert_contains "${_out}" "'app' gets no crash reporter" "MinGW must not pass silently"
t_assert_contains "${_out}" "SOURCES=[_s-NOTFOUND]" "nothing is compiled that its compiler cannot build"

t_case "a library or a missing target fails the configure"
_out="$(_wiring 'set(WIN32 TRUE)
set(MSVC TRUE)' 'add_library(app INTERFACE)')"
t_assert_contains "${_out}" "'app' is a INTERFACE_LIBRARY" "a library has no process to watch"
_out="$(_wiring '' '')"
t_assert_contains "${_out}" "'app' is not a target" "a typo in the target name must not pass"

for _tool in clang-cl lld-link llvm-rc; do
  t_skip_unless "${_tool}" test -x "$(pe_icon_find_tool "${_tool}")"
done
t_skip_unless "ninja" command -v ninja

# _generated <config>: the build.ninja a clang-cl cross configure writes; nothing is compiled.
_generated() {
  local dir="${_work}/$1"
  cmake -S "${_work}" -B "${dir}" -G Ninja -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64 \
    "-DCMAKE_CXX_COMPILER=$(pe_icon_find_tool clang-cl)" -DCMAKE_CXX_COMPILER_TARGET=x86_64-pc-windows-msvc \
    "-DCMAKE_LINKER=$(pe_icon_find_tool lld-link)" "-DCMAKE_RC_COMPILER=$(pe_icon_find_tool llvm-rc)" \
    -DCMAKE_CXX_COMPILER_WORKS=TRUE \
    "-DCMAKE_BUILD_TYPE=$1" > "${_work}/$1.log" 2>&1 || { cat "${_work}/$1.log" >&2; return 1; }
  cat "${dir}/build.ninja"
}

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
printf 'int main() { return 0; }\n' > "${_work}/main.cpp"
printf 'cmake_minimum_required(VERSION 3.20)\nproject(p LANGUAGES CXX)\ninclude("%s/CrashDump.cmake")\nadd_executable(app main.cpp)\nkataglyphis_add_crash_dump(app)\n' \
  "${HUB_CMAKE}" > "${_work}/CMakeLists.txt"

t_case "a clang-cl Release generates the handler's compile with /w and a /DEBUG link"
_ninja="$(_generated Release)"
t_assert_contains "${_ninja}" "kataglyphis_crash_dump.cpp" "the handler is compiled into the executable"
t_assert_eq "1" "$(grep -A3 -e 'kataglyphis_crash_dump.cpp.obj:' <<< "${_ninja}" | grep -c -e 'FLAGS = .* /w$')" \
  "the handler's compile carries the warning switch"
t_assert_eq "0" "$(grep -A3 -e 'main.cpp.obj:' <<< "${_ninja}" | grep -c -e 'FLAGS = .* /w$')" \
  "the consumer's own sources keep their warnings"
t_assert_contains "${_ninja}" "/DEBUG /OPT:REF /OPT:ICF" "the generator expression expands for Release"

t_case "a clang-cl Debug link gets no extra flags"
t_assert_eq "0" "$(_generated Debug | grep -c -e '/OPT:ICF')" "Debug keeps its incremental link"

t_summary
