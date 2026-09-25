#!/usr/bin/env bash
# The hub cmake/ follows the TARGET a Windows cross build names through
# CMAKE_SYSTEM_PROCESSOR (Get-CMakeCrossArgs): Hardening.cmake drops /CETCOMPAT,
# which an ARM64 link refuses, and CPackCommon.cmake's arm64 runtime list drops the
# ARM64EC vcruntime<ver>_1.dll. No compiler needed (MSVC faked, or script mode).
# docs/windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# Windows form on Git Bash (pwd -W): a native cmake cannot read /c/... from a file.
HUB_CMAKE="$(cd "${TESTS_DIR}/../../../cmake" && { pwd -W 2>/dev/null || pwd; })"

# _hardening_link_options <CMAKE_SYSTEM_PROCESSOR> -> the link options an MSVC target gets
_hardening_link_options() {
  local dir
  dir="$(mktemp -d)"
  cat > "${dir}/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.20)
project(p NONE)
set(MSVC TRUE)
set(CMAKE_SYSTEM_PROCESSOR "$1")
include("${HUB_CMAKE}/Hardening.cmake")
add_library(t INTERFACE)
myproject_enable_hardening(t OFF OFF)
get_target_property(_o t INTERFACE_LINK_OPTIONS)
message(STATUS "LINK=[\${_o}]")
EOF
  cmake -S "${dir}" -B "${dir}/b" 2>&1 | sed -n 's/^-- LINK=\[\(.*\)\]$/\1/p'
  rm -rf "${dir}"
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

t_summary
