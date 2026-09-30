#!/usr/bin/env bash
# Wraps a python-app-bundle.sh folder as tar.gz, deb and AppImage, and starts each as a user would; see docs/python-app-bundles.md § Packages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/app-packaging.sh
source "${SCRIPT_DIR}/../lib/app-packaging.sh"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

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

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:?}"; shift 2 ;;
    --config) CONFIG="${2:?}"; shift 2 ;;
    --bundle) BUNDLE="${2:?}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --formats) FORMATS="${2:?}"; shift 2 ;;
    --no-test) RUN_TESTS=false; shift ;;
    --work-dir) WORK_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

cd "${REPO_ROOT}"
[ -n "${BUNDLE}" ] || { usage >&2; exit 2; }
BUNDLE="$(realpath "${BUNDLE}")"
[ -f "${BUNDLE}/bundle.json" ] || err "no bundle.json in ${BUNDLE}: build it with python-app-bundle.sh first"
OUT_DIR="$(realpath -m "${OUT_DIR:-$(dirname "${BUNDLE}")}")"
mkdir -p "${OUT_DIR}" "${WORK_DIR}"
SELFTEST="${SCRIPT_DIR}/python-app-selftest.py"

# One JSON read per fact; arrays come back space-separated, which console-script names allow.
app() {
  python3 -c 'import json, sys; v = json.load(open(sys.argv[1])).get(sys.argv[2], ""); print(" ".join(v) if isinstance(v, list) else v)' "${CONFIG}" "$1"
}
APP_ID="$(app id)"
APP_NAME="$(app name)"
DESCRIPTION="$(app description)"
PUBLISHER="$(app publisher)"
HOMEPAGE="$(app homepage)"
ICON="$(app icon)"
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
  [ "${RUN_TESTS}" = true ] || return 0
  python3 "${SELFTEST}" --root "${root}" -- "$@" > /dev/null || err "the packaged self-test failed: $*"
  info "  started: $* -> ok"
}

package_tar() {
  local name="${APP_ID}-${VERSION}-linux-${UNAME_ARCH}" stage test_dir
  stage="${WORK_DIR}/tar"
  rm -rf "${stage}" && mkdir -p "${stage}"
  cp -a "${BUNDLE}" "${stage}/${name}"
  tar -C "${stage}" -czf "${OUT_DIR}/${name}.tar.gz" "${name}"
  app_packaging_assert_artifact "${OUT_DIR}/${name}.tar.gz"
  test_dir="${WORK_DIR}/tar-test"
  rm -rf "${test_dir}" && mkdir -p "${test_dir}"
  tar -C "${test_dir}" -xzf "${OUT_DIR}/${name}.tar.gz"
  prove "${test_dir}/${name}" "${test_dir}/${name}/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}"
}

# The installed size in PNG terms: hicolor wants the icon under its real size.
icon_size() { python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' "$1"; }

# libc6 at the newest GLIBC_ version any ELF asks for, plus the packages owning the sonames left to the host.
deb_depends() {
  python3 - "${BUNDLE}" <<'PY'
import json, os, re, subprocess, sys
bundle = sys.argv[1]
# What the bundle builder waived on purpose (the chain ORT's DNNL provider without oneDNN) is no dependency.
waived = set(json.load(open(os.path.join(bundle, "bundle.json"))).get("unresolved_allowed", []))
names, needed, glibc = set(waived), set(), (2, 17)
for root, _, files in os.walk(bundle):
    for f in files:
        names.add(f)
for root, _, files in os.walk(bundle):
    for f in files:
        path = os.path.join(root, f)
        if os.path.islink(path):
            continue
        with open(path, "rb") as fh:
            if fh.read(4) != b"\x7fELF":
                continue
        dyn = subprocess.run(["readelf", "-dW", path], capture_output=True, text=True).stdout
        # An $ORIGIN/../lib/... entry (python-build-standalone's python3) names a bundled file by path.
        needed.update(n for n in re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", dyn) if n.rsplit("/", 1)[-1] not in names)
        ver = subprocess.run(["readelf", "-VW", path], capture_output=True, text=True).stdout
        for v in re.findall(r"GLIBC_(\d+)\.(\d+)", ver):
            glibc = max(glibc, (int(v[0]), int(v[1])))
cache = subprocess.run(["ldconfig", "-p"], capture_output=True, text=True).stdout
packages, missing = {"libc6"}, []
for soname in sorted(needed):
    m = re.search(r"^\s*" + re.escape(soname) + r" \(.*?\) => (\S+)$", cache, re.M)
    path = m.group(1) if m else ""
    # usrmerge: ldconfig says /lib/..., dpkg recorded /usr/lib/... or the versioned file the link names.
    candidates = [path, "/usr" + path if path.startswith("/lib") else "", os.path.realpath(path) if path else ""]
    owner = ""
    for candidate in filter(None, candidates):
        found = subprocess.run(["dpkg", "-S", candidate], capture_output=True, text=True)
        if found.returncode == 0:
            owner = found.stdout.split(":")[0]
            break
    if not owner:
        missing.append(soname)
        continue
    packages.add(owner)
if missing:
    sys.exit("no installed package provides " + ", ".join(missing) + "; the deb could not name its dependencies")
packages.discard("libc6")
print(", ".join([f"libc6 (>= {glibc[0]}.{glibc[1]})"] + sorted(packages)))
PY
}

package_deb() {
  local root="${WORK_DIR}/deb" depends file script size
  local output="${OUT_DIR}/${APP_ID}_${VERSION}_${DEB_ARCH}.deb"
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
  cat > "${root}/DEBIAN/control" <<EOF
Package: ${APP_ID}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: ${MAINTAINER}
Homepage: ${HOMEPAGE}
Depends: ${depends}
Description: ${APP_NAME}
 ${DESCRIPTION}
EOF
  chmod 0755 "${root}/DEBIAN"
  dpkg-deb --root-owner-group --build "${root}" "${output}" > /dev/null
  app_packaging_assert_artifact "${output}"
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
  local appdir="${WORK_DIR}/${APP_ID}.AppDir" tool link
  local output="${OUT_DIR}/${APP_ID}-${VERSION}-${UNAME_ARCH}.AppImage"
  [ -n "${ICON}" ] || err "an AppImage needs an icon; app.json names none"
  tool="$(app_packaging_resolve_appimagetool)"
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
  APPIMAGE_EXTRACT_AND_RUN=1 NO_APPSTREAM=1 ARCH="${UNAME_ARCH}" "${tool}" "${appdir}" "${output}" > /dev/null
  app_packaging_assert_artifact "${output}"
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
