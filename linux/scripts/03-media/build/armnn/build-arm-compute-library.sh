#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

ACL_VERSION="${ACL_VERSION:-v53.2.0}"
ACL_REPO="${ACL_REPO:-https://github.com/ARM-software/ComputeLibrary.git}"
ACL_SRC_DIR="${ACL_SRC_DIR:-/tmp/acl-src}"
ACL_INSTALL_DIR="${ACL_INSTALL_DIR:-/opt/acl}"
ACL_BUILD_DIR="${ACL_BUILD_DIR:-${ACL_SRC_DIR}/build}"

ARCH="${TARGET_ARCH:-${TARGETARCH:-$(uname -m)}}"

clone_acl() {
  retry 3 10 "ACL git clone" clone_or_update_repo "${ACL_REPO}" "${ACL_SRC_DIR}" "${ACL_VERSION}"
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

  if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${ARCH}" != "amd64" ]; then
    local cross_prefix
    case "${ARCH}" in
      arm64|aarch64) cross_prefix="aarch64-linux-gnu-" ;;
      *) die "No cross prefix for ${ARCH}" ;;
    esac
    export CC="${cross_prefix}gcc"
    export CXX="${cross_prefix}g++"
  fi

  # scons defaults to -j1; media_jobs caps the count by memory because ACL's C++ is RAM-heavy.
  local acl_jobs
  acl_jobs="$(media_jobs)"
  info "Building ACL with -j${acl_jobs}"

  scons -j "${acl_jobs}" Werror=0 \
    ${arch_flag} \
    build="native" \
    neon=1 \
    opencl=1 \
    examples=0 \
    benchmark_tests=0 \
    validation_tests=0 \
    "${@}"

  mkdir -p "${ACL_INSTALL_DIR}/lib" "${ACL_INSTALL_DIR}/include"
  # A build may yield only .so or only .a, so each copy may miss; the checks below verify the install as a whole.
  cp -a build/*.so "${ACL_INSTALL_DIR}/lib/" 2>/dev/null || true
  cp -a build/*.a "${ACL_INSTALL_DIR}/lib/" 2>/dev/null || true
  cp -a include/* "${ACL_INSTALL_DIR}/include/" 2>/dev/null || true
  cp -a arm_compute "${ACL_INSTALL_DIR}/include/" 2>/dev/null || true

  ls "${ACL_INSTALL_DIR}/lib/"libarm_compute* >/dev/null 2>&1 \
    || die "ACL install verification failed: no libarm_compute* in ${ACL_INSTALL_DIR}/lib"
  [ -d "${ACL_INSTALL_DIR}/include/arm_compute" ] \
    || die "ACL install verification failed: arm_compute headers missing from ${ACL_INSTALL_DIR}/include"

  info "ACL installed to ${ACL_INSTALL_DIR}"
  # Best-effort strip of the dedicated prefix; MEDIA_STRIP=0 disables it inside the helper.
  declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${ACL_INSTALL_DIR}" || true
  ls -la "${ACL_INSTALL_DIR}/lib/" | head -10
}

main() {
  clone_acl
  build_acl "$@"
}

main "$@"
