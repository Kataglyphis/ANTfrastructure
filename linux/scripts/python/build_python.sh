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
PYTHON_CROSS_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}"

cleanup() {
  rm -rf \
    "${PYTHON_SOURCE_DIR}" \
    "${PYTHON_TARBALL}" \
    /tmp/Python-"${PYTHON_VERSION}"-cross-* \
    /tmp/python-config-site-*
}

trap cleanup EXIT

python_cross_stage_root_for_arch() {
  local target_arch="$1"

  printf '%s' "${PYTHON_CROSS_STAGE_ROOT}/$(arch_normalize "${target_arch}")"
}

python_cross_stage_prefix_for_arch() {
  local target_arch="$1"

  printf '%s' "$(python_cross_stage_root_for_arch "${target_arch}")/usr/local"
}

python_hostrunner_for_arch() {
  local target_arch="$1"

  case "$(arch_normalize "${target_arch}")" in
    amd64)
      command -v qemu-x86_64-static 2>/dev/null || command -v qemu-x86_64 2>/dev/null || true
      ;;
    arm64)
      command -v qemu-aarch64-static 2>/dev/null || command -v qemu-aarch64 2>/dev/null || true
      ;;
    386)
      command -v qemu-i386-static 2>/dev/null || command -v qemu-i386 2>/dev/null || true
      ;;
    riscv64)
      command -v qemu-riscv64-static 2>/dev/null || command -v qemu-riscv64 2>/dev/null || true
      ;;
    *)
      return 1
      ;;
  esac
}

python_stage_finalize() {
  local target_arch="$1"
  local stage_root="$2"
  local python_mm="$3"
  local target_triplet="$4"
  local pkgconfig_dir="${stage_root}/usr/local/lib/pkgconfig"

  mkdir -p "${stage_root}/usr/local/include/${target_triplet}/python${python_mm}"
  if [ -f "${stage_root}/usr/local/include/python${python_mm}/pyconfig.h" ]; then
    cp -a \
      "${stage_root}/usr/local/include/python${python_mm}/pyconfig.h" \
      "${stage_root}/usr/local/include/${target_triplet}/python${python_mm}/pyconfig.h"
  fi

  if [ -x "${stage_root}/usr/local/bin/python${python_mm}" ]; then
    ln -sfn "python${python_mm}" "${stage_root}/usr/local/bin/python3"
    ln -sfn "python${python_mm}" "${stage_root}/usr/local/bin/python"
  fi

  if [ -x "${stage_root}/usr/local/bin/python${python_mm}-config" ]; then
    ln -sfn "python${python_mm}-config" "${stage_root}/usr/local/bin/python3-config"
  fi

  mkdir -p "${pkgconfig_dir}"
  if [ -f "${pkgconfig_dir}/python-${python_mm}.pc" ]; then
    ln -sfn "python-${python_mm}.pc" "${pkgconfig_dir}/python3.pc"
  fi
  if [ -f "${pkgconfig_dir}/python-${python_mm}-embed.pc" ]; then
    ln -sfn "python-${python_mm}-embed.pc" "${pkgconfig_dir}/python3-embed.pc"
  fi

  echo "Target Python ${python_mm} staged for ${target_arch}:"
  echo "  prefix: $(python_cross_stage_prefix_for_arch "${target_arch}")"
  echo "  include: ${stage_root}/usr/local/include/python${python_mm}"
  echo "  arch include: ${stage_root}/usr/local/include/${target_triplet}/python${python_mm}"
  echo "  libdir: ${stage_root}/usr/local/lib"
  echo "  pkg-config: ${pkgconfig_dir}"
}

stage_host_python_payload() {
  local target_arch="$1"
  local python_mm="${PYTHON_MAJOR_MINOR}"
  local stage_root
  local target_triplet

  stage_root="$(python_cross_stage_root_for_arch "${target_arch}")"
  target_triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")"

  rm -rf "${stage_root}"
  mkdir -p "${stage_root}/usr/local/bin" "${stage_root}/usr/local/lib" "${stage_root}/usr/local/include"

  cp -a "/usr/local/bin/python${python_mm}" "${stage_root}/usr/local/bin/"
  if [ -x "/usr/local/bin/python${python_mm}-config" ]; then
    cp -a "/usr/local/bin/python${python_mm}-config" "${stage_root}/usr/local/bin/"
  fi

  cp -a "/usr/local/lib/python${python_mm}" "${stage_root}/usr/local/lib/"
  cp -a "/usr/local/include/python${python_mm}" "${stage_root}/usr/local/include/"

  shopt -s nullglob
  cp -a /usr/local/lib/libpython"${python_mm}".so* "${stage_root}/usr/local/lib/"
  if [ -d "/usr/local/lib/pkgconfig" ]; then
    mkdir -p "${stage_root}/usr/local/lib/pkgconfig"
    cp -a /usr/local/lib/pkgconfig/python*.pc "${stage_root}/usr/local/lib/pkgconfig/" 2>/dev/null || true
  fi
  shopt -u nullglob

  python_stage_finalize "${target_arch}" "${stage_root}" "${python_mm}" "${target_triplet}"
}

build_cross_target_python_payload() {
  local source_dir="$1"
  local target_arch="$2"
  local python_mm="${PYTHON_MAJOR_MINOR}"
  local target_triplet build_triplet build_python_bin build_python_libdir
  local cross_build_dir config_site pkg_config_libdir stage_root
  local ext_build_dir

  target_triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")"
  build_triplet="$(build_deb_multiarch_triplet)"
  build_python_bin="/usr/local/bin/python${python_mm}"
  build_python_libdir="/usr/local/lib"
  cross_build_dir="/tmp/Python-${PYTHON_VERSION}-cross-${target_triplet}"
  config_site="/tmp/python-config-site-${target_triplet}"
  stage_root="$(python_cross_stage_root_for_arch "${target_arch}")"

  echo "Cross mode detected; building target Python ${python_mm} for ${target_arch} (${target_triplet})"

  if [ ! -x "${build_python_bin}" ]; then
    echo "Expected build Python ${build_python_bin} was not found" >&2
    exit 1
  fi

  prepare_cross_target_env "${target_arch}" "cross Python ${target_arch} staging"
  install_target_packages zlib1g-dev libbz2-dev liblzma-dev libzstd-dev libffi-dev libssl-dev 2>/dev/null || true
  pkg_config_libdir="$(cross_pkg_config_libdir "${target_triplet}")"
  export CFLAGS="${CFLAGS:--O2} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  export CPPFLAGS="${CPPFLAGS:-} -idirafter /usr/include -idirafter /usr/include/${target_triplet}"
  cat > "${config_site}" <<EOF
ac_cv_buggy_getaddrinfo=no
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_header_ffi_h=no
EOF

  rm -f "${source_dir}/Python/frozen_modules/"*.h "${source_dir}/Python/frozen_modules/MANIFEST"
  make -C "${source_dir}" clean 2>/dev/null || true
  rm -f "${source_dir}/pyconfig.h" "${source_dir}/Makefile" "${source_dir}/python" "${source_dir}/Modules/Setup.local"
  rm -rf "${cross_build_dir}" "${stage_root}"
  mkdir -p "${cross_build_dir}/Python/frozen_modules" "${stage_root}"

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
        --prefix=/usr/local \
        --with-build-python="${build_python_bin}" \
        --with-pkg-config=yes \
        --enable-shared \
        --without-ensurepip \
        --disable-test-modules
  )

  (
    cd "${cross_build_dir}"
    make -k -j"$(nproc)" 2>&1 || true
  )

  if [ ! -x "${cross_build_dir}/python" ] || [ ! -f "${cross_build_dir}/libpython${python_mm}.so.1.0" ]; then
    echo "ERROR: target Python cross build for ${target_arch} did not produce the critical binary or shared library" >&2
    exit 1
  fi

  # Stage the cross-built interpreter binary and libraries into the
  # per-architecture root. Do not run `make altinstall` because --
  # with-build-python already sets PYTHON_FOR_BUILD for compileall,
  # --without-ensurepip removes the pip bootstrap, and the target
  # Python binary itself cannot execute on the build host without
  # QEMU. Copying from the build tree is deterministic and avoids
  # depending on HOSTRUNNER availability in the container.

  mkdir -p "${stage_root}/usr/local/bin" "${stage_root}/usr/local/lib" "${stage_root}/usr/local/include"

  if [ -x "${cross_build_dir}/python" ]; then
    cp -a "${cross_build_dir}/python" "${stage_root}/usr/local/bin/python${python_mm}"
  else
    echo "Expected cross-built python binary was not produced in ${cross_build_dir}" >&2
    exit 1
  fi

  shopt -s nullglob
  cp -a "${cross_build_dir}"/libpython"${python_mm}".so* "${stage_root}/usr/local/lib/"
  shopt -u nullglob

  if [ ! -f "${stage_root}/usr/local/lib/libpython${python_mm}.so.1.0" ] && \
     [ ! -f "${stage_root}/usr/local/lib/libpython${python_mm}.so" ]; then
    echo "Expected cross-built libpython${python_mm}.so was not produced" >&2
    exit 1
  fi

  cp -a "${source_dir}/Include/." "${stage_root}/usr/local/include/python${python_mm}/"
  cp -a "${cross_build_dir}/pyconfig.h" "${stage_root}/usr/local/include/python${python_mm}/pyconfig.h"

  cp -a "${source_dir}/Lib/." "${stage_root}/usr/local/lib/python${python_mm}/"

  for ext_build_dir in "${cross_build_dir}/build/lib.linux"*; do
    if [ -d "${ext_build_dir}" ]; then
      mkdir -p "${stage_root}/usr/local/lib/python${python_mm}/lib-dynload"
      cp -a "${ext_build_dir}/"* "${stage_root}/usr/local/lib/python${python_mm}/lib-dynload/"
    fi
  done

  mkdir -p "${stage_root}/usr/local/lib/pkgconfig"
  if [ -f "${cross_build_dir}/Misc/python.pc" ]; then
    cp -a "${cross_build_dir}/Misc/python.pc" "${stage_root}/usr/local/lib/pkgconfig/python-${python_mm}.pc"
  else
    echo "Expected cross-built python-${python_mm}.pc was not produced" >&2
    exit 1
  fi

  if [ -f "${cross_build_dir}/Misc/python-embed.pc" ]; then
    cp -a "${cross_build_dir}/Misc/python-embed.pc" "${stage_root}/usr/local/lib/pkgconfig/python-${python_mm}-embed.pc"
  fi

  python_stage_finalize "${target_arch}" "${stage_root}" "${python_mm}" "${target_triplet}"
}

stage_requested_cross_python_payloads() {
  local raw_targets=""
  local normalized_targets=""
  local build_arch=""
  local target_arch=""

  if [ "${BUILD_MODE:-native}" != "cross" ]; then
    return 0
  fi

  raw_targets="$(cross_targets_effective_raw 2>/dev/null || printf '%s' "${CROSS_TARGETS:-}")"
  [ -n "${raw_targets}" ] || return 0

  normalized_targets="$(arch_list_csv_normalize "${raw_targets}")" || {
    echo "Unsupported cross target list for Python staging: ${raw_targets}" >&2
    exit 1
  }
  build_arch="$(build_arch_oci 2>/dev/null || arch_oci)"

  rm -rf "${PYTHON_CROSS_STAGE_ROOT}"
  mkdir -p "${PYTHON_CROSS_STAGE_ROOT}"

  for target_arch in ${normalized_targets//,/ }; do
    if [ "${target_arch}" = "${build_arch}" ]; then
      stage_host_python_payload "${target_arch}"
    else
      build_cross_target_python_payload "${PYTHON_SOURCE_DIR}" "${target_arch}"
    fi
  done
}

echo "Building Python ${PYTHON_VERSION} from source..."

if [ "${BUILD_MODE:-native}" = "cross" ]; then
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

stage_requested_cross_python_payloads

# Clean up
cd /
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Python ${PYTHON_VERSION} built and installed successfully."
