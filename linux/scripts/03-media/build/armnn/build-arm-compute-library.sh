#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

ACL_VERSION="${ACL_VERSION:-v25.04}"
ACL_REPO="${ACL_REPO:-https://github.com/ARM-software/ComputeLibrary.git}"
ACL_SRC_DIR="${ACL_SRC_DIR:-/tmp/acl-src}"
ACL_INSTALL_DIR="${ACL_INSTALL_DIR:-/opt/acl}"
ACL_BUILD_DIR="${ACL_BUILD_DIR:-${ACL_SRC_DIR}/build}"

ARCH="${TARGET_ARCH:-${TARGETARCH:-$(uname -m)}}"

clone_acl() {
  if [ ! -d "${ACL_SRC_DIR}" ]; then
    info "Cloning Arm Compute Library ${ACL_VERSION} into ${ACL_SRC_DIR}"
    git clone --branch "${ACL_VERSION}" --depth 1 "${ACL_REPO}" "${ACL_SRC_DIR}"
  else
    info "ACL source already exists at ${ACL_SRC_DIR}"
  fi
}

build_acl() {
  info "Building Arm Compute Library for ${ARCH}"

  local arch_flag
  case "${ARCH}" in
    arm64|aarch64) arch_flag="arch=arm64-v8a" ;;
    amd64|x86_64)  arch_flag="arch=x86_64" ;;
    *) die "Unsupported ACL architecture: ${ARCH}" ;;
  esac

  cd "${ACL_SRC_DIR}"

  local build_toolchain="GCC"
  if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${ARCH}" != "amd64" ]; then
    local cross_prefix
    case "${ARCH}" in
      arm64|aarch64) cross_prefix="aarch64-linux-gnu-" ;;
      *) die "No cross prefix for ${ARCH}" ;;
    esac
    export CC="${cross_prefix}gcc"
    export CXX="${cross_prefix}g++"
    build_toolchain="GCC"
  fi

  scons Werror=0 \
    ${arch_flag} \
    build="native" \
    neon=1 \
    opencl=1 \
    examples=0 \
    benchmark_tests=0 \
    validation_tests=0 \
    "${@}"

  mkdir -p "${ACL_INSTALL_DIR}/lib" "${ACL_INSTALL_DIR}/include"
  cp -a build/*.so "${ACL_INSTALL_DIR}/lib/" 2>/dev/null || true
  cp -a build/*.a "${ACL_INSTALL_DIR}/lib/" 2>/dev/null || true
  cp -a include/* "${ACL_INSTALL_DIR}/include/" 2>/dev/null || true
  cp -a arm_compute "${ACL_INSTALL_DIR}/include/" 2>/dev/null || true

  info "ACL installed to ${ACL_INSTALL_DIR}"
  ls -la "${ACL_INSTALL_DIR}/lib/" | head -10
}

main() {
  clone_acl
  build_acl "$@"
}

main "$@"
