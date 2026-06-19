#!/usr/bin/env bash
set -euo pipefail
# verify-media-artifacts.sh
# Validates that each media build stage produced actual output before the next
# stage consumes it.  Called from Dockerfile.media RUN steps after each library
# build completes.
#
# Usage:
#   verify-media-artifacts.sh <stage> [prefix_dir]
#
# Stages: onnxruntime-cpu, onnxruntime-genai, onnxruntime-gpu, litert, litert-headers,
#         opencv, opencv-core, ffmpeg, gstreamer, libcamera, app-wheels

STAGE="${1:-}"
PREFIX="${2:-}"

fail_check() {
  echo "FAIL [${STAGE}]: $*" >&2
  FAILURES=$((FAILURES + 1))
}

pass_check() {
  echo "OK   [${STAGE}]: $*" >&2
}

FAILURES=0

verify_dir_not_empty() {
  local dir="$1"
  local label="${2:-directory}"

  if [ ! -d "${dir}" ]; then
    fail_check "${label} not found: ${dir}"
    return 1
  fi
  if [ -z "$(ls -A "${dir}" 2>/dev/null || true)" ]; then
    fail_check "${label} is empty: ${dir}"
    return 1
  fi
  return 0
}

verify_file_exists() {
  local file="$1"
  local label="${2:-file}"

  if [ ! -f "${file}" ] && [ ! -L "${file}" ]; then
    fail_check "${label} not found: ${file}"
    return 1
  fi
  if [ ! -s "${file}" ]; then
    fail_check "${label} is empty: ${file}"
    return 1
  fi
  return 0
}

verify_shared_lib() {
  local dir="$1"
  local glob_pattern="$2"
  local label="${3:-shared library}"

  local found=""
  found="$(find "${dir}" -maxdepth 2 -name "${glob_pattern}" -type f 2>/dev/null | head -1 || true)"
  if [ -z "${found}" ]; then
    fail_check "${label} (${glob_pattern}) not found in ${dir}"
    return 1
  fi
  if [ ! -s "${found}" ]; then
    fail_check "${label} is empty: ${found}"
    return 1
  fi
  pass_check "${label}: ${found}"
  return 0
}

case "${STAGE}" in
  onnxruntime-cpu)
    PREFIX="${PREFIX:-/usr/local/lib/onnxruntime-cpu}"
    verify_dir_not_empty "${PREFIX}/lib" "ONNX Runtime CPU lib dir"
    verify_shared_lib "${PREFIX}/lib" "libonnxruntime.so*" "libonnxruntime.so"
    verify_dir_not_empty "${PREFIX}/include" "ONNX Runtime CPU include dir"
    verify_file_exists "${PREFIX}/include/onnxruntime/core/session/onnxruntime_c_api.h" "ONNX Runtime C API header"
    ;;

  onnxruntime-genai)
    PREFIX="${PREFIX:-/usr/local/lib/onnxruntime-genai}"
    if [ "${BUILD_GENAI:-true}" != "true" ]; then
      echo "SKIP [${STAGE}]: BUILD_GENAI is not true"
      exit 0
    fi
    verify_dir_not_empty "${PREFIX}" "ONNX Runtime GenAI output dir"
    ;;

  onnxruntime-gpu)
    PREFIX="${PREFIX:-/usr/local/lib/onnxruntime-gpu}"
    if [ "${ENABLE_NVIDIA:-false}" != "true" ] && [ "${ENABLE_AMD:-false}" != "true" ]; then
      echo "SKIP [${STAGE}]: GPU disabled"
      exit 0
    fi
    verify_dir_not_empty "${PREFIX}" "ONNX Runtime GPU output dir"
    ;;

  onnxruntime-pkgconfig)
    PREFIX="${PREFIX:-/usr/local/lib/onnxruntime-cpu}"
    verify_file_exists "${PREFIX}/runtime/lib/pkgconfig/libonnxruntime.pc" "ONNX Runtime pkg-config"
    ;;

  litert)
    PREFIX="${PREFIX:-/usr/local}"
    verify_dir_not_empty "${PREFIX}/include" "LiteRT include dir"
    verify_dir_not_empty "${PREFIX}/lib" "LiteRT lib dir"
    if ! verify_shared_lib "${PREFIX}/lib" "libtensorflow-lite*.so*" "libtensorflow-lite.so" 2>/dev/null; then
      verify_shared_lib "${PREFIX}/lib" "libtflite*.so*" "LiteRT shared lib" || true
    fi
    ;;

  litert-headers)
    PREFIX="${PREFIX:-/usr/local}"
    verify_dir_not_empty "${PREFIX}/include/tensorflow/lite" "TFLite headers" || \
    verify_dir_not_empty "${PREFIX}/include/tflite" "LiteRT headers"
    ;;

  opencv-core)
    PREFIX="${PREFIX:-/opt/opencv5}"
    verify_shared_lib "${PREFIX}/lib" "libopencv_core.so*" "libopencv_core.so" || \
    verify_shared_lib "${PREFIX}/lib64" "libopencv_core.so*" "libopencv_core.so"
    ;;

  opencv)
    PREFIX="${PREFIX:-/opt/opencv5}"
    verify_dir_not_empty "${PREFIX}/lib" "OpenCV lib dir" || \
    verify_dir_not_empty "${PREFIX}/lib64" "OpenCV lib64 dir"
    verify_file_exists "${PREFIX}/lib/pkgconfig/opencv5.pc" "OpenCV pkg-config" || \
    verify_file_exists "${PREFIX}/lib64/pkgconfig/opencv5.pc" "OpenCV pkg-config"
    ;;

  ffmpeg)
    PREFIX="${PREFIX:-/opt/ffmpeg}"
    verify_file_exists "${PREFIX}/bin/ffmpeg" "ffmpeg binary"
    verify_file_exists "${PREFIX}/bin/ffprobe" "ffprobe binary"
    if [ -x "${PREFIX}/bin/ffmpeg" ] && ! cross_build_is_active 2>/dev/null; then
      if "${PREFIX}/bin/ffmpeg" -version >/dev/null 2>&1; then
        pass_check "ffmpeg -version OK"
      else
        fail_check "ffmpeg -version failed"
      fi
    elif cross_build_is_active 2>/dev/null; then
      echo "SKIP [${STAGE}]: ffmpeg -version (cross build, binary is for target arch)" >&2
    fi
    verify_dir_not_empty "${PREFIX}/lib" "FFmpeg lib dir"
    ;;

  gstreamer)
    PREFIX="${PREFIX:-/opt/gstreamer}"
    verify_file_exists "${PREFIX}/bin/gst-launch-1.0" "gst-launch-1.0"
    verify_file_exists "${PREFIX}/bin/gst-inspect-1.0" "gst-inspect-1.0"
    # Only run version check on native builds; cross-built binaries are for the target arch
    if ! cross_build_is_active 2>/dev/null; then
      if "${PREFIX}/bin/gst-inspect-1.0" --version >/dev/null 2>&1; then
        pass_check "gst-inspect-1.0 --version OK"
      else
        fail_check "gst-inspect-1.0 --version failed"
      fi
    fi
    verify_dir_not_empty "${PREFIX}/lib" "GStreamer lib dir"
    ;;

  libcamera)
    PREFIX="${PREFIX:-/opt/libcamera}"
    verify_file_exists "${PREFIX}/bin/cam" "cam binary" || \
    verify_file_exists "${PREFIX}/bin/lc-compliance" "lc-compliance binary"
    verify_file_exists "${PREFIX}/lib/pkgconfig/libcamera.pc" "libcamera pkg-config" || \
    verify_file_exists "${PREFIX}/lib64/pkgconfig/libcamera.pc" "libcamera pkg-config"
    ;;

  app-wheels)
    PREFIX="${PREFIX:-/opt/app-wheels}"
    if [ "${TARGET_ARCH:-${TARGETARCH:-amd64}}" != "riscv64" ]; then
      echo "SKIP [${STAGE}]: not riscv64"
      exit 0
    fi
    verify_dir_not_empty "${PREFIX}" "app wheelhouse"
    ;;

  media-inputs)
    echo "=== Media inputs stage integrity check ==="
    verify_dir_not_empty "${ONNXRUNTIME_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}/lib" "ONNX CPU libs in media-inputs"
    verify_dir_not_empty "${OPENCV_OUTPUT_DIR:-/opt/opencv5}/lib" "OpenCV libs in media-inputs" || \
    verify_dir_not_empty "${OPENCV_OUTPUT_DIR:-/opt/opencv5}/lib64" "OpenCV lib64 in media-inputs"
    verify_file_exists "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg" "ffmpeg in media-inputs"
    ;;

  *)
    echo "ERROR: Unknown verification stage: ${STAGE}" >&2
    echo "Known stages: onnxruntime-cpu, onnxruntime-genai, onnxruntime-gpu, onnxruntime-pkgconfig, litert, litert-headers, opencv, opencv-core, ffmpeg, gstreamer, libcamera, app-wheels, media-inputs" >&2
    exit 1
    ;;
esac

if [ "${FAILURES}" -gt 0 ]; then
  echo ""
  echo "=== ${FAILURES} artifact verification failure(s) for stage ${STAGE} ===" >&2
  echo "The build produced incomplete or missing artifacts. The image build will" >&2
  echo "be aborted to prevent propagating broken artifacts to downstream stages." >&2
  exit 1
fi

echo "OK   [${STAGE}]: All artifact checks passed" >&2
exit 0
