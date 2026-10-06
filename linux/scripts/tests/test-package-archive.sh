#!/usr/bin/env bash
# package_archive.sh's four formats and the app-packaging.sh knobs it sets; see docs/shared-script-libraries.md#06-packagingpackage_archivesh--one-binary-four-formats
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# _png <path> <w> <h>: the 24 header bytes app_packaging_icon_size reads; nothing else looks inside.
_png() {
  python3 -c 'import struct, sys
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", int(sys.argv[2]), int(sys.argv[3])) + b"\x08\x06\x00\x00\x00")' "$1" "$2" "$3"
}

# A project: a release binary, its desktop entry and icon.
_project="${_work}/project"
mkdir -p "${_project}/target/release" "${_project}/packaging"
printf '#!/bin/sh\necho "oxidant ran: $*"\n' > "${_project}/target/release/kataglyphis_cli"
chmod +x "${_project}/target/release/kataglyphis_cli"
printf '[Desktop Entry]\nType=Application\nName=OxidANT\nExec=old-exec\nTerminal=true\n' > "${_project}/packaging/app.desktop"
_png "${_project}/packaging/icon.png" 2 3

# _tree <app-packaging.sh source>: package_archive.sh beside its siblings; the preflight never installs here.
_tree() {
  local t; t="$(mktemp -d "${_work}/tree.XXXXXX")"
  mkdir -p "${t}/02-toolchain"
  cp -r "${SCRIPTS}/01-core" "${SCRIPTS}/06-packaging" "${t}/"
  mkdir -p "${t}/lib"
  cp "${SCRIPTS}/lib/"*.sh "${t}/lib/"
  printf '#!/bin/sh\nexit 0\n' > "${t}/02-toolchain/packaging-deps.sh"
  [ "$1" = real ] || cp "$1" "${t}/lib/app-packaging.sh"
  printf '%s' "${t}"
}

# _archive <tree> [args...]: rc|output of one run against the project.
_archive() {
  local tree="$1" out rc; shift
  out="$(cd "${_project}" && KATAGLYPHIS_PACKAGING_WORKDIR="${_work}/pkgwork" \
    bash "${tree}/06-packaging/package_archive.sh" --binary oxidant --binary-file kataglyphis_cli \
      --version v2.3.4 --arch x64 --desktop-file packaging/app.desktop --icon-file packaging/icon.png \
      --archive-dir "${_work}/dist" --archive-name "${_work}/dist/oxidant.tar.gz" --no-github-output "$@" 2>&1)"; rc=$?
  printf '%s|%s' "${rc}" "${out}"
}

# A stub library: each packager records its arguments and the knobs it was handed.
cat > "${_work}/stub-app-packaging.sh" <<'STUB'
_record() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "${STUB_LOG}"
  {
    printf 'bundle=%s\n' "${APP_PACKAGING_BUNDLE_DIR}"; printf 'version=%s\n' "${APP_PACKAGING_VERSION}"
    printf 'desktop=%s\n' "${APP_PACKAGING_DESKTOP_FILE}"; printf 'icon=%s\n' "${APP_PACKAGING_ICON_FILE}"
    printf 'out=%s\n' "${APP_PACKAGING_OUT_DIR}"; printf 'depends=%s\n' "${APP_PACKAGING_DEB_DEPENDS}"
    printf 'app_id=%s\n' "${APP_PACKAGING_APP_ID:-}"
  } > "${STUB_LOG}.env"
  [ -x "${APP_PACKAGING_BUNDLE_DIR}/oxidant" ] && printf 'staged binary runs: %s\n' "$("${APP_PACKAGING_BUNDLE_DIR}/oxidant" x)" >> "${STUB_LOG}"
}
app_packaging_package_linux_bundle_deb() { _record deb "$@"; }
app_packaging_package_linux_bundle_appimage() { _record appimage "$@"; }
app_packaging_package_linux_bundle_flatpak() { _record flatpak "$@"; }
STUB
_stub_tree="$(_tree "${_work}/stub-app-packaging.sh")"
export STUB_LOG="${_work}/stub.log"

t_case "an unknown package type stops the run before anything is built"
out="$(_archive "${_stub_tree}" --package-types tar,zip)"
t_assert_eq "1" "${out%%|*}"
t_assert_contains "${out}" "unknown package type 'zip' (tar, deb, appimage, flatpak)"
t_assert_fails test -e "${_work}/dist/oxidant.tar.gz"

t_case "a flag that was accepted and never read is an error now, not a silent no-op"
for flag in --flatpak-manifest --appdata-file; do
  out="$(_archive "${_stub_tree}" --package-types tar "${flag}" x.json)"
  t_assert_eq "1" "${out%%|*}" "${flag}"
  t_assert_contains "${out}" "${flag} was removed: the flatpak manifest is generated from the staged bundle"
done

t_case "deb, appimage and flatpak need --arch; the tar does not"
out="$(cd "${_project}" && bash "${_stub_tree}/06-packaging/package_archive.sh" --binary oxidant --binary-file kataglyphis_cli \
  --desktop-file packaging/app.desktop --icon-file packaging/icon.png --package-types deb --no-github-output 2>&1)"
t_assert_contains "${out}" "--arch is required for deb, appimage and flatpak"

t_case "every format but the tar gets the staged binary and the knobs from the project's own files"
: > "${STUB_LOG}"
out="$(_archive "${_stub_tree}" --package-types 'tar, DEB,appimage flatpak')"
t_assert_eq "0" "${out%%|*}" "${out#*|}"
t_assert_ok test -s "${_work}/dist/oxidant.tar.gz"
t_assert_eq "oxidant" "$(tar -tzf "${_work}/dist/oxidant.tar.gz")" "the tar holds the binary under its package name"
t_assert_contains "$(cat "${STUB_LOG}")" "deb x64 oxidant"
t_assert_contains "$(cat "${STUB_LOG}")" "appimage x64 oxidant"
t_assert_contains "$(cat "${STUB_LOG}")" "flatpak x64 oxidant"
t_assert_contains "$(cat "${STUB_LOG}")" "staged binary runs: oxidant ran: x"
_env="$(cat "${STUB_LOG}.env")"
t_assert_contains "${_env}" "version=2.3.4" "a tag's leading v is not part of a deb version"
t_assert_contains "${_env}" "desktop=${_project}/packaging/app.desktop" "absolute: the packagers stage elsewhere"
t_assert_contains "${_env}" "icon=${_project}/packaging/icon.png"
t_assert_contains "${_env}" "out=${_work}/dist"
t_assert_contains "${_env}" "depends=libc6, libgcc-s1" "a Rust binary needs no GTK"

t_case "a caller's deb Depends and app id win over the defaults"
out="$(APP_PACKAGING_DEB_DEPENDS='libc6, libgstreamer1.0-0' _archive "${_stub_tree}" --package-types deb --app-id io.example.App)"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "$(cat "${STUB_LOG}.env")" "depends=libc6, libgstreamer1.0-0"
t_assert_contains "$(cat "${STUB_LOG}.env")" "app_id=io.example.App"

t_case "the real library packs a deb from the staged binary, with the project's desktop entry and icon"
t_needs "dpkg-deb" command -v dpkg-deb
_real_tree="$(_tree real)"
out="$(_archive "${_real_tree}" --package-types tar,deb)"
t_assert_eq "0" "${out%%|*}" "${out#*|}"
_deb="${_work}/dist/oxidant_2.3.4_amd64.deb"
_list="$(dpkg-deb -c "${_deb}" 2>/dev/null | awk '{print $NF}')"
t_assert_contains "${_list}" "./opt/oxidant/oxidant"
t_assert_contains "${_list}" "./usr/bin/oxidant"
t_assert_contains "${_list}" "./usr/share/icons/hicolor/2x3/apps/oxidant.png" "the icon goes where its real size says"
t_assert_contains "$(dpkg-deb -f "${_deb}" Depends 2>/dev/null)" "libc6, libgcc-s1"
mkdir -p "${_work}/debx" && dpkg-deb -x "${_deb}" "${_work}/debx" 2>/dev/null
_desktop="$(cat "${_work}/debx/usr/share/applications/oxidant.desktop" 2>/dev/null)"
t_assert_contains "${_desktop}" "Name=OxidANT" "the project's own entry, not a generated one"
t_assert_contains "${_desktop}" "Exec=oxidant"
t_assert_contains "${_desktop}" "Icon=oxidant" "inserted where the project's entry had none"
t_assert_eq "0" "$(printf '%s\n' "${_desktop}" | grep -c 'old-exec')" "the project's Exec is replaced, not doubled"

t_case "app_packaging_icon_size reads the PNG header and falls back to 512x512"
_size_src="$(t_fn_src "${SCRIPTS}/lib/app-packaging.sh" app_packaging_icon_size)" || exit 1
_size() { bash -c "${_size_src}"$'\napp_packaging_icon_size "$1"' _ "$1"; }
_png "${_work}/wide.png" 300 20
t_assert_eq "300x20" "$(_size "${_work}/wide.png")"
printf 'not a png' > "${_work}/text.png"
t_assert_eq "512x512" "$(_size "${_work}/text.png")" "a placeholder that only looks like an icon"
t_assert_eq "512x512" "$(_size "${_work}/missing.png")"

t_case "a Flutter bundle keeps its defaults when no knob is set"
_dir_src="$(t_fn_src "${SCRIPTS}/lib/app-packaging.sh" app_packaging_detect_bundle_dir)" || exit 1
t_assert_eq "build/linux/arm64/release/bundle" "$(bash -c "${_dir_src}"$'\napp_packaging_detect_bundle_dir arm64')"
t_assert_eq "/x/bundle" "$(APP_PACKAGING_BUNDLE_DIR=/x/bundle bash -c "${_dir_src}"$'\napp_packaging_detect_bundle_dir arm64')"

t_summary
