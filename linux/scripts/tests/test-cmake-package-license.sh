#!/usr/bin/env bash
# Covers staged CPack ZIP/DEB and generated WiX RTF; does not run WiX or install an MSI.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/cmake-project-fixture.sh
source "${TESTS_DIR}/cmake-project-fixture.sh"
HUB_CMAKE="$(cmake_fixture_module_root --native)"
_project="$(_cmake_project "
project(p VERSION 1.2.3 LANGUAGES NONE)
set(WIN32 TRUE)
set(ENABLE_WIX_PACKAGING ON CACHE BOOL \"\" FORCE)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include(\"${HUB_CMAKE}/CPackCommon.cmake\")
kataglyphis_cpack_common(VENDOR Example WIX_UPGRADE_GUID 01234567-89AB-CDEF-0123-456789ABCDEF APPIMAGE_DEFAULT OFF)
file(WRITE \"\${CMAKE_BINARY_DIR}/rtf-path.txt\" \"\${CPACK_WIX_LICENSE_RTF}\")
include(CPack)")"
trap 'rm -rf "${_project}"' EXIT
mkdir -p "${_project}/docs/packaging"
printf 'License {terms} \\ path\r\nCopyright \303\251 \360\237\230\200\tend\r\n' > "${_project}/LICENSE"
printf 'readme\n' > "${_project}/README.md"
printf 'welcome\n' > "${_project}/docs/packaging/WelcomeFile.txt"

t_case "a Windows package stages the exact licence and displays the actual text in WiX"
t_assert_rc 0 cmake -S "${_project}" -B "${_project}/build"
t_assert_ok cmake --install "${_project}/build" --prefix "${_project}/installed"
t_assert_ok cmp "${_project}/LICENSE" "${_project}/installed/share/licenses/p/LICENSE"
_rtf="$(cat "${_project}/build/kataglyphis-license.rtf")"
t_assert_contains "${_rtf}" 'License \{terms\} \\ path' "RTF control characters are escaped"
t_assert_contains "${_rtf}" 'Copyright \u233? \u-10179?\u-8704?\tab end' "Unicode and tabs survive RTF conversion"
t_assert_contains "${_rtf}" '\par' "line breaks remain readable"
t_assert_eq "${_project}/build/kataglyphis-license.rtf" "$(cat "${_project}/build/rtf-path.txt")" "WiX uses the generated text"

t_case "CPack includes the exact project licence in its ZIP payload"
t_assert_rc 0 cpack --config "${_project}/build/CPackConfig.cmake" -G ZIP -B "${_project}/packages"
_package="$(find "${_project}/packages" -maxdepth 1 -name '*.zip' -print -quit)"
t_assert_ok test -n "${_package}"
mkdir -p "${_project}/unpacked"
_unpack_zip() { (cd "${_project}/unpacked" && cmake -E tar xf "${_package}"); }
t_assert_ok _unpack_zip
_packaged_license="$(find "${_project}/unpacked" -path '*/share/licenses/p/LICENSE' -print -quit)"
t_assert_ok cmp "${_project}/LICENSE" "${_packaged_license}"

t_case "the Linux DEB also contains the same licence bytes"
_linux="${_project}/linux"
mkdir -p "${_linux}/docs/packaging"
sed '/^set(WIN32 TRUE)$/d' "${_project}/CMakeLists.txt" > "${_linux}/CMakeLists.txt"
cp "${_project}/LICENSE" "${_project}/README.md" "${_linux}/"
cp "${_project}/docs/packaging/WelcomeFile.txt" "${_linux}/docs/packaging/"
t_assert_rc 0 cmake -S "${_linux}" -B "${_linux}/build"
t_assert_rc 0 cpack --config "${_linux}/build/CPackConfig.cmake" -G DEB -B "${_linux}/packages"
_deb="$(find "${_linux}/packages" -maxdepth 1 -name '*.deb' -print -quit)"
t_assert_ok test -n "${_deb}"
t_assert_rc 0 dpkg-deb -x "${_deb}" "${_linux}/unpacked"
_deb_license="$(find "${_linux}/unpacked" -path '*/share/licenses/p/LICENSE' -print -quit)"
t_assert_ok cmp "${_linux}/LICENSE" "${_deb_license}"

t_case "a caller may supply an existing RTF, but a missing one fails"
_custom="${_project}/custom"
mkdir -p "${_custom}/docs/packaging"
sed "s|APPIMAGE_DEFAULT OFF)|APPIMAGE_DEFAULT OFF WIX_LICENSE_RTF \"${_custom}/custom.rtf\")|" \
  "${_project}/CMakeLists.txt" > "${_custom}/CMakeLists.txt"
cp "${_project}/LICENSE" "${_project}/README.md" "${_custom}/"
cp "${_project}/docs/packaging/WelcomeFile.txt" "${_custom}/docs/packaging/"
printf '{\\rtf1 custom terms}' > "${_custom}/custom.rtf"
t_assert_rc 0 cmake -S "${_custom}" -B "${_custom}/build"
t_assert_eq "${_custom}/custom.rtf" "$(cat "${_custom}/build/rtf-path.txt")" "explicit RTF remains supported"
rm "${_custom}/custom.rtf"
t_assert_fails cmake -S "${_custom}" -B "${_custom}/build"

t_case "empty and malformed licences fail at configure time"
printf '  \n' > "${_project}/LICENSE"
t_assert_fails cmake -S "${_project}" -B "${_project}/build"
printf 'bad\377\n' > "${_project}/LICENSE"
t_assert_fails cmake -S "${_project}" -B "${_project}/build"
rm "${_project}/LICENSE"
t_assert_fails cmake -S "${_project}" -B "${_project}/build"

t_summary
