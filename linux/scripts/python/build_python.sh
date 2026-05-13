#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source_first_helper() {
  local helper=""

  for helper in "$@"; do
    if [ -f "${helper}" ]; then
      # shellcheck disable=SC1090
      source "${helper}"
      return 0
    fi
  done

  return 1
}

source_first_helper \
  "/opt/scripts/core/platform.sh" \
  "${SCRIPT_DIR}/../01-core/platform.sh"

source_first_helper \
  "/opt/scripts/core/cross-env.sh" \
  "${SCRIPT_DIR}/../01-core/cross-env.sh" || true

PYTHON_VERSION=${1:-3.14.4}
PYTHON_MAJOR_MINOR="${PYTHON_MAJOR_MINOR:-$(version_major_minor "${PYTHON_VERSION}")}"
PYTHON_TARBALL="/tmp/Python-${PYTHON_VERSION}.tgz"
PYTHON_SOURCE_DIR="/tmp/Python-${PYTHON_VERSION}"

cleanup() {
  rm -rf "${PYTHON_SOURCE_DIR}" "${PYTHON_TARBALL}"
}

trap cleanup EXIT

build_cross_target_python_dev_files() {
  local source_dir="$1"
  local python_mm target_triplet build_triplet build_python_bin cross_build_dir config_site
  local target_libdir target_pkgconfig_dir target_include target_arch_include
  local target_python_so target_python_soversion pkg_config_libdir build_python_libdir

  if ! command -v cross_build_enabled >/dev/null 2>&1 || ! cross_build_enabled; then
    return 0
  fi

  if command -v host_python_major_minor >/dev/null 2>&1; then
    python_mm="$(host_python_major_minor)"
  else
    python_mm="${PYTHON_MAJOR_MINOR}"
  fi
  target_triplet="$(cross_target_triplet)"
  build_triplet="$(build_deb_multiarch_triplet)"
  build_python_bin="/usr/local/bin/python${python_mm}"
  build_python_libdir="/usr/local/lib"
  cross_build_dir="/tmp/Python-${PYTHON_VERSION}-cross-${target_triplet}"
  config_site="/tmp/python-config-site-${target_triplet}"
  target_libdir="/usr/lib/${target_triplet}"
  target_pkgconfig_dir="${target_libdir}/pkgconfig"
  target_include="/usr/include/python${python_mm}"
  target_arch_include="/usr/include/${target_triplet}/python${python_mm}"
  target_python_so="libpython${python_mm}.so"
  target_python_soversion="libpython${python_mm}.so.1.0"
  pkg_config_libdir="/usr/${target_triplet}/lib/pkgconfig:/usr/lib/${target_triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"

  echo "Cross mode detected; building target Python ${python_mm} development artifacts for ${target_triplet}"

  if [ ! -x "${build_python_bin}" ]; then
    echo "Expected build Python ${build_python_bin} was not found" >&2
    exit 1
  fi

  setup_linux_cross_env

  # Host in-tree builds leave generated frozen headers in the source tree.
  # Remove them so the out-of-tree cross build regenerates its own copies
  # in the build directory instead of resolving stale VPATH matches.
  rm -f "${source_dir}/Python/frozen_modules/"*.h "${source_dir}/Python/frozen_modules/MANIFEST"

  rm -rf "${cross_build_dir}"
  mkdir -p "${cross_build_dir}/Python/frozen_modules"

  cat > "${config_site}" <<EOF
ac_cv_buggy_getaddrinfo=no
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
EOF

  (
    cd "${cross_build_dir}"
    CONFIG_SITE="${config_site}" \
      LD_LIBRARY_PATH="${build_python_libdir}:${LD_LIBRARY_PATH:-}" \
      PKG_CONFIG_ALLOW_CROSS=1 \
      PKG_CONFIG_SYSROOT_DIR=/ \
      PKG_CONFIG_LIBDIR="${pkg_config_libdir}" \
      "${source_dir}/configure" \
        --build="${build_triplet}" \
        --host="${target_triplet}" \
        --prefix=/usr \
        --exec-prefix=/usr \
        --libdir="${target_libdir}" \
        --includedir=/usr/include \
        --with-build-python="${build_python_bin}" \
        --with-pkg-config=yes \
        --enable-shared \
        --without-ensurepip \
        --disable-test-modules
  )

  (
    cd "${cross_build_dir}"
    make -j"$(nproc)" "${target_python_so}"
  )

  mkdir -p "${target_include}" "${target_arch_include}" "${target_libdir}" "${target_pkgconfig_dir}"

  cp -a "${source_dir}/Include/." "${target_include}/"
  cp -a "${cross_build_dir}/pyconfig.h" "${target_include}/pyconfig.h"
  cp -a "${cross_build_dir}/pyconfig.h" "${target_arch_include}/pyconfig.h"

  if [ -f "${cross_build_dir}/${target_python_soversion}" ]; then
    cp -a "${cross_build_dir}/${target_python_soversion}" "${target_libdir}/${target_python_soversion}"
    ln -sf "${target_python_soversion}" "${target_libdir}/${target_python_so}"
  elif [ -f "${cross_build_dir}/${target_python_so}" ]; then
    cp -a "${cross_build_dir}/${target_python_so}" "${target_libdir}/${target_python_so}"
  else
    echo "Expected cross-built ${target_python_so} was not produced" >&2
    exit 1
  fi

  if [ -f "${cross_build_dir}/Misc/python.pc" ]; then
    cp -a "${cross_build_dir}/Misc/python.pc" "${target_pkgconfig_dir}/python-${python_mm}.pc"
    ln -sf "python-${python_mm}.pc" "${target_pkgconfig_dir}/python3.pc"
  else
    echo "Expected cross-built python-${python_mm}.pc was not produced" >&2
    exit 1
  fi

  if [ -f "${cross_build_dir}/Misc/python-embed.pc" ]; then
    cp -a "${cross_build_dir}/Misc/python-embed.pc" "${target_pkgconfig_dir}/python-${python_mm}-embed.pc"
    ln -sf "python-${python_mm}-embed.pc" "${target_pkgconfig_dir}/python3-embed.pc"
  else
    echo "Expected cross-built python-${python_mm}-embed.pc was not produced" >&2
    exit 1
  fi

  echo "Target Python ${python_mm} development artifacts staged:"
  echo "  include: ${target_include}"
  echo "  arch include: ${target_arch_include}"
  echo "  libdir: ${target_libdir}"
  echo "  pkg-config: ${target_pkgconfig_dir}"

  rm -rf "${cross_build_dir}" "${config_site}"
}

echo "Building Python ${PYTHON_VERSION} from source..."

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
  echo "Cross mode detected; building host Python ${PYTHON_VERSION} for shared build tooling"
fi

wget "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" -O "${PYTHON_TARBALL}"
tar -xf "${PYTHON_TARBALL}" -C /tmp

cd "${PYTHON_SOURCE_DIR}"
./configure --enable-shared --enable-optimizations --prefix=/usr/local
make -j"$(nproc)"
make altinstall

# Add the lib path to the system linker
echo "/usr/local/lib" > "/etc/ld.so.conf.d/python-${PYTHON_VERSION}.conf"
ldconfig

build_cross_target_python_dev_files "${PYTHON_SOURCE_DIR}"

# Clean up
cd /
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Python ${PYTHON_VERSION} built and installed successfully."
