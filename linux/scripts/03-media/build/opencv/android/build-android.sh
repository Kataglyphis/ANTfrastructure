#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"
android_build_preamble_init "Android OpenCV build" "${ANDROID_API_LEVEL:-34}"

# Env-first like the litert/iree/onnxruntime siblings (android-dispatch.sh
# passes no arguments, so `${1:-...}` alone always took the literal). Inline
# default mirrors versions.env OPENCV_VERSION — the released 5.0.0 TAG, not
# the moving 5.x branch (which made the android OpenCV non-reproducible and
# of different provenance than the chain's /opt/opencv5).
OPENCV_VERSION="${OPENCV_VERSION:-${1:-5.0.0}}"
INSTALL_DIR="${OPENCV_ROOT_ANDROID:-/opt/android/opencv}"

apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 openjdk-21-jdk ant

android_clone_shallow "https://github.com/opencv/opencv.git" "${OPENCV_VERSION}" opencv-android

# OpenCV 5.0's root CMakeLists.txt unconditionally add_subdirectory(samples),
# and samples/CMakeLists.txt calls add_android_project — a function undefined
# when BUILD_ANDROID_PROJECTS=OFF. Replacing samples/CMakeLists.txt with a
# stub makes the subdirectory a no-op.
rm -rf samples/android samples/cpp samples/python samples/java samples/cpp
mkdir -p samples
cat > samples/CMakeLists.txt <<'EOF'
# Stub: samples disabled for cross-compile Android build
EOF

# Same MLAS stub fix as build-opencv.sh via the canonical patch in
# patches/opencv/001-mlas-hgemm-supported-stub.patch. apply-patch.sh is
# idempotent (skips if already applied via reverse-check), so re-runs stay safe.
android_apply_patch \
  "opencv/001-mlas-hgemm-supported-stub.patch" \
  "$(pwd)" \
  "OpenCV MLAS MlasHGemmSupported stub for MLAS_GEMM_ONLY"

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"
: "${ANDROID_HOME:?ANDROID_HOME must be set}"

# OpenCV 5.x RVV handling for the riscv64 Android ABI. The baseline universal-
# intrinsic sources (e.g. modules/imgproc/src/thresh.cpp) capture sizeless RVV
# types (__rvv_uint16m2_t, ...) by-copy inside lambdas. The Android NDK's clang
# rejects that ("by-copy capture of variable with sizeless type"), whereas the
# Linux riscv64 build (GCC 16) tolerates it — so this is an Android/clang-only
# breakage. Drop RVV from the CPU baseline + disable the RVV HAL for the riscv64
# ABI so those paths fall back to scalar. Other ABIs (arm64-v8a, x86_64) have no
# RVV and are unaffected. NOTE: the Linux riscv64 OpenCV also ships WITHOUT RVV
# (media-riscv64.log: HAVE_CPU_RVV_SUPPORT - Failed) — it sets neither
# CPU_BASELINE nor WITH_HAL_RVV, and the comment that previously said "keeps
# RVV under GCC" here was false. See backlog LOG10.
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
