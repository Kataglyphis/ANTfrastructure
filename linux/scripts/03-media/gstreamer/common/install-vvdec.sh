#!/usr/bin/env bash
set -euo pipefail

# Robust installer script for vvdec
# - clones the repo
# - builds shared library with CMake
# - installs into /usr/local
# - writes a pkg-config file if one isn't provided

TMPDIR="/tmp/vvdec"
PREFIX="/usr/local"

rm -rf "${TMPDIR}"
git clone --depth 1 https://github.com/fraunhoferhhi/vvdec.git "${TMPDIR}"
cd "${TMPDIR}"

# Prefer CMake build flow which is supported by vvdec
mkdir -p build
cmake -S . -B build -DENABLE_SHARED=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${PREFIX}"
cmake --build build --target install -- -j"$(nproc)"

# Ensure pkgconfig dir exists
mkdir -p "${PREFIX}/lib/pkgconfig"

## Create a simple pkg-config file if upstream did not install one
PKGFILE="${PREFIX}/lib/pkgconfig/libvvdec.pc"
if [ ! -f "${PKGFILE}" ]; then
  cat > "${PKGFILE}" <<PCF
prefix=${PREFIX}
exec_prefix=
libdir=${PREFIX}/lib
includedir=${PREFIX}/include

Name: libvvdec
Description: VVC/vvdec video decoder library
Version: 3.0
Libs: -L${libdir} -lvvdec
Cflags: -I${includedir}
PCF
fi

cd /
rm -rf "${TMPDIR}"

echo "vvdec installed to ${PREFIX} (pkg-config: ${PKGFILE})"
