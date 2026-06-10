#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"
android_build_preamble_init "Android OpenCV build" "${ANDROID_API_LEVEL:-34}"

OPENCV_VERSION="${1:-5.x}"
INSTALL_DIR="${OPENCV_ROOT_ANDROID:-/opt/android/opencv}"

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

PARALLEL_JOBS="$(nproc)"
if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    PARALLEL_JOBS="$(compute_jobs_with_mem_cap "" 2000)"
  fi
fi
ninja -j"${PARALLEL_JOBS}" install || cmake --build . --target install -j1

cd /opt
rm -rf opencv-android
