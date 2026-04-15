#!/usr/bin/env bash
set -euxo pipefail

is_x86_64() {
  local arch="${TARGETARCH:-$(uname -m)}"
  case "${arch}" in amd64|x86_64) return 0 ;; *) return 1 ;; esac
}

if ! is_x86_64; then
  echo "Skipping Android LiteRT build on non-x86_64 architecture"
  exit 0
fi

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
  -DANDROID_ABI="arm64-v8a" \
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
