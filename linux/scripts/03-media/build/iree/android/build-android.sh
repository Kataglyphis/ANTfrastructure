#!/usr/bin/env bash
set -euo pipefail

# Non-gating: this cross-build is unvalidated, so every failure warns and exits 0 rather than failing the android image.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"

warn() { printf 'WARNING: %s\n' "$*" >&2; }

android_build_preamble_init "Android IREE build" "${ANDROID_API_LEVEL:-34}"

# No inline default: a literal would hide an ARG that Dockerfile.android failed to forward.
IREE_VERSION="${IREE_VERSION:-${1:?IREE_VERSION not forwarded into the android stage (see Dockerfile.android ARG/ENV) and no version given as $1}}"
INSTALL_DIR="${IREE_ROOT_ANDROID:-/opt/android/iree}"
: "${CMAKE_POLICY_VERSION_MINIMUM:=3.5}"

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

apt-get update && apt-get install -y --no-install-recommends \
    g++ git cmake ninja-build python3 python3-pip \
  || { warn "Android IREE: apt deps install failed; skipping (non-gating)"; exit 0; }

# Skip the compiler-only submodules; the runtime never needs them and torch-mlir drags in a second llvm-project.
cd /opt
rm -rf iree-android
git clone --depth 1 -b "${IREE_VERSION}" https://github.com/iree-org/iree.git iree-android \
  || { warn "Android IREE: clone ${IREE_VERSION} failed; skipping (non-gating)"; exit 0; }
( cd iree-android && git \
    -c submodule."third_party/llvm-project".update=none \
    -c submodule."third_party/torch-mlir".update=none \
    -c submodule."third_party/stablehlo".update=none \
    submodule update --init --recursive --depth 1 ) \
  || { warn "Android IREE: submodule init failed; skipping (non-gating)"; exit 0; }

HOST_CC="$(resolve_host_compiler c)"
HOST_CXX="$(resolve_host_compiler cxx)"
PARALLEL_JOBS="$(media_jobs)"

# Stage 1 — LLVM-free host tools for IREE_HOST_BIN_DIR.
HOST_BUILD=/opt/iree-android/build-host
HOST_INSTALL="${HOST_BUILD}/install"
cmake -GNinja -S /opt/iree-android -B "${HOST_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DIREE_BUILD_COMPILER=OFF \
    -DIREE_BUILD_PYTHON_BINDINGS=OFF \
    -DIREE_BUILD_SAMPLES=OFF \
    -DIREE_BUILD_TESTS=OFF \
    -DCMAKE_C_COMPILER="${HOST_CC}" \
    -DCMAKE_CXX_COMPILER="${HOST_CXX}" \
    -DCMAKE_INSTALL_PREFIX="${HOST_INSTALL}" \
  || { warn "Android IREE: host-tools configure failed; skipping (non-gating)"; exit 0; }
cmake --build "${HOST_BUILD}" --target install -- -j"${PARALLEL_JOBS}" \
  || { warn "Android IREE: host-tools build failed; skipping (non-gating)"; exit 0; }

# Stage 2 — cross the runtime for Android against the host tools.
TARGET_BUILD=/opt/iree-android/build-android
cmake -GNinja -S /opt/iree-android -B "${TARGET_BUILD}" \
    -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${ANDROID_ABI}" \
    -DANDROID_PLATFORM="android-${ANDROID_API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM} \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DIREE_HOST_BIN_DIR="${HOST_INSTALL}/bin" \
    -DIREE_BUILD_COMPILER=OFF \
    -DIREE_BUILD_PYTHON_BINDINGS=OFF \
    -DIREE_BUILD_SAMPLES=OFF \
    -DIREE_BUILD_TESTS=OFF \
    -DIREE_HAL_DRIVER_LOCAL_SYNC=ON \
    -DIREE_HAL_DRIVER_LOCAL_TASK=ON \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  || { warn "Android IREE: target configure failed; skipping (non-gating)"; exit 0; }
ninja -C "${TARGET_BUILD}" -j"${PARALLEL_JOBS}" install \
  || cmake --build "${TARGET_BUILD}" --target install -j1 \
  || { warn "Android IREE: target build/install failed; skipping (non-gating)"; exit 0; }

echo "Android IREE runtime installed into ${INSTALL_DIR} (ABI ${ANDROID_ABI}, API ${ANDROID_API_LEVEL}; compiler intentionally not built)"

cd /opt
rm -rf iree-android
