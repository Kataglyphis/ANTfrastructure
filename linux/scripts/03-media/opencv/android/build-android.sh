#!/usr/bin/env bash
set -euxo pipefail

is_x86_64() {
  local arch="${TARGETARCH:-$(uname -m)}"
  case "${arch}" in amd64|x86_64) return 0 ;; *) return 1 ;; esac
}

if ! is_x86_64; then
  echo "Skipping Android OpenCV build on non-x86_64 architecture"
  exit 0
fi

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
  -DANDROID_ABI="arm64-v8a" \
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
