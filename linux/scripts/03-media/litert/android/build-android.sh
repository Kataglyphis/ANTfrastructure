#!/usr/bin/env bash
set -euxo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

build_arch() {
  if command -v build_arch_oci >/dev/null 2>&1; then
    build_arch_oci
    return 0
  fi
  if [ -n "${BUILDARCH:-}" ]; then
    printf '%s' "${BUILDARCH}"
    return 0
  fi
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture 2>/dev/null && return 0
  fi
  uname -m || true
}

android_abi() {
  if command -v android_abi_for_target >/dev/null 2>&1; then
    android_abi_for_target
    return 0
  fi
  case "${TARGET_ARCH:-${TARGETARCH:-arm64}}" in
    amd64|x86_64) printf '%s' "x86_64" ;;
    arm64|aarch64) printf '%s' "arm64-v8a" ;;
    386|i386|i686|x86) printf '%s' "x86" ;;
    riscv64|riscv|rv64*) printf '%s' "riscv64" ;;
    *) printf '%s' "" ;;
  esac
}

if [ "$(build_arch)" != "amd64" ]; then
  echo "Skipping Android LiteRT build on non-amd64 build host"
  exit 0
fi

ANDROID_ABI="$(android_abi)"
: "${ANDROID_ABI:?Unsupported Android target ABI}"

LITERT_VERSION="${1:-v2.1.4}"
INSTALL_DIR="/opt/android/litert"

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 python3-pip

cd /opt
rm -rf litert-android
git clone --depth 1 -b ${LITERT_VERSION} https://github.com/google-ai-edge/LiteRT.git litert-android
cd litert-android

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

mkdir -p litert/build-android && cd litert/build-android
cmake -GNinja \
  -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="${ANDROID_ABI}" \
  -DANDROID_PLATFORM="android-34" \
  -DCMAKE_BUILD_TYPE=Release \
  -DTFLITE_ENABLE_XNNPACK=ON \
  -DTFLITE_ENABLE_RUY=ON \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DRUY_PROFILER=0 \
  -DRUY_ENABLE_INSTRUMENTATION=OFF \
  -DRUY_PROFILER_INSTRUMENTATION=OFF \
  -DRUY_BUILD_TOOLS=OFF \
  -DRUY_BUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  ..

ninja -j"$(nproc)" install || cmake --build . --target install -j1

cd /opt
rm -rf litert-android
