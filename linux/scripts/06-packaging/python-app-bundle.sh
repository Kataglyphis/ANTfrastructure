#!/usr/bin/env bash
# Builds a consumer's Python app into a relocatable folder and proves it runs; see docs/python-app-bundles.md § What the builders do
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

REPO_ROOT="${PWD}"
CONFIG="packaging/app.json"
WHEEL_DIR="dist"
OUT_DIR=""
PYTHON_VERSION="3.14.8"
ORT_WHEEL_DIR="${ORT_CHAIN_WHEEL_DIR:-/opt/onnxruntime-wheels}"
WORK_DIR=""

usage() {
  printf 'usage: %s [--repo-root DIR] [--config FILE] [--wheel-dir DIR] [--out-dir DIR] [--python-version X.Y.Z] [--ort-wheel-dir DIR] [--work-dir DIR]\n' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:?}"; shift 2 ;;
    --config) CONFIG="${2:?}"; shift 2 ;;
    --wheel-dir) WHEEL_DIR="${2:?}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:?}"; shift 2 ;;
    --python-version) PYTHON_VERSION="${2:?}"; shift 2 ;;
    --ort-wheel-dir) ORT_WHEEL_DIR="${2:?}"; shift 2 ;;
    --work-dir) WORK_DIR="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

cd "${REPO_ROOT}"
case "$(uname -m)" in
  x86_64) ARCH=x86_64; MULTIARCH=x86_64-linux-gnu ;;
  aarch64) ARCH=aarch64; MULTIARCH=aarch64-linux-gnu ;;
  *) err "unsupported machine $(uname -m)" ;;
esac
[ -n "${OUT_DIR}" ] || OUT_DIR="dist/linux-${ARCH}/bundle"
[ -n "${WORK_DIR}" ] || WORK_DIR="$(mktemp -d)"
[ -f "${CONFIG}" ] || err "no app config at ${CONFIG}"

# One JSON read per key, with the image's python; the bundle's interpreter does not exist yet.
cfg() { python3 -c 'import json, sys; v = json.load(open(sys.argv[1]))[sys.argv[2]]; print("\n".join(v) if isinstance(v, list) else v)' "${CONFIG}" "$1"; }
APP_ID="$(cfg id)"
DISTRIBUTION="$(cfg distribution)"
DATA_ENV="$(cfg data_env)"
DATA_DIR="$(cfg data_dir)"
mapfile -t EXTRAS < <(cfg extras)
mapfile -t SCRIPTS < <(cfg scripts)
mapfile -t SELF_TEST < <(cfg self_test)

BUNDLE="$(realpath -m "${OUT_DIR}")"
RUNTIME="${BUNDLE}/runtime"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/bin"

dist_key="$(printf '%s' "${DISTRIBUTION}" | tr '[:upper:]-.' '[:lower:]__')"
app_wheel=""
for pattern in "*-manylinux*_${ARCH}.whl" "*-linux_${ARCH}.whl" "*-none-any.whl"; do
  for wheel in "${WHEEL_DIR}"/${pattern}; do
    [ -f "${wheel}" ] || continue
    name="$(basename "${wheel}")"
    [ "$(printf '%s' "${name%%-*}" | tr '[:upper:]-.' '[:lower:]__')" = "${dist_key}" ] || continue
    app_wheel="${wheel}"
    break 2
  done
done
[ -n "${app_wheel}" ] || err "no ${DISTRIBUTION} wheel in ${WHEEL_DIR}; build it first (ci_packaging.sh)"
info "app wheel: $(basename "${app_wheel}")"

ort_wheel=""
for wheel in "${ORT_WHEEL_DIR}"/onnxruntime*.whl; do
  case "$(basename "${wheel}")" in onnxruntime_genai*) continue ;; esac
  [ -f "${wheel}" ] || continue
  [ -z "${ort_wheel}" ] || err "more than one chain ONNX Runtime wheel in ${ORT_WHEEL_DIR}"
  ort_wheel="${wheel}"
done
[ -n "${ort_wheel}" ] || err "no chain ONNX Runtime wheel in ${ORT_WHEEL_DIR}: the family ships only the chain ORT"
info "chain ORT wheel: $(basename "${ort_wheel}")"

info "== runtime: python-build-standalone ${PYTHON_VERSION} (the image's distro Python is not relocatable)"
uv python install "${PYTHON_VERSION}" --install-dir "${WORK_DIR}/python" --no-bin
python_home="$(find "${WORK_DIR}/python" -mindepth 1 -maxdepth 1 -type d -name "cpython-${PYTHON_VERSION}-linux-*" | head -n 1)"
[ -n "${python_home}" ] || err "uv installed no cpython-${PYTHON_VERSION} into ${WORK_DIR}/python"
cp -a "${python_home}" "${RUNTIME}"
PY="${RUNTIME}/bin/python3"
"${PY}" -c 'import sys; print(sys.version)'

info "== packages from uv.lock (${EXTRAS[*]}), the app wheel, then the chain ORT"
extra_args=()
for extra in "${EXTRAS[@]}"; do extra_args+=(--extra "${extra}"); done
uv export --locked --no-dev --no-emit-project --format requirements.txt "${extra_args[@]}" --output-file "${WORK_DIR}/requirements.lock.txt"
uv pip install --python "${PY}" --break-system-packages --compile-bytecode --requirement "${WORK_DIR}/requirements.lock.txt"
uv pip install --python "${PY}" --break-system-packages --compile-bytecode --no-deps "${app_wheel}"
mapfile -t pypi_ort < <(uv pip list --python "${PY}" --format freeze | sed -n 's/^\(onnxruntime[a-z0-9_-]*\)==.*/\1/p' | grep -v genai || true)
[ "${#pypi_ort[@]}" -eq 0 ] || uv pip uninstall --python "${PY}" --break-system-packages "${pypi_ort[@]}"
uv pip install --python "${PY}" --break-system-packages --compile-bytecode --no-index --no-deps "${ort_wheel}"
# python-build-standalone ships its stdlib without bytecode, which the launchers' -B would recompile on every start.
"${PY}" -m compileall -q -j 0 -x '/(site-packages|test|tests|idlelib)/' "$("${PY}" -I -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"

info "== launchers"
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
exec "\$root/runtime/bin/python3" -I -B -c 'import sys; sys.argv[0] = "${script}"; from ${module} import ${func} as _entry; sys.exit(_entry())' "\$@"
EOF
  chmod 0755 "${BUNDLE}/bin/${script}"
  info "  ${script} -> ${target}"
done

info "== data"
python3 - "${CONFIG}" "${BUNDLE}" <<'PY'
import json, shutil, sys
from pathlib import Path
for item in json.load(open(sys.argv[1])).get("data", []):
    dest = Path(sys.argv[2]) / item["to"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(item["from"], dest)
    print(f"  {item['from']} -> {item['to']}")
PY

info "== ELF closure"
# G6 needs the chain ORT byte-identical, so it is protected and preloaded; oneDNN is absent image-wide, unloaded unless asked for.
ALLOWED_UNRESOLVED=(libdnnl.so.3)
closure_args=()
for soname in "${ALLOWED_UNRESOLVED[@]}"; do closure_args+=(--allow-unresolved "${soname}"); done
bash "${SCRIPT_DIR}/python-app-closure.sh" --bundle "${BUNDLE}" --lib-dir "${RUNTIME}/lib" \
  --search /opt/gcc-*/lib64 --search "/usr/lib/${MULTIARCH}" --search "/lib/${MULTIARCH}" \
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

info "== G6: ONNX Runtime is the chain build"
bash "${SCRIPT_DIR}/check-ort-provenance.sh" "${BUNDLE}"

info "== self-test: ${SELF_TEST[*]}"
report="$(python3 "${SCRIPT_DIR}/python-app-selftest.py" --root "${BUNDLE}" -- "${BUNDLE}/bin/${SELF_TEST[0]}" "${SELF_TEST[@]:1}")" ||
  err "self-test '${SELF_TEST[*]}' failed"
# The packagers read the waived sonames back: a deb must not depend on a library nothing loads.
python3 - "${BUNDLE}" "${report}" "$(basename "${app_wheel}")" "$(basename "${ort_wheel}")" "${PYTHON_VERSION}" "${ALLOWED_UNRESOLVED[*]}" "${SCRIPTS[@]}" <<'PY'
import json, sys
bundle, report, wheel, ort, python, allowed, *scripts = sys.argv[1:]
manifest = {"wheel": wheel, "ort_wheel": ort, "python": python, "scripts": scripts,
            "unresolved_allowed": allowed.split(), "self_test": json.loads(report)}
open(f"{bundle}/bundle.json", "w").write(json.dumps(manifest, indent=2) + "\n")
PY
info "bundle ready: ${BUNDLE} (${APP_ID})"
