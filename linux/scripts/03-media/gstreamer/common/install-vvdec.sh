#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/media/media-build-preamble.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/media/media-build-preamble.sh
  media_build_preamble_init "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

VV_VERSION="${VV_VERSION:-${VVDEC_VERSION:-${1:-v3.1.0}}}"
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
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${PREFIX}"
  -DCMAKE_INSTALL_LIBDIR="lib"
  -DCMAKE_CXX_FLAGS="-Wno-error=unused-but-set-variable"
)
if command -v append_cmake_cross_args >/dev/null 2>&1; then
  append_cmake_cross_args cmake_args
fi

cmake -S . -B build "${cmake_args[@]}" || {
  echo "ERROR: vvdec cmake configure failed" >&2
  exit 1
}

NPROC="$(nproc)"
if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
  NPROC="$(compute_jobs_with_mem_cap "" 2000)"
fi
cmake --build build --target install -- -j"${NPROC}" || {
  echo "ERROR: vvdec build failed" >&2
  exit 1
}

mkdir -p "${PREFIX}/lib/pkgconfig"

PKGFILE="${PREFIX}/lib/pkgconfig/libvvdec.pc"
vv_numeric="$(echo "${VV_VERSION}" | sed 's/^v//')"
cat > "${PKGFILE}" <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libvvdec
Description: VVC/vvdec video decoder library
Version: ${vv_numeric}
Libs: -L\${libdir} -lvvdec
Libs.private: -lstdc++ -lm -lgcc
Cflags: -I\${includedir}
EOF

cd /
rm -rf "${TMPDIR}"

if [ ! -f "${PREFIX}/lib/libvvdec.so" ] && [ ! -f "${PREFIX}/lib/libvvdec.so.3" ]; then
  echo "ERROR: vvdec shared library not found after install" >&2
  exit 1
fi

echo "vvdec ${VV_VERSION} installed to ${PREFIX} (pkg-config: ${PKGFILE})"
