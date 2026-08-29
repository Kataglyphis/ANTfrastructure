#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

ARMNN_VERSION="${ARMNN_VERSION:-v26.07}"
ARMNN_REPO="${ARMNN_REPO:-https://github.com/ARM-software/armnn.git}"
ARMNN_SRC_DIR="${ARMNN_SRC_DIR:-/tmp/armnn-src}"
ARMNN_INSTALL_DIR="${ARMNN_INSTALL_DIR:-/opt/armnn}"
ARMNN_BUILD_DIR="${ARMNN_BUILD_DIR:-${ARMNN_SRC_DIR}/build}"
ACL_INSTALL_DIR="${ACL_INSTALL_DIR:-/opt/acl}"

ARCH="${TARGET_ARCH:-${TARGETARCH:-$(uname -m)}}"

clone_armnn() {
  # Shared shallow-clone helper (same one litert/opencv/libcamera use); submodule
  # sync runs in a subshell so it never leaks cwd (build_armnn cds itself).
  retry 3 10 "Arm NN git clone" clone_or_update_repo "${ARMNN_REPO}" "${ARMNN_SRC_DIR}" "${ARMNN_VERSION}"
  ( cd "${ARMNN_SRC_DIR}" && git submodule update --init --recursive )
}

build_armnn() {
  info "Building Arm NN for ${ARCH}"

  # libgomp.so dev symlink: libgomp1:<arch> ships only libgomp.so.1, and the
  # cross toolchain has no target libgomp. Create the dev symlink here too
  # (not just in install-deps.sh) in case the install-deps layer is cached
  # from before the fix.
  if [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then
    local _gdir="/usr/lib/aarch64-linux-gnu"
    if [ -d "${_gdir}" ] && [ ! -e "${_gdir}/libgomp.so" ] && [ -e "${_gdir}/libgomp.so.1" ]; then
      ln -sf libgomp.so.1 "${_gdir}/libgomp.so"
      info "Created ${_gdir}/libgomp.so -> libgomp.so.1"
    fi
  fi

  local cross_args=()
  if [ "${BUILD_MODE:-native}" = "cross" ] && [ "${ARCH}" != "amd64" ]; then
    if command -v append_cmake_cross_args >/dev/null 2>&1; then
      # Canonical cross toolchain args (same helper opencv/litert/onnx use).
      append_cmake_cross_args cross_args
    else
      # Fallback: hand-rolled cross toolchain args (pre-helper environments).
      local cross_prefix triplet
      case "${ARCH}" in
        arm64|aarch64)
          cross_prefix="aarch64-linux-gnu"
          triplet="aarch64-linux-gnu"
          ;;
        *) die "No cross config for ${ARCH}" ;;
      esac
      cross_args=(
        -DCMAKE_C_COMPILER="${cross_prefix}-gcc"
        -DCMAKE_CXX_COMPILER="${cross_prefix}-g++"
        -DCMAKE_FIND_ROOT_PATH="/usr/${triplet}"
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
      )
    fi

    # ArmNN's CMakeLists.txt hardcodes target_link_libraries(armnn -lgomp)
    # (OpenMP, BUILD_ACL_OPENMP=ON). The cross GCC's default ld.lld search
    # paths don't include /usr/lib/<triplet>/ where libgomp.so lives. Adding
    # -L/usr/lib/<triplet> causes ld.lld to find an incompatible libstdc++.so
    # there. Instead, symlink libgomp.so into the GCC's own lib dir which the
    # linker already searches by default — no -L needed.
    local _tri _libdir _gcc_libdir
    _tri="$(cross_target_triplet 2>/dev/null || true)"
    _libdir="/usr/lib/${_tri}"
    _gcc_libdir="/opt/gcc-${GCC_VERSION:-16.2.0}/${_tri}/lib"
    if [ -n "${_tri}" ] && [ -d "${_libdir}" ] && [ -d "${_gcc_libdir}" ]; then
      if [ -e "${_libdir}/libgomp.so.1" ] && [ ! -e "${_gcc_libdir}/libgomp.so" ]; then
        ln -sf "${_libdir}/libgomp.so.1" "${_gcc_libdir}/libgomp.so"
        info "Symlinked ${_gcc_libdir}/libgomp.so -> ${_libdir}/libgomp.so.1"
      fi
    fi
  fi

  mkdir -p "${ARMNN_BUILD_DIR}"
  cd "${ARMNN_BUILD_DIR}"

  # Arm NN v25.11+ probes ACL's CMake package config directly (installed by
  # scons into ACL_BUILD_DIR). ARMCOMPUTE_ROOT points to the ACL build tree
  # which contains the generated cmake files and arm_compute_version.h.
  # GCC 16.1.0's -Werror=array-bounds triggers false positives on std::mutex
  # placement in ACL/Arm NN buffers; suppress to avoid build failure.
  #
  # LOG12 (2026-08-28): NEON backend ENABLED. CL stays OFF — no GPU device in
  # the cross-build container, and OpenCL headers/libs are not staged for
  # cross. If a consumer needs ArmNN CL, stage the OpenCL headers and pass
  # -DARMCOMPUTECL=1. TOSA Reference stays OFF (upstream default).
  cmake "${ARMNN_SRC_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${ARMNN_INSTALL_DIR}" \
    -DARMCOMPUTE_ROOT="${ACL_SRC_DIR:-/tmp/acl-src}" \
    -DARMCOMPUTE_BUILD_DIR="${ACL_SRC_DIR:-/tmp/acl-src}/build" \
    -DARMCOMPUTE_LIBS="${ACL_INSTALL_DIR}/lib" \
    -DARMCOMPUTE_LIBRARIES="${ACL_INSTALL_DIR}/lib/libarm_compute.so" \
    -DARMCOMPUTENEON=1 \
    -DBUILD_UNIT_TESTS=0 \
    -DBUILD_TESTS=0 \
    -DBUILD_BENCHMARK_TESTS=0 \
    -DBUILD_BENCHMARK_EXECUTABLE=0 \
    -DCMAKE_CXX_FLAGS="-Wno-array-bounds" \
    -DCMAKE_C_FLAGS="-Wno-array-bounds" \
    "${cross_args[@]}"

  cmake --build . -j"$(media_jobs)"
  cmake --install .

  info "Arm NN installed to ${ARMNN_INSTALL_DIR}"
  # AP4: strip Arm NN's libs (dedicated /opt/armnn prefix). strip_media_prefixes
  # self-derives the cross <triplet>-strip; --strip-all keeps .dynsym.
  # Best-effort, MEDIA_STRIP=0 disables. arm64-only lane.
  # DUPN1: MEDIA_STRIP gate lives inside the helper now.
  declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${ARMNN_INSTALL_DIR}" || true
  ls -la "${ARMNN_INSTALL_DIR}/lib/" 2>/dev/null | head -10 || true
}

main() {
  if [ "${ARCH}" != "arm64" ] && [ "${ARCH}" != "aarch64" ]; then
    info "Arm NN is only built for arm64; skipping on ${ARCH}"
    exit 0
  fi
  clone_armnn
  build_armnn "$@"
}

main "$@"
