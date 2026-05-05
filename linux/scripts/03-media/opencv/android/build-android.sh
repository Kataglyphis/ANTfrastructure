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
  echo "Skipping Android OpenCV build on non-amd64 build host"
  exit 0
fi

ANDROID_ABI="$(android_abi)"
: "${ANDROID_ABI:?Unsupported Android target ABI}"

OPENCV_VERSION="${1:-4.11.0}"
INSTALL_DIR="/opt/android/opencv"

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 openjdk-21-jdk ant

cd /opt
rm -rf opencv-android
git clone --depth 1 -b ${OPENCV_VERSION} https://github.com/opencv/opencv.git opencv-android
cd opencv-android

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"
: "${ANDROID_HOME:?ANDROID_HOME must be set}"

mkdir -p build-android && cd build-android
cmake -GNinja \
  -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="${ANDROID_ABI}" \
  -DANDROID_PLATFORM="android-34" \
  -DANDROID_SDK="${ANDROID_HOME}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_JAVA=ON \
  -DBUILD_ANDROID_PROJECTS=OFF \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  ..

ninja -j"$(nproc)" install || cmake --build . --target install -j1

cd /opt
rm -rf opencv-android
