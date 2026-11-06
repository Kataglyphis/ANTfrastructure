#!/usr/bin/env bash
# The hub cmake/ follows a Windows cross build's CMAKE_SYSTEM_PROCESSOR. See docs/windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
HUB_CMAKE="$(cmake_fixture_module_root --native)"

# _hardening_link_options <CMAKE_SYSTEM_PROCESSOR> -> the link options an MSVC target gets
_hardening_link_options() {
  cmake_fixture_output "set(MSVC TRUE)
set(CMAKE_SYSTEM_PROCESSOR \"$1\")
include(\"${HUB_CMAKE}/Hardening.cmake\")
add_library(t INTERFACE)
myproject_enable_hardening(t OFF OFF)
get_target_property(_o t INTERFACE_LINK_OPTIONS)
message(STATUS \"LINK=[\${_o}]\")" | sed -n 's/^-- LINK=\[\(.*\)\]$/\1/p'
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
# The arm64 redist ships that one as an x64-machine PE; everything else in it is arm64.
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

t_case "a package that carries the MSVC runtime installs Redist.txt and the end-user notice, one without it neither"
# _notice_files <runtime libs> -> the files the notice installs, sorted
_notice_files() {
  local proj vs
  vs="$(mktemp -d)"
  mkdir -p "${vs}/VC/Redist/MSVC/14.50/x64" "${vs}/Licenses/1033"
  printf 'terms' > "${vs}/Licenses/1033/Redist.txt"
  vs="$(cd "${vs}" && { pwd -W 2>/dev/null || pwd; })"
  proj="$(_cmake_project "include(\"${HUB_CMAKE}/CPackCommon.cmake\")
set(MSVC_REDIST_DIR \"${vs}/VC/Redist/MSVC/14.50\")
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS $1)
kataglyphis_install_msvc_runtime_notice(_n)
message(STATUS \"NOTICE=[\${_n}]\")")"
  cmake -S "${proj}" -B "${proj}/b" >/dev/null 2>&1
  cmake --install "${proj}/b" --prefix "${proj}/out" >/dev/null 2>&1
  (cd "${proj}/out" 2>/dev/null && find . -type f | sort | tr '\n' ' ')
  rm -rf "${proj}" "${vs}"
}
t_assert_eq "./licenses/msvc-runtime/README.txt ./licenses/msvc-runtime/Redist.txt " \
  "$(_notice_files '"C:/crt/msvcp140.dll;C:/crt/vcruntime140.dll"')" "the runtime installs its notice"
t_assert_eq "" "$(_notice_files '"C:/crt/other.dll"')" "no runtime, no notice"

t_summary
