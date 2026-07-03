#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../android-build-preamble.sh"
android_build_preamble_init "Android ONNX Runtime build" "${ANDROID_API_LEVEL:-34}"

case "${TARGET_ARCH}" in
  riscv64|riscv|rv64*)
    echo "Skipping Android ONNX Runtime build for riscv64 because upstream build.sh does not support that Android ABI"
    exit 0
    ;;
esac

ORT_VERSION="${1:-${ONNXRUNTIME_VERSION:-v1.27.0}}"
INSTALL_DIR="${ONNXRUNTIME_ROOT_ANDROID:-/opt/android/onnxruntime}"

apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build python3 python3-pip openjdk-21-jdk curl

PARALLEL_JOBS="$(nproc)"
if [ -f /opt/scripts/core/parallelism.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/parallelism.sh 2>/dev/null || true
  if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
    PARALLEL_JOBS="$(compute_jobs_with_mem_cap "" 2000)"
  fi
fi

cd /opt
rm -rf onnxruntime-android
git clone --depth 1 -b ${ORT_VERSION} https://github.com/microsoft/onnxruntime.git onnxruntime-android
cd onnxruntime-android

# Patch Android Gradle Plugin 7.4.2 -> 8.3.1 (JDK 21) and re-enable buildConfig
_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
bash "${_scripts_dir}/01-core/apply-patch.sh" \
  "${_scripts_dir}/patches/onnxruntime/001-android-gradle-agp8-compat.patch" \
  "$(pwd)" \
  "ONNX Runtime Android Gradle AGP 8 compat"

: "${ANDROID_HOME:?ANDROID_HOME must be set}"
: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must be set}"

./build.sh \
  --allow_running_as_root \
  --android \
  --android_sdk_path "${ANDROID_HOME}" \
  --android_ndk_path "${ANDROID_NDK_HOME}" \
  --android_abi "${ANDROID_ABI}" \
  --android_api "${ANDROID_API_LEVEL}" \
  --build_java \
  --build_shared_lib \
  --config Release \
  --parallel "$PARALLEL_JOBS" \
  --skip_tests \
  --use_nnapi \
  --use_xnnpack \
  --update \
  --build

mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/include" "${INSTALL_DIR}/java"
# The headers always exist in the source tree — a failed copy here is a real
# error, not an optional step.
cp -r include/* "${INSTALL_DIR}/include/"
find build/Android/Release -name "libonnxruntime*.so" -print0 | xargs -0 -r cp -t "${INSTALL_DIR}/lib/"
find build/Android/Release -name "*.aar" -print0 | xargs -0 -r cp -t "${INSTALL_DIR}/java/"

# Verify the install actually landed before deleting the build tree — these
# copies failing silently used to produce an "installed" stage with no library.
ls "${INSTALL_DIR}/lib/"libonnxruntime*.so >/dev/null 2>&1 \
  || { echo "ERROR: no libonnxruntime*.so under ${INSTALL_DIR}/lib after build (--build_shared_lib output missing)" >&2; exit 1; }
ls "${INSTALL_DIR}/java/"*.aar >/dev/null 2>&1 \
  || { echo "ERROR: no .aar under ${INSTALL_DIR}/java after build (--build_java output missing)" >&2; exit 1; }

cd /opt
rm -rf onnxruntime-android
