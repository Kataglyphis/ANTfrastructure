#!/usr/bin/env bash
# Stubbed package builders verify control bytes and failure policies, not actual Debian archives or installation.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${1:-${TESTS_DIR}/../lib/app-packaging.sh}"
PY_PACKAGE="${2:-${TESTS_DIR}/../06-packaging/python-app-package.sh}"
t_source_functions "${LIB}" _app_packaging_bundle_deb || exit 1
t_source_functions "${PY_PACKAGE}" package_deb || exit 1
if grep -q '^app_packaging_write_deb_control()' "${LIB}"; then
  t_source_functions "${LIB}" app_packaging_write_deb_control || exit 1
fi
WORK="$(mktemp -d '/tmp/ant-deb fixture.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
t_emit_optional_functions package_deb _app_packaging_bundle_deb app_packaging_write_deb_control > "${WORK}/worker"
cat >> "${WORK}/worker" <<'WORKER'
set -euo pipefail
WORK="$1"; caller="$2"; profile="$3"; builder_status="$4"
WORK_DIR="${WORK}/python work"; OUT_DIR="${WORK}/out"; BUNDLE="${WORK}/payload"
KATAGLYPHIS_PACKAGING_WORKDIR="${WORK}/native work"
APP_ID=org.example.fixture APP_NAME='Demo % App' VERSION=2.4.6 DEB_ARCH=arm64
MAINTAINER='A Person <person@example.invalid>' HOMEPAGE=https://example.invalid
DESCRIPTION='A package description' ICON='' GUI_SCRIPT=runner RUN_TESTS=false
SCRIPTS=(runner second)
matrix_arch=arm64 package_name=demo-pkg version=2.4.6 app_name="${APP_NAME}"
out_dir="${OUT_DIR}" bundle_dir="${BUNDLE}" binary_name=runner icon_file=fixture.png icon_name=demo-pkg app_id="${APP_ID}"
APP_PACKAGING_MAINTAINER="${MAINTAINER}" APP_PACKAGING_DEB_DEPENDS='libc6, custom-dep' APP_PACKAGING_DESCRIPTION="${DESCRIPTION}"
case "${profile}" in
  empty) HOMEPAGE=''; DESCRIPTION=''; APP_PACKAGING_MAINTAINER=''; APP_PACKAGING_DEB_DEPENDS=''; APP_PACKAGING_DESCRIPTION='' ;;
  multiline) DESCRIPTION=$'first line\n second line'; APP_PACKAGING_DESCRIPTION="${DESCRIPTION}" ;;
esac
mkdir -p "${OUT_DIR}" "${BUNDLE}"
: > "${BUNDLE}/payload"
info() { :; }
err() { printf '%s\n' "$*" >&2; exit 1; }
deb_depends() { printf 'libc6, custom-dep'; }
app_packaging_map_arch_to_deb() { printf arm64; }
app_packaging_icon_size() { printf 32x32; }
app_packaging_create_desktop_file() { :; }
_app_packaging_stage_desktop_icon() { :; }
_app_packaging_copy_bundle() { mkdir -p "$2"; cp -a "$1/." "$2/"; }
app_packaging_assert_artifact() { test -s "$1"; }
dpkg-deb() {
  local root="${@: -2:1}" output="${@: -1}"
  cp "${root}/DEBIAN/control" "${WORK}/control"
  printf '%s\n' "$1" > "${WORK}/first-flag"
  [ "${builder_status}" -eq 0 ] || return "${builder_status}"
  printf artifact > "${output}"
}
if [ "${caller}" = python ]; then package_deb; else _app_packaging_bundle_deb; fi
printf 'REACHED\n'
WORKER
output='' status=0
for caller in python native; do
  for profile in explicit empty multiline; do
    for builder_status in 0 23; do
      t_case "${caller}: ${profile} fields and builder status ${builder_status}"
      t_capture_command output status bash "${WORK}/worker" "${WORK}" "${caller}" "${profile}" "${builder_status}"
      expected_status=0
      if [ "${builder_status}" -ne 0 ]; then
        expected_status=23; [ "${caller}" = python ] || expected_status=1
      fi
      t_assert_eq "${expected_status}" "${status}" "${output}"
      maintainer='A Person <person@example.invalid>'; depends='libc6, custom-dep'; description='A package description'
      homepage='https://example.invalid'; package=org.example.fixture; first_flag=--root-owner-group
      if [ "${profile}" = multiline ]; then description=$'first line\n second line'; fi
      if [ "${profile}" = empty ]; then
        homepage=''; description=''
        if [ "${caller}" = native ]; then maintainer='Unknown <dev@localhost>'; depends='libc6, libstdc++6, libgtk-3-0'; description='Demo % App desktop application.'; fi
      fi
      if [ "${caller}" = native ]; then package=demo-pkg; first_flag=--build; fi
      expected="$(printf 'Package: %s\nVersion: 2.4.6\nSection: utils\nPriority: optional\nArchitecture: arm64\nMaintainer: %s\n' "${package}" "${maintainer}")"$'\n'
      if [ "${caller}" = python ]; then expected+="Homepage: ${homepage}"$'\n'; fi
      expected+="$(printf 'Depends: %s\nDescription: Demo %% App\n %s' "${depends}" "${description}")"$'\n'
      printf '%s' "${expected}" > "${WORK}/expected"
      t_assert_ok cmp "${WORK}/expected" "${WORK}/control"
      t_assert_eq "${first_flag}" "$(cat "${WORK}/first-flag")"
      if [ "${builder_status}" -eq 0 ]; then t_assert_contains "${output}" REACHED; else t_assert_eq 1 "$(t_rc grep -q REACHED <<< "${output}")"; fi
    done
  done
done
t_summary
