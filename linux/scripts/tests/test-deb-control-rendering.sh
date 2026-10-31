#!/usr/bin/env bash
# Stubbed package builders verify control bytes and failure policies, not actual Debian archives or installation.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${1:-${TESTS_DIR}/../lib/app-packaging.sh}"
PY_PACKAGE="${2:-${TESTS_DIR}/../06-packaging/python-app-package.sh}"
t_skip_unless "real POSIX symlinks for the Debian package fixture" t_posix_symlinks
t_source_functions "${LIB}" _app_packaging_bundle_deb || exit 1
t_source_functions "${PY_PACKAGE}" package_deb || exit 1
t_source_functions "${PY_PACKAGE}" deb_depends || exit 1
if grep -q '^app_packaging_write_deb_control()' "${LIB}"; then
  t_source_functions "${LIB}" app_packaging_write_deb_control || exit 1
fi
WORK="$(mktemp -d '/tmp/ant-deb fixture.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
t_emit_optional_functions package_deb _app_packaging_bundle_deb app_packaging_write_deb_control > "${WORK}/worker"
cat >> "${WORK}/worker" <<'WORKER'
set -euo pipefail
WORK="$1"; caller="$2"; profile="$3"; builder_status="$4"; license_status="${5:-0}"
gpu_status="${6:-0}"
WORK_DIR="${WORK}/python work"; OUT_DIR="${WORK}/out"; BUNDLE="${WORK}/payload"
KATAGLYPHIS_PACKAGING_WORKDIR="${WORK}/native work"
APP_ID=org.example.fixture APP_NAME='Demo % App' VERSION=2.4.6 DEB_ARCH=arm64
ARTIFACT_ID="${APP_ID}"
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
rm -f "${WORK}/license-check" "${WORK}/gpu-check"
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
verify_gpu_package() {
  printf '%s\n%s\n' "$1" "$2" > "${WORK}/gpu-check"
  return "${gpu_status}"
}
verify_python_app_package_license() {
  printf '%s\n%s\n' "$1" "$2" > "${WORK}/license-check"
  return "${license_status}"
}
dpkg-deb() {
  local root="${@: -2:1}" output="${@: -1}"
  cp "${root}/DEBIAN/control" "${WORK}/control"
  printf '%s\n' "$@" > "${WORK}/builder-args"
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
      homepage='https://example.invalid'; package=org.example.fixture
      if [ "${profile}" = multiline ]; then description=$'first line\n second line'; fi
      if [ "${profile}" = empty ]; then
        homepage=''; description=''
        if [ "${caller}" = native ]; then maintainer='Unknown <dev@localhost>'; depends='libc6, libstdc++6, libgtk-3-0'; description='Demo % App desktop application.'; fi
      fi
      if [ "${caller}" = native ]; then package=demo-pkg; fi
      expected="$(printf 'Package: %s\nVersion: 2.4.6\nSection: utils\nPriority: optional\nArchitecture: arm64\nMaintainer: %s\n' "${package}" "${maintainer}")"$'\n'
      if [ "${caller}" = python ]; then expected+="Homepage: ${homepage}"$'\n'; fi
      expected+="$(printf 'Depends: %s\nDescription: Demo %% App\n %s' "${depends}" "${description}")"$'\n'
      printf '%s' "${expected}" > "${WORK}/expected"
      t_assert_ok cmp "${WORK}/expected" "${WORK}/control"
      t_assert_eq $'--root-owner-group\n-Zgzip\n--build' "$(head -n 3 "${WORK}/builder-args")"
      if [ "${caller}" = python ] && [ "${builder_status}" -eq 0 ]; then
        t_assert_eq "$(printf '%s\n%s' "${WORK}/out/org.example.fixture_2.4.6_arm64.deb" 'opt/org.example.fixture')" "$(cat "${WORK}/gpu-check")"
        t_assert_ok test -f "${WORK}/license-check"
        t_assert_eq "$(printf '%s\n%s' "${WORK}/out/org.example.fixture_2.4.6_arm64.deb" 'opt/org.example.fixture/LICENSE')" "$(cat "${WORK}/license-check")"
      else
        t_assert_fails test -e "${WORK}/gpu-check"
        t_assert_fails test -e "${WORK}/license-check"
      fi
      if [ "${builder_status}" -eq 0 ]; then t_assert_contains "${output}" REACHED; else t_assert_eq 1 "$(t_rc grep -q REACHED <<< "${output}")"; fi
    done
  done
done

t_case 'a failed Python license check propagates its status and stops the worker'
t_capture_command output status bash "${WORK}/worker" "${WORK}" python explicit 0 17
t_assert_eq 17 "${status}" "${output}"
t_assert_eq 1 "$(t_rc grep -q REACHED <<< "${output}")"

t_case 'a failed Python GPU payload check stops before the license check'
t_capture_command output status bash "${WORK}/worker" "${WORK}" python explicit 0 0 19
t_assert_eq 19 "${status}" "${output}"
t_assert_fails test -e "${WORK}/license-check"
t_assert_eq 1 "$(t_rc grep -q REACHED <<< "${output}")"

t_case "a failed readelf command cannot produce a partial package dependency list"
_DEP_BUNDLE="${WORK}/dependency-bundle"
_DEP_TOOLS="${WORK}/dependency-tools"
mkdir -p "${_DEP_BUNDLE}/lib" "${_DEP_TOOLS}"
printf '{"glibc":true}\n' > "${_DEP_BUNDLE}/bundle.json"
cp /bin/true "${_DEP_BUNDLE}/lib/module.so"
SCRIPT_DIR="$(cd "$(dirname "${PY_PACKAGE}")" && pwd)"
export SCRIPT_DIR
REAL_READELF="$(command -v readelf)"
export REAL_READELF
cat > "${_DEP_TOOLS}/readelf" <<'TOOL'
#!/usr/bin/env bash
[ "${READELF_FAIL:-0}" = 0 ] || exit 9
exec "${REAL_READELF}" "$@"
TOOL
chmod +x "${_DEP_TOOLS}/readelf"
_DEP_OUT="$(BUNDLE="${_DEP_BUNDLE}" PATH="${_DEP_TOOLS}:${PATH}" deb_depends)"
_DEP_RC=$?
t_assert_eq 0 "${_DEP_RC}" "${_DEP_OUT}"
t_assert_contains "${_DEP_OUT}" 'libc6'
_DEP_OUT="$(BUNDLE="${_DEP_BUNDLE}" PATH="${_DEP_TOOLS}:${PATH}" READELF_FAIL=1 deb_depends 2>&1)"
_DEP_RC=$?
t_assert_eq 1 "${_DEP_RC}" "readelf failure must abort dependency discovery"
t_assert_contains "${_DEP_OUT}" 'cannot derive Debian dependencies:'
t_assert_contains "${_DEP_OUT}" 'returned non-zero exit status'

t_summary
