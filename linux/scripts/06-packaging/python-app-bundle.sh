#!/usr/bin/env bash
# Builds a consumer's Python app into a relocatable folder and proves it runs; see docs/python-app-bundles.md § What the builders do
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

source "${SCRIPT_DIR}/python-app-cli.sh"

REPO_ROOT="${PWD}"
CONFIG="packaging/app.json"
WHEEL_DIR="dist"
OUT_DIR=""
# The image's interpreter built the wheels, so its X.Y.Z decides; the pin runs ahead of a published image (CON90).
runtime_python_version() {
  local v
  v="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)" || v=""
  [ -n "${v}" ] || v="$(sed -n 's/^PYTHON_VERSION=//p' "${SCRIPT_DIR}/../01-core/versions.env" 2>/dev/null | head -n 1)"
  printf '%s' "${v}"
}
PYTHON_VERSION="$(runtime_python_version)"
ORT_WHEEL_DIR="${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}"
WORK_DIR=""
# image: the image's own CPython, staged relocatable; standalone: python-build-standalone, for a host without the image.
PYTHON_RUNTIME="image"

usage() {
  printf 'usage: %s [--repo-root DIR] [--config FILE] [--wheel-dir DIR] [--out-dir DIR] [--python-version X.Y.Z] [--ort-wheel-dir DIR] [--work-dir DIR] [--python-runtime image|standalone]\n' "$0"
}

parse_python_app_args bundle "$@"

cd "${REPO_ROOT}"
case "$(uname -m)" in
  x86_64) ARCH=x86_64; MULTIARCH=x86_64-linux-gnu ;;
  aarch64) ARCH=aarch64; MULTIARCH=aarch64-linux-gnu ;;
  *) err "unsupported machine $(uname -m)" ;;
esac
[ -n "${OUT_DIR}" ] || OUT_DIR="dist/linux-${ARCH}/bundle"
[ -n "${WORK_DIR}" ] || WORK_DIR="$(mktemp -d)"
[ -f "${CONFIG}" ] || err "no app config at ${CONFIG}"
[ -n "${PYTHON_VERSION}" ] || err "no PYTHON_VERSION: pass --python-version, or keep versions.env beside the scripts"

# One JSON read per key, with the image's python; the bundle's interpreter does not exist yet.
cfg() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print("\n".join(v) if isinstance(v, list) else v)' "${CONFIG}" "$1"; }
APP_ID="$(cfg id)"
DISTRIBUTION="$(cfg distribution)"
DATA_ENV="$(cfg data_env)"
DATA_DIR="$(cfg data_dir)"
mapfile -t EXTRAS < <(cfg extras)
mapfile -t SCRIPTS < <(cfg scripts)
mapfile -t SELF_TEST < <(cfg self_test)
# The optional "gstreamer" block: the image's own GStreamer travels, never the host's (docs/python-app-bundles.md § GStreamer).
gst_cfg() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1])).get("gstreamer", {}).get(sys.argv[2], []); sys.stdout.write("".join(x + "\n" for x in v))' "${CONFIG}" "$1"; }
mapfile -t GST_TOOLS < <(gst_cfg tools)
mapfile -t GST_PLUGINS < <(gst_cfg plugins)
mapfile -t GST_OPTIONAL < <(gst_cfg optional)
mapfile -t GST_ELEMENTS < <(gst_cfg elements)

BUNDLE="$(realpath -m "${OUT_DIR}")"
RUNTIME="${BUNDLE}/runtime"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/bin"

# select_app_wheel <dir> <dist key> <arch> <abi>: the binary wheel for the runtime's ABI (or abi3), else the pure one; another ABI's binaries alone are an error.
select_app_wheel() {
  local dir="$1" key="$2" arch="$3" abi="$4" wheel name tag others=""
  for wheel in "${dir}"/*-manylinux*_"${arch}".whl "${dir}"/*-linux_"${arch}".whl "${dir}"/*-none-any.whl; do
    [ -f "${wheel}" ] || continue
    name="${wheel##*/}"
    [ "$(printf '%s' "${name%%-*}" | tr '[:upper:]-.' '[:lower:]__')" = "${key}" ] || continue
    tag="${name%-*}"
    tag="${tag##*-}"
    case "${tag}" in
      "${abi}"|abi3) printf '%s\n' "${wheel}"; return 0 ;;
      none) [ -n "${others}" ] || { printf '%s\n' "${wheel}"; return 0; } ;;
      *) others+=" ${name}" ;;
    esac
  done
  if [ -n "${others}" ]; then
    printf 'no %s wheel in %s, only%s; build one with the runtime interpreter (ci_packaging.sh)\n' "${abi}" "${dir}" "${others}"
  else
    printf 'no %s wheel in %s; build it first (ci_packaging.sh)\n' "${key}" "${dir}"
  fi
  return 1
}

# Resolve against chain ORT immediately: the PyPI provider may lack this Python ABI.
install_python_app_packages() {
  local python="$1" app="$2" ort="$3" work="$4" provider_names provider extra
  shift 4
  local -a export_args=(--locked --no-dev --no-emit-project --format requirements.txt)
  provider_names="$(python3 - "${SCRIPT_DIR}/../03-media/runtime/ort-venv-census.py" <<'PY'
import runpy
import sys
import tomllib

census = runpy.run_path(sys.argv[1])
with open("uv.lock", "rb") as stream:
    lock = tomllib.load(stream)
for name in sorted({census["norm"](package["name"]) for package in lock["package"]}):
    if census["ORT_RUNTIME"].fullmatch(name):
        print(name)
PY
  )" || return 1
  while IFS= read -r provider; do
    [ -z "${provider}" ] || export_args+=(--no-emit-package "${provider}")
  done <<< "${provider_names}"
  for extra in "$@"; do export_args+=(--extra "${extra}"); done
  # Keep provider dependencies and all other locked packages (also GenAI/Extensions) and hashes.
  uv export "${export_args[@]}" --output-file "${work}/requirements.lock.txt" || return 1
  uv pip install --python "${python}" --break-system-packages --compile-bytecode \
    --requirement "${work}/requirements.lock.txt" "${ort}" || return 1
  uv pip install --python "${python}" --break-system-packages --compile-bytecode --no-deps "${app}"
}

dist_key="$(printf '%s' "${DISTRIBUTION}" | tr '[:upper:]-.' '[:lower:]__')"

ort_wheel=""
for wheel in "${ORT_WHEEL_DIR}"/onnxruntime*.whl; do
  case "$(basename "${wheel}")" in onnxruntime_genai*) continue ;; esac
  [ -f "${wheel}" ] || continue
  [ -z "${ort_wheel}" ] || err "more than one chain ONNX Runtime wheel in ${ORT_WHEEL_DIR}"
  ort_wheel="${wheel}"
done
[ -n "${ort_wheel}" ] || err "no chain ONNX Runtime wheel in ${ORT_WHEEL_DIR}: the family ships only the chain ORT"
info "chain ORT wheel: $(basename "${ort_wheel}")"

case "${PYTHON_RUNTIME}" in
  image)
    image_python_version="$(python3 -I -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
    [ "${image_python_version}" = "${PYTHON_VERSION}" ] ||
      err "the image's python3 is ${image_python_version}, not ${PYTHON_VERSION}; pass --python-runtime standalone for another version"
    info "== runtime: the image's own CPython ${PYTHON_VERSION}, staged relocatable"
    python3 -I "${SCRIPT_DIR}/python-relocate.py" stage --python "$(command -v python3)" --dest "${RUNTIME}" ||
      err "could not stage the image's CPython; pass --python-runtime standalone on a host without the image"
    python3 -I "${SCRIPT_DIR}/python-relocate.py" check --tree "${RUNTIME}" || err "the staged CPython does not run once moved"
    ;;
  standalone)
    info "== runtime: python-build-standalone ${PYTHON_VERSION}"
    uv python install "${PYTHON_VERSION}" --install-dir "${WORK_DIR}/python" --no-bin
    python_home="$(find "${WORK_DIR}/python" -mindepth 1 -maxdepth 1 -type d -name "cpython-${PYTHON_VERSION}-linux-*" | head -n 1)"
    [ -n "${python_home}" ] || err "uv installed no cpython-${PYTHON_VERSION} into ${WORK_DIR}/python"
    cp -a "${python_home}" "${RUNTIME}"
    ;;
  *) err "--python-runtime is image or standalone, not '${PYTHON_RUNTIME}'" ;;
esac
PY="${RUNTIME}/bin/python3"
"${PY}" -c 'import sys; print(sys.version)'
# The runtime decides: ci_packaging.sh ships a free-threaded twin beside the GIL wheel, and only one of them installs here.
abi="$("${PY}" -I -c 'import sys, sysconfig; print("cp%d%d%s" % (*sys.version_info[:2], "t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""))')"
app_wheel="$(select_app_wheel "${WHEEL_DIR}" "${dist_key}" "${ARCH}" "${abi}")" || err "${app_wheel}"
info "app wheel for the ${abi} runtime: $(basename "${app_wheel}")"

info "== locked packages (${EXTRAS[*]}) with the chain ORT, then the app wheel"
install_python_app_packages "${PY}" "${app_wheel}" "${ort_wheel}" "${WORK_DIR}" "${EXTRAS[@]}"
# python-build-standalone ships its stdlib without bytecode, which the launchers' -B would recompile on every start; the image's has it.
"${PY}" -m compileall -q -j 0 -x '/(site-packages|test|tests|idlelib)/' "$("${PY}" -I -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"

info "== launchers"
gst_env=""
if [ "${#GST_PLUGINS[@]}" -gt 0 ]; then
  gst_env="export GST_PLUGIN_PATH=\"\$root/runtime/lib/gstreamer-1.0\" GST_PLUGIN_SYSTEM_PATH= GST_PLUGIN_SYSTEM_PATH_1_0= GST_REGISTRY_FORK=no
copy=\$(printf %s \"\$root\" | cksum | cut -d' ' -f1)
export GST_REGISTRY=\"\${XDG_CACHE_HOME:-\${HOME:-/tmp}/.cache}/${APP_ID}/gstreamer-\$copy.bin\"
export PATH=\"\$root/runtime/libexec/gstreamer:\$PATH\""
fi
entry_points="$("${PY}" -I -c 'import sys
from importlib.metadata import distribution
for ep in distribution(sys.argv[1]).entry_points.select(group="console_scripts"):
    print(ep.name, ep.value)' "${DISTRIBUTION}")"
for script in "${SCRIPTS[@]}"; do
  target="$(printf '%s\n' "${entry_points}" | awk -v n="${script}" '$1 == n { print $2 }')"
  [[ "${target}" =~ ^[A-Za-z0-9_.]+:[A-Za-z0-9_]+$ ]] || err "${DISTRIBUTION} declares no console script '${script}' as module:function"
  module="${target%%:*}"
  func="${target##*:}"
  cat > "${BUNDLE}/bin/${script}" <<EOF
#!/bin/sh
# ${script}: runs ${target} on the bundle's own CPython; -I keeps PYTHON* variables and the user site out, -B leaves the install dir unwritten.
here=\$(dirname "\$(readlink -f "\$0")")
root=\$(dirname "\$here")
export ${DATA_ENV}="\$root/${DATA_DIR}"
${gst_env}
exec "\$root/runtime/bin/python3" -I -B -c 'import sys; sys.argv[0] = "${script}"; from ${module} import ${func} as _entry; sys.exit(_entry())' "\$@"
EOF
  chmod 0755 "${BUNDLE}/bin/${script}"
  info "  ${script} -> ${target}"
done

info "== data"
python3 - "${CONFIG}" "${BUNDLE}" <<'PY'
import json
import shutil
import sys
from pathlib import Path

with open(sys.argv[1], encoding="utf-8") as config_file:
    data = json.load(config_file).get("data", [])
for item in data:
    dest = Path(sys.argv[2]) / item["to"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(item["from"], dest)
    print(f"  {item['from']} -> {item['to']}")
PY

gst_search=()
if [ "${#GST_PLUGINS[@]}" -gt 0 ]; then
  info "== GStreamer: the image's own build, its plugins and tools"
  gst_args=()
  for plugin in "${GST_PLUGINS[@]}"; do gst_args+=(--plugin "${plugin}"); done
  for plugin in "${GST_OPTIONAL[@]}"; do gst_args+=(--optional "${plugin}"); done
  bash "${SCRIPT_DIR}/gstreamer-bundle.sh" copy --dest "${RUNTIME}/lib/gstreamer-1.0" "${gst_args[@]}"
  mkdir -p "${RUNTIME}/libexec/gstreamer"
  for tool in "${GST_TOOLS[@]}"; do cp -L "$(pkg-config --variable=prefix gstreamer-1.0)/bin/${tool}" "${RUNTIME}/libexec/gstreamer/${tool}"; done
  # Ahead of the multiarch dirs, which hold the distro's GStreamer too; the image reaches these only through ld.so.conf.
  for dir in "$(pkg-config --variable=libdir gstreamer-1.0)" "${LIBCAMERA_PREFIX:-/opt/libcamera}/lib"; do
    [ -d "${dir}" ] && gst_search+=(--search "${dir}")
  done
fi

info "== ELF closure"
# G6 needs the chain ORT byte-identical, so it is protected and preloaded; oneDNN is absent image-wide, unloaded unless asked for.
ALLOWED_UNRESOLVED=(libdnnl.so.3)
closure_args=()
for soname in "${ALLOWED_UNRESOLVED[@]}"; do closure_args+=(--allow-unresolved "${soname}"); done
bash "${SCRIPT_DIR}/python-app-closure.sh" --bundle "${BUNDLE}" --lib-dir "${RUNTIME}/lib" \
  --search /opt/gcc-*/lib64 "${gst_search[@]}" --search "/usr/lib/${MULTIARCH}" --search "/lib/${MULTIARCH}" \
  --protect '*/site-packages/onnxruntime/*' "${closure_args[@]}"
site_packages="$("${PY}" -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
cat > "${site_packages}/sitecustomize.py" <<'PY'
# Written by python-app-bundle.sh: loads what the protected chain ORT needs from runtime/lib, so its sonames resolve.
import ctypes
import os
import sys

_lib = os.path.join(sys.prefix, "lib")
_list = os.path.join(_lib, "preload.list")
if os.path.exists(_list):
    with open(_list) as _f:
        for _name in _f.read().split():
            ctypes.CDLL(os.path.join(_lib, _name), mode=ctypes.RTLD_GLOBAL)
PY

info "== loader: the image's glibc travels, for hosts with an older one"
# On the interpreter itself: a child that runs sys.executable starts through the same launcher, which --argv0 keeps as its path.
gst_tools=()
for tool in "${GST_TOOLS[@]}"; do gst_tools+=("runtime/libexec/gstreamer/${tool}"); done
bash "${SCRIPT_DIR}/bundle-loader.sh" --beside "${BUNDLE}" "${RUNTIME}/lib" "runtime/bin/$(basename "$(readlink -f "${PY}")")" "${gst_tools[@]}"
GLIBC_VERSION="$(getconf GNU_LIBC_VERSION | awk '{ print $2 }')"

if [ "${#GST_ELEMENTS[@]}" -gt 0 ]; then
  info "== GStreamer: every element from the bundled plugins alone"
  bash "${SCRIPT_DIR}/gstreamer-bundle.sh" check --plugins "${RUNTIME}/lib/gstreamer-1.0" --lib-dir "${RUNTIME}/lib" "${GST_ELEMENTS[@]}"
fi
for tool in "${GST_TOOLS[@]}"; do
  for bundled in "" 1; do
    KATAGLYPHIS_BUNDLED_GLIBC="${bundled}" GST_PLUGIN_PATH="${RUNTIME}/lib/gstreamer-1.0" GST_PLUGIN_SYSTEM_PATH='' \
      GST_PLUGIN_SYSTEM_PATH_1_0='' GST_REGISTRY_FORK=no GST_REGISTRY="${WORK_DIR}/gst-registry.bin" \
      "${RUNTIME}/libexec/gstreamer/${tool}" --version >/dev/null || err "the bundled ${tool} does not start${bundled:+ through the bundled loader}"
  done
  info "  ${tool} starts on both glibc paths"
done

info "== G6: ONNX Runtime is the chain build"
bash "${SCRIPT_DIR}/check-ort-provenance.sh" "${BUNDLE}"

info "== self-test: ${SELF_TEST[*]}"
report="$(python3 "${SCRIPT_DIR}/python-app-selftest.py" --root "${BUNDLE}" -- "${BUNDLE}/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}")" ||
  err "self-test '${SELF_TEST[*]}' failed"
info "== self-test through the bundled loader, as on a host with an older glibc"
KATAGLYPHIS_BUNDLED_GLIBC=1 python3 "${SCRIPT_DIR}/python-app-selftest.py" --root "${BUNDLE}" -- "${BUNDLE}/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}" >/dev/null ||
  err "self-test '${SELF_TEST[*]}' failed through the bundled loader"
# The packagers read the waived sonames back: a deb must not depend on a library nothing loads.
python3 - "${BUNDLE}" "${report}" "$(basename "${app_wheel}")" "$(basename "${ort_wheel}")" "${PYTHON_VERSION}" "${GLIBC_VERSION}" "${ALLOWED_UNRESOLVED[*]}" "${SCRIPTS[@]}" <<'PY'
import json
import sys

bundle, report, wheel, ort, python, glibc, allowed, *scripts = sys.argv[1:]
manifest = {"wheel": wheel, "ort_wheel": ort, "python": python, "glibc": glibc, "scripts": scripts,
            "unresolved_allowed": allowed.split(), "self_test": json.loads(report)}
with open(f"{bundle}/bundle.json", "w", encoding="utf-8") as manifest_file:
    json.dump(manifest, manifest_file, indent=2)
    manifest_file.write("\n")
PY
info "bundle ready: ${BUNDLE} (${APP_ID})"
