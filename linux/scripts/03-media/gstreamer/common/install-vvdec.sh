#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

# Robust installer script for vvdec
# - clones the repo
# - builds shared library with CMake
# - installs into /usr/local
# - writes a pkg-config file if one isn't provided

TMPDIR="/tmp/vvdec"
PREFIX="/usr/local"

rm -rf "${TMPDIR}"
git clone --depth 1 --branch v3.1.0 https://github.com/fraunhoferhhi/vvdec.git "${TMPDIR}"
cd "${TMPDIR}"

# Prefer CMake build flow which is supported by vvdec
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
cmake -S . -B build "${cmake_args[@]}"
cmake --build build --target install -- -j"$(nproc)"

# Ensure pkgconfig dir exists
mkdir -p "${PREFIX}/lib/pkgconfig"

## Create a robust pkg-config file directly
PKGFILE="${PREFIX}/lib/pkgconfig/libvvdec.pc"
cat > "${PKGFILE}" <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libvvdec
Description: VVC/vvdec video decoder library
Version: 3.2.0
Libs: -L\${libdir} -lvvdec
Libs.private: -lstdc++ -lm -lgcc
Cflags: -I\${includedir}
EOF

cd /
rm -rf "${TMPDIR}"

echo "vvdec installed to ${PREFIX} (pkg-config: ${PKGFILE})"
