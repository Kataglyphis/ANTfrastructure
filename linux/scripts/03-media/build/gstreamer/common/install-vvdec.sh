#!/usr/bin/env bash
set -euo pipefail

_VVDEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_VVDEC_DIR}/../../../core/common.sh"
media_common_init "${_VVDEC_DIR}"

VV_VERSION="${VV_VERSION:-${VVDEC_VERSION:-${1:-v3.2.0}}}"
TMPDIR="/tmp/vvdec-$$"
PREFIX="/usr/local"

echo "Building vvdec ${VV_VERSION}..."

rm -rf "${TMPDIR}"
git clone --depth 1 --branch "${VV_VERSION}" https://github.com/fraunhoferhhi/vvdec.git "${TMPDIR}" || {
  echo "ERROR: Failed to clone vvdec ${VV_VERSION}" >&2
  exit 1
}
cd "${TMPDIR}"

mkdir -p build
cmake_args=(
  -DBUILD_SHARED_LIBS=ON
  -DBUILD_APPS=OFF
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${PREFIX}"
  -DCMAKE_INSTALL_LIBDIR="lib"
  # maybe-uninitialized is optimization-dependent and fires inside SIMDe's
  # x86-emulation headers once riscv64 builds with vector. Upstream third-party
  # code, not ours. docs/failure-modes.md
  -DCMAKE_CXX_FLAGS="-Wno-error=unused-but-set-variable -Wno-error=maybe-uninitialized"
  -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined"
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-shlib-undefined"
)
if command -v append_cmake_cross_args >/dev/null 2>&1; then
  append_cmake_cross_args cmake_args
fi

cmake -S . -B build "${cmake_args[@]}" || {
  echo "ERROR: vvdec cmake configure failed" >&2
  exit 1
}

NPROC="$(media_jobs)"
cmake --build build --target install -- -j"${NPROC}" || {
  echo "ERROR: vvdec build failed" >&2
  exit 1
}

mkdir -p "${PREFIX}/lib/pkgconfig"

PKGFILE="${PREFIX}/lib/pkgconfig/libvvdec.pc"
vv_numeric="$(echo "${VV_VERSION}" | sed 's/^v//')"
generate_pkgconfig_file "${PKGFILE}" \
  "libvvdec" "VVC/vvdec video decoder library" "${vv_numeric}" "${PREFIX}" \
  '-L${libdir} -lvvdec' '-I${includedir}' '' '-lstdc++ -lm -lgcc'

cd /
rm -rf "${TMPDIR}"

if [ ! -f "${PREFIX}/lib/libvvdec.so" ] && [ ! -f "${PREFIX}/lib/libvvdec.so.3" ]; then
  echo "ERROR: vvdec shared library not found after install" >&2
  exit 1
fi

echo "vvdec ${VV_VERSION} installed to ${PREFIX} (pkg-config: ${PKGFILE})"
