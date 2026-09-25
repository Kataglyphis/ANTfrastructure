#!/usr/bin/env bash
# The hub cmake/ follows the TARGET a Windows cross build names through
# CMAKE_SYSTEM_PROCESSOR (Get-CMakeCrossArgs): Hardening.cmake drops /CETCOMPAT,
# which an ARM64 link refuses, and CPackCommon.cmake's arm64 runtime list drops the
# ARM64EC vcruntime<ver>_1.dll. CPackCommon.cmake also installs a staged package
# DLL directory. No compiler needed (MSVC faked, script mode, or a NONE project).
# docs/windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# Windows form on Git Bash (pwd -W): a native cmake cannot read /c/... from a file.
HUB_CMAKE="$(cd "${TESTS_DIR}/../../../cmake" && { pwd -W 2>/dev/null || pwd; })"

# _cmake_project <body> -> a fresh directory whose CMakeLists.txt is a compiler-less project
# preamble plus <body>. The caller configures it and removes it.
_cmake_project() {
  local dir
  dir="$(mktemp -d)"
  printf 'cmake_minimum_required(VERSION 3.20)\nproject(p NONE)\n%s\n' "$1" > "${dir}/CMakeLists.txt"
  printf '%s' "${dir}"
}

# _hardening_link_options <CMAKE_SYSTEM_PROCESSOR> -> the link options an MSVC target gets
_hardening_link_options() {
  local proj
  proj="$(_cmake_project "set(MSVC TRUE)
set(CMAKE_SYSTEM_PROCESSOR \"$1\")
include(\"${HUB_CMAKE}/Hardening.cmake\")
add_library(t INTERFACE)
myproject_enable_hardening(t OFF OFF)
get_target_property(_o t INTERFACE_LINK_OPTIONS)
message(STATUS \"LINK=[\${_o}]\")")"
  cmake -S "${proj}" -B "${proj}/b" 2>&1 | sed -n 's/^-- LINK=\[\(.*\)\]$/\1/p'
  rm -rf "${proj}"
}

t_case "cmake is here: the cases below configure a real project"
t_assert_ok cmake --version

t_case "x64 keeps /CETCOMPAT"
t_assert_eq "/NXCOMPAT;/CETCOMPAT" "$(_hardening_link_options AMD64)" \
  "an AMD64 target must link with CET compatibility"

t_case "ARM64 drops it, in every spelling a cross build or a host uses"
for _arch in ARM64 arm64 aarch64; do
  t_assert_eq "/NXCOMPAT" "$(_hardening_link_options "${_arch}")" \
    "a ${_arch} target must not get /CETCOMPAT"
done

t_case "an arm64 package's VC++ runtime leaves out only the ARM64EC vcruntime<ver>_1.dll"
# The arm64 redist folder holds that one as an x64-machine PE (measured in the arm64
# bundle, 2026-09-25); everything else in it is arm64 and ships.
_crt="C:/Redist/arm64/Microsoft.VC145.CRT"
_script="$(mktemp)"
cat > "${_script}" <<EOF
include("${HUB_CMAKE}/CPackCommon.cmake")
kataglyphis_arm64_system_runtime_libs(_out "${_crt}/msvcp140.dll" "${_crt}/vcruntime140_1.dll" "${_crt}/vcruntime140.dll" "${_crt}/concrt140.dll")
message("LIBS=[\${_out}]")
EOF
_libs="$(cmake -P "${_script}" 2>&1 | sed -n 's/^LIBS=\[\(.*\)\]$/\1/p')"
rm -f "${_script}"
t_assert_eq "${_crt}/msvcp140.dll;${_crt}/vcruntime140.dll;${_crt}/concrt140.dll" "${_libs}" \
  "every arm64 runtime file but vcruntime140_1.dll"

t_case "a staged package DLL directory installs its DLLs beside the executables, and nothing else"
# _installed_files <KATAGLYPHIS_PACKAGE_DLL_DIR> -> the files `cmake --install` lays down, sorted
_installed_files() {
  local proj
  proj="$(_cmake_project "include(\"${HUB_CMAKE}/CPackCommon.cmake\")
kataglyphis_install_package_dlls()")"
  cmake -S "${proj}" -B "${proj}/b" "-DKATAGLYPHIS_PACKAGE_DLL_DIR=$1" >/dev/null 2>&1
  cmake --install "${proj}/b" --prefix "${proj}/out" >/dev/null 2>&1
  (cd "${proj}/out" 2>/dev/null && find . -type f | sort | tr '\n' ' ')
  rm -rf "${proj}"
}
_stage="$(mktemp -d)"
: > "${_stage}/gstreamer-1.0-0.dll"
: > "${_stage}/vcruntime140.dll"
: > "${_stage}/closure.log"
_stage_cm="$(cd "${_stage}" && { pwd -W 2>/dev/null || pwd; })"
t_assert_eq "./bin/gstreamer-1.0-0.dll ./bin/vcruntime140.dll " "$(_installed_files "${_stage_cm}")" \
  "the staged DLLs land in bin, the log beside them does not"
t_assert_eq "" "$(_installed_files "")" "an empty directory name installs nothing"
rm -rf "${_stage}"

t_summary
