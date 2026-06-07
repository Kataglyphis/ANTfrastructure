#!/usr/bin/env bash
set -euxo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

if ! android_require_amd64_build_host "Android OpenCV build"; then
  exit 0
fi

TARGET_ARCH="$(android_target_arch)"
ANDROID_ABI="$(android_target_abi)"
: "${ANDROID_ABI:?Unsupported Android target ABI}"

OPENCV_VERSION="${1:-5.x}"
ANDROID_API_LEVEL="$(android_raise_api_level_if_needed "${TARGET_ARCH}" "${ANDROID_API_LEVEL:-34}" "Android OpenCV build")"
INSTALL_DIR="${OPENCV_ROOT_ANDROID:-/opt/android/opencv}"

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 openjdk-21-jdk ant

cd /opt
rm -rf opencv-android
git clone --depth 1 -b ${OPENCV_VERSION} https://github.com/opencv/opencv.git opencv-android
cd opencv-android

# Same MLAS stub fix as in build-opencv.sh: MlasHGemmSupported is declared
# but never defined in vendored MLAS when MLAS_GEMM_ONLY=1.
mlas_compute="3rdparty/mlas/lib/compute.cpp"
if [ -f "${mlas_compute}" ] && ! grep -Fq 'MLAS_GEMM_ONLY stub' "${mlas_compute}"; then
    echo "Patching vendored MLAS: adding MlasHGemmSupported stub for MLAS_GEMM_ONLY"
    cat >> "${mlas_compute}" <<'MLAS_STUB_EOF'

#ifdef MLAS_GEMM_ONLY
// MLAS_GEMM_ONLY stub
MLASCALL
bool
MlasHGemmSupported(
    CBLAS_TRANSPOSE TransA,
    CBLAS_TRANSPOSE TransB
    )
{
    (void)TransA;
    (void)TransB;
    return false;
}
#endif
MLAS_STUB_EOF
    echo "OpenCV MLAS stub patch applied (Android)"
fi

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"
: "${ANDROID_HOME:?ANDROID_HOME must be set}"

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
  -DBUILD_JAVA=ON \
  -DBUILD_ANDROID_PROJECTS=OFF \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  ..

ninja -j"$(nproc)" install || cmake --build . --target install -j1

cd /opt
rm -rf opencv-android
