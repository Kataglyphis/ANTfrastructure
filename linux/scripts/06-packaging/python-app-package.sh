#!/usr/bin/env bash
# PYTHON_APP_GPU_PACKAGE_API=1

# PYTHON_APP_GPU_FINISHED_BINARY_API=1

# Wraps a python-app-bundle.sh folder as tar.gz, deb and AppImage, and starts each as a user would; see docs/python-app-bundles.md § Packages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/app-packaging.sh
source "${SCRIPT_DIR}/../lib/app-packaging.sh"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

source "${SCRIPT_DIR}/python-app-cli.sh"

REPO_ROOT="${PWD}"
CONFIG="packaging/app.json"
BUNDLE=""
OUT_DIR=""
FORMATS="tar,deb,appimage"
RUN_TESTS=true
WORK_DIR="${KATAGLYPHIS_PACKAGING_WORKDIR:-/tmp/packaging-work}/python-app"

usage() {
  printf 'usage: %s --bundle DIR [--repo-root DIR] [--config FILE] [--out-dir DIR] [--formats tar,deb,appimage] [--no-test] [--work-dir DIR]\n' "$0"
}

parse_python_app_args package "$@"

cd "${REPO_ROOT}"
[ -n "${BUNDLE}" ] || { usage >&2; exit 2; }
BUNDLE="$(realpath "${BUNDLE}")"
[ -f "${BUNDLE}/bundle.json" ] || err "no bundle.json in ${BUNDLE}: build it with python-app-bundle.sh first"
required_provider="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("required_provider", ""))' "${BUNDLE}/bundle.json")"
if [ -n "${required_provider}" ] && [ "${RUN_TESTS}" != true ]; then err "a GPU package must run its ${required_provider} self-test"; fi
OUT_DIR="$(realpath -m "${OUT_DIR:-$(dirname "${BUNDLE}")}")"
mkdir -p "${OUT_DIR}" "${WORK_DIR}"
SELFTEST="${SCRIPT_DIR}/python-app-selftest.py"

# One JSON read per fact; arrays come back space-separated, which console-script names allow.
app() {
  python3 -c 'import json, sys; v = json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(" ".join(v) if isinstance(v, list) else v)' "${CONFIG}" "$1"
}
APP_ID="$(app id)"
APP_NAME="$(app name)"
ARTIFACT_ID="${APP_ID}"
case "${required_provider}" in
  CUDAExecutionProvider) ARTIFACT_ID="${APP_ID}-gpu-nvidia" ;;
  MIGraphXExecutionProvider) ARTIFACT_ID="${APP_ID}-gpu-amd" ;;
esac
DESCRIPTION="$(app description)"
PUBLISHER="$(app publisher)"
HOMEPAGE="$(app homepage)"
ICON="$(app icon)"
LICENSE_FILE="$(app license_file)"
[ -n "${LICENSE_FILE}" ] || err "app.json must name license_file"
app_packaging_validate_project_license "${LICENSE_FILE}" || err "the Python app license is required"
LICENSE_FILE="$(realpath "${LICENSE_FILE}")"
GUI_SCRIPT="$(app gui_script)"
# A deb needs "Name <address>"; without one in app.json, the reserved .invalid TLD says plainly there is none.
MAINTAINER="$(app maintainer)"
MAINTAINER="${MAINTAINER:-${PUBLISHER:-${APP_NAME}} <noreply@invalid>}"
read -r -a SCRIPTS <<< "$(app scripts)"
read -r -a SELF_TEST <<< "$(app self_test)"
[ -n "${GUI_SCRIPT}" ] || GUI_SCRIPT="${SCRIPTS[0]}"
# The wheel name's second field is its version: orchestrant-0.0.28-py3-none-any.whl.
VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["wheel"].split("-")[1])' "${BUNDLE}/bundle.json")"
DEB_ARCH="$(app_packaging_map_arch_to_deb "$(uname -m)")"
UNAME_ARCH="$(app_packaging_map_arch_to_appimage "$(uname -m)")"
info "${APP_NAME} ${VERSION} (${UNAME_ARCH}) from ${BUNDLE}"

# Runs the self-test through a packaged launcher; --root pins where its ONNX Runtime must come from.
prove() {
  local root="$1"; shift
  local -a provider_args=()
  [ "${RUN_TESTS}" = true ] || return 0
  if [ -n "${required_provider}" ]; then
    provider_args+=(--require-available-provider "${required_provider}")
    if [ "${PYTHON_APP_REQUIRE_ACTIVE_PROVIDER:-false}" = true ]; then provider_args+=(--require-provider "${required_provider}"); fi
  fi
  python3 "${SELFTEST}" --root "${root}" "${provider_args[@]}" -- "$@" > /dev/null || err "the packaged self-test failed: $*"
  info "  started: $* -> ok"
}

# This checks the declared project text, not the completeness of bundled dependency licenses.
verify_python_app_package_license() {
  local artifact="${1:?artifact required}" member="${2:?license member required}"
  python3 "${SCRIPT_DIR}/../verify_package_license.py" "${artifact}" --require "${member}=${LICENSE_FILE}"
}

verify_gpu_package() {
  [ -n "${required_provider}" ] || return 0
  python3 "${SCRIPT_DIR}/verify-python-gpu-package.py" --bundle "${BUNDLE}" \
    --wheel-dir "${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}" --artifact "$1" --prefix "$2"
}

package_tar() {
  local name="${ARTIFACT_ID}-${VERSION}-linux-${UNAME_ARCH}" stage test_dir
  stage="${WORK_DIR}/tar"
  rm -rf "${stage}" && mkdir -p "${stage}"
  cp -a "${BUNDLE}" "${stage}/${name}"
  tar -C "${stage}" -czf "${OUT_DIR}/${name}.tar.gz" "${name}"
  app_packaging_assert_artifact "${OUT_DIR}/${name}.tar.gz"
  verify_gpu_package "${OUT_DIR}/${name}.tar.gz" "${name}" || return $?
  verify_python_app_package_license "${OUT_DIR}/${name}.tar.gz" "${name}/LICENSE" || return $?
  test_dir="${WORK_DIR}/tar-test"
  rm -rf "${test_dir}" && mkdir -p "${test_dir}"
  tar -C "${test_dir}" -xzf "${OUT_DIR}/${name}.tar.gz"
  prove "${test_dir}/${name}" "${test_dir}/${name}/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}"
}

# The installed size in PNG terms: hicolor wants the icon under its real size.
icon_size() { python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' "$1"; }

# The packages owning the sonames left to the host, and libc6: unversioned when the bundle carries its glibc, else at the newest GLIBC_ any ELF asks for.
deb_depends() {
  python3 "${SCRIPT_DIR}/python-app-deb-depends.py" "${BUNDLE}"
}

package_deb() {
  local root="${WORK_DIR}/deb" depends file script size
  local output="${OUT_DIR}/${ARTIFACT_ID}_${VERSION}_${DEB_ARCH}.deb"
  command -v dpkg-deb > /dev/null || err "dpkg-deb not found"
  depends="$(deb_depends)"
  info "  Depends: ${depends}"
  rm -rf "${root}"
  mkdir -p "${root}/DEBIAN" "${root}/opt" "${root}/usr/bin" "${root}/usr/share/applications"
  cp -a "${BUNDLE}" "${root}/opt/${APP_ID}"
  # The launchers resolve themselves with readlink -f, so a symlink in PATH finds the bundle.
  for script in "${SCRIPTS[@]}"; do ln -s "/opt/${APP_ID}/bin/${script}" "${root}/usr/bin/${script}"; done
  APP_PACKAGING_COMMENT="${DESCRIPTION}" app_packaging_create_desktop_file \
    "${root}/usr/share/applications/${APP_ID}.desktop" "${APP_ID}" "${APP_NAME}" "${GUI_SCRIPT}" "${APP_ID}"
  if [ -n "${ICON}" ]; then
    size="$(icon_size "${ICON}")"
    mkdir -p "${root}/usr/share/icons/hicolor/${size}/apps"
    cp "${ICON}" "${root}/usr/share/icons/hicolor/${size}/apps/${APP_ID}.png"
  fi
  app_packaging_write_deb_control "${root}/DEBIAN/control" "${APP_ID}" "${VERSION}" "${DEB_ARCH}" \
    "${MAINTAINER}" "${depends}" "${APP_NAME}" "${DESCRIPTION}" "${HOMEPAGE}"
  chmod 0755 "${root}/DEBIAN"
  dpkg-deb --root-owner-group -Zgzip --build "${root}" "${output}" > /dev/null
  app_packaging_assert_artifact "${output}"
  verify_gpu_package "${output}" "opt/${APP_ID}" || return $?
  verify_python_app_package_license "${output}" "opt/${APP_ID}/LICENSE" || return $?
  [ "${RUN_TESTS}" = true ] || return 0
  if [ "$(id -u)" -eq 0 ] || sudo -n true > /dev/null 2>&1; then
    app_packaging_run_privileged_cmd dpkg -i "${output}" > /dev/null
    prove "/opt/${APP_ID}" "/usr/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}"
    app_packaging_run_privileged_cmd dpkg -r "${APP_ID}" > /dev/null
    [ ! -e "/opt/${APP_ID}" ] || err "dpkg -r left /opt/${APP_ID} behind"
  else
    warn "no root here: proving the deb's payload with dpkg-deb -x instead of dpkg -i"
    file="${WORK_DIR}/deb-test"
    rm -rf "${file}" && dpkg-deb -x "${output}" "${file}"
    prove "${file}/opt/${APP_ID}" "${file}/opt/${APP_ID}/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}"
  fi
}

package_appimage() {
  local appdir="${WORK_DIR}/${APP_ID}.AppDir" tool link runtime_file
  local output="${OUT_DIR}/${ARTIFACT_ID}-${VERSION}-${UNAME_ARCH}.AppImage"
  [ -n "${ICON}" ] || err "an AppImage needs an icon; app.json names none"
  tool="$(app_packaging_resolve_appimagetool)"
  runtime_file="$(app_packaging_appimage_runtime_file)"
  rm -rf "${appdir}" && mkdir -p "${appdir}/usr/lib"
  cp -a "${BUNDLE}" "${appdir}/usr/lib/${APP_ID}"
  # ARGV0 is the name the AppImage was started under: a symlink named after a script runs that script.
  cat > "${appdir}/AppRun" <<EOF
#!/bin/sh
here=\$(dirname "\$(readlink -f "\$0")")
case " ${SCRIPTS[*]} " in
  *" \${ARGV0##*/} "*) exec "\$here/usr/lib/${APP_ID}/bin/\${ARGV0##*/}" "\$@" ;;
esac
exec "\$here/usr/lib/${APP_ID}/bin/${GUI_SCRIPT}" "\$@"
EOF
  chmod 0755 "${appdir}/AppRun"
  APP_PACKAGING_COMMENT="${DESCRIPTION}" app_packaging_create_desktop_file \
    "${appdir}/${APP_ID}.desktop" "${APP_ID}" "${APP_NAME}" "AppRun" "${APP_ID}"
  cp "${ICON}" "${appdir}/${APP_ID}.png"
  APPIMAGE_EXTRACT_AND_RUN=1 NO_APPSTREAM=1 ARCH="${UNAME_ARCH}" "${tool}" ${runtime_file:+--runtime-file "${runtime_file}"} "${appdir}" "${output}" > /dev/null
  app_packaging_assert_artifact "${output}"
  verify_gpu_package "${output}" "usr/lib/${APP_ID}" || return $?
  bash "${SCRIPT_DIR}/verify-native-appimage-license.sh" "${output}" "${UNAME_ARCH}" "usr/lib/${APP_ID}/LICENSE" "${LICENSE_FILE}" || return $?
  link="${WORK_DIR}/appimage-test/${SELF_TEST[0]}"
  mkdir -p "$(dirname "${link}")" "${WORK_DIR}/appimage-run" && ln -sf "${output}" "${link}"
  # Extract-and-run needs no FUSE, which a container lacks; its temp dir is the root ORT must come from.
  APPIMAGE_EXTRACT_AND_RUN=1 TMPDIR="${WORK_DIR}/appimage-run" prove "${WORK_DIR}/appimage-run" "${link}" "${SELF_TEST[@]:1}"
}

IFS=',' read -r -a wanted <<< "${FORMATS}"
for format in "${wanted[@]}"; do
  info "== ${format}"
  case "${format}" in
    tar) package_tar ;;
    deb) package_deb ;;
    appimage) package_appimage ;;
    *) err "unknown format '${format}' (tar, deb, appimage)" ;;
  esac
done
info "packages ready in ${OUT_DIR}"
