#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"
android_build_preamble_init "Android OpenCV build" "${ANDROID_API_LEVEL:-34}"

# Env first, since android-dispatch.sh passes no arguments; the default is versions.env's release tag, not the 5.x branch.
OPENCV_VERSION="${OPENCV_VERSION:-${1:-5.0.0}}"
INSTALL_DIR="${OPENCV_ROOT_ANDROID:-/opt/android/opencv}"

apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 openjdk-21-jdk ant

android_clone_shallow "https://github.com/opencv/opencv.git" "${OPENCV_VERSION}" opencv-android

# OpenCV 5.0 always adds samples/, whose add_android_project is undefined with BUILD_ANDROID_PROJECTS=OFF.
rm -rf samples/android samples/cpp samples/python samples/java samples/cpp
mkdir -p samples
cat > samples/CMakeLists.txt <<'EOF'
# Stub: samples disabled for cross-compile Android build
EOF

# Same MLAS stub as build-opencv.sh; see docs/upstreamable-patches.md § 6.
android_apply_patch \
  "opencv/001-mlas-hgemm-supported-stub.patch" \
  "$(pwd)" \
  "OpenCV MLAS MlasHGemmSupported stub for MLAS_GEMM_ONLY"

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"
: "${ANDROID_HOME:?ANDROID_HOME must be set}"

# The NDK's clang rejects OpenCV's by-copy lambda capture of sizeless RVV types, which Linux GCC accepts.
declare -a OPENCV_ANDROID_EXTRA_ARGS=()
case "${ANDROID_ABI}" in
  riscv64)
    OPENCV_ANDROID_EXTRA_ARGS+=( -DWITH_HAL_RVV=OFF -DCPU_BASELINE_DISABLE=RVV )
    ;;
esac

mkdir -p build-android && cd build-android
cmake -GNinja \
  -DCMAKE_TOOLCHAIN_FILE="${ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="${ANDROID_ABI}" \
  -DANDROID_PLATFORM="android-${ANDROID_API_LEVEL}" \
  -DANDROID_SDK="${ANDROID_HOME}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_JAVA=OFF \
  -DBUILD_ANDROID_PROJECTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_samples=OFF \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  "${OPENCV_ANDROID_EXTRA_ARGS[@]}" \
  ..

PARALLEL_JOBS="$(media_jobs)"
ninja -j"${PARALLEL_JOBS}" install || cmake --build . --target install -j1

cd /opt
rm -rf opencv-android
