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

case "${1:-}" in
  -h|--help)
    echo "Usage: $0 <stage> [prefix_dir]"
    echo ""
    echo "Validate that a media build stage produced actual output (shared libs,"
    echo "binaries, headers) before downstream stages consume it."
    echo ""
    echo "Stages: onnxruntime-cpu, onnxruntime-genai, onnxruntime-gpu,"
    echo "        onnxruntime-pkgconfig, litert, litert-headers, opencv, opencv-core,"
    echo "        ffmpeg, gstreamer, libcamera, app-wheels, media-inputs"
    exit 0
    ;;
esac

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

# Locate a <pc_name>.pc under <prefix> and report. Required by default; pass
# "optional" as the 4th arg to downgrade a miss to an INFO instead of a failure.
verify_pkgconfig() {
  local prefix="$1" pc_name="$2" label="$3" optional="${4:-}"
  local pc
  # `|| true` (like verify_shared_lib below): an absent prefix makes find exit
  # non-zero, which must surface as this function's "not found" verdict — not
  # as a set -e abort of the whole verifier.
  pc="$(find "${prefix}" -name "${pc_name}" -type f 2>/dev/null | head -1 || true)"
  if [ -n "${pc}" ]; then
    pass_check "${label} pkg-config: ${pc}"
  elif [ "${optional}" = "optional" ]; then
    echo "INFO [${STAGE}]: ${pc_name} not found" >&2
  else
    fail_check "${label} pkg-config (${pc_name}) not found under ${prefix}"
  fi
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

# Like verify_shared_lib but does NOT increment the failure counter — for
# libraries that may not be produced by every build revision (e.g. LiteRT
# may build only static libs depending on the source revision).
verify_shared_lib_optional() {
  local dir="$1"
  local glob_pattern="$2"
  local label="${3:-shared library}"

  local found=""
  found="$(find "${dir}" -maxdepth 2 -name "${glob_pattern}" -type f 2>/dev/null | head -1 || true)"
  if [ -z "${found}" ]; then
    echo "INFO [LITERT]: ${label} (${glob_pattern}) not found — may be a static-only build" >&2
    return 0
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
    # LiteRT may produce shared or static libs depending on build revision
    verify_shared_lib_optional "${PREFIX}/lib" "libtensorflow-lite*.so*" "libtensorflow-lite.so"
    verify_shared_lib_optional "${PREFIX}/lib" "libtflite*.so*" "LiteRT shared lib"
    ;;

  litert-headers)
    PREFIX="${PREFIX:-/usr/local}"
    verify_dir_not_empty "${PREFIX}/include/tensorflow/lite" "TFLite headers" || \
    verify_dir_not_empty "${PREFIX}/include/tflite" "LiteRT headers"
    ;;

  opencv-core)
    PREFIX="${PREFIX:-/opt/opencv5}"
    verify_shared_lib_optional "${PREFIX}/lib" "libopencv_core.so*" "libopencv_core.so"
    verify_shared_lib_optional "${PREFIX}/lib64" "libopencv_core.so*" "libopencv_core.so"
    ;;

  opencv)
    PREFIX="${PREFIX:-/opt/opencv5}"
    if [ -d "${PREFIX}/lib" ]; then
      pass_check "OpenCV lib dir: ${PREFIX}/lib"
    elif [ -d "${PREFIX}/lib64" ]; then
      pass_check "OpenCV lib dir: ${PREFIX}/lib64"
    else
      fail_check "No OpenCV lib dir found under ${PREFIX}"
    fi
    verify_pkgconfig "${PREFIX}" "opencv5.pc" "OpenCV"
    ;;

  ffmpeg)
    PREFIX="${PREFIX:-/opt/ffmpeg}"
    verify_file_exists "${PREFIX}/bin/ffmpeg" "ffmpeg binary"
    verify_file_exists "${PREFIX}/bin/ffprobe" "ffprobe binary"
    # Skip -version check: ffmpeg's shared libs aren't registered with ldconfig yet
    # at this build stage (configure-runtime.sh runs later in the final stage).
    verify_dir_not_empty "${PREFIX}/lib" "FFmpeg lib dir"
    ;;

  gstreamer)
    PREFIX="${PREFIX:-/opt/gstreamer}"
    verify_file_exists "${PREFIX}/bin/gst-launch-1.0" "gst-launch-1.0"
    verify_file_exists "${PREFIX}/bin/gst-inspect-1.0" "gst-inspect-1.0"
    # Skip --version check: shared libs aren't registered with ldconfig yet at
    # this build stage (configure-runtime.sh runs later in the final stage).
    verify_dir_not_empty "${PREFIX}/lib" "GStreamer lib dir"
    ;;

  libcamera)
    PREFIX="${PREFIX:-/opt/libcamera}"
    # libcamera binaries may be installed to different paths depending on meson config
    cam_bin="$(find "${PREFIX}" -name "cam" -type f 2>/dev/null | head -1 || true)"
    lc_bin="$(find "${PREFIX}" -name "lc-compliance" -type f 2>/dev/null | head -1 || true)"
    if [ -n "${cam_bin}" ] || [ -n "${lc_bin}" ]; then
      pass_check "libcamera binary: ${cam_bin:-${lc_bin}}"
    else
      echo "INFO [libcamera]: no cam or lc-compliance binary found" >&2
    fi
    # pkg-config may be in lib/pkgconfig, lib64/pkgconfig, or any subdirectory
    verify_pkgconfig "${PREFIX}" "libcamera.pc" "libcamera" optional
    ;;

  app-wheels)
    PREFIX="${PREFIX:-/opt/app-wheels}"
    if [ "${TARGET_ARCH:-${TARGETARCH:-amd64}}" != "riscv64" ]; then
      echo "SKIP [${STAGE}]: not riscv64"
      exit 0
    fi
    verify_dir_not_empty "${PREFIX}" "app wheelhouse"
    ;;

  armnn)
    echo "=== Arm NN stage integrity check ==="
    case "${TARGET_ARCH:-${TARGETARCH:-}}" in
      arm64|aarch64)
        verify_dir_not_empty "/opt/armnn/lib" "Arm NN libs"
        verify_dir_not_empty "/opt/acl/lib" "ACL libs"
        ;;
      *)
        echo "Skipping Arm NN check (arm64 only, got ${TARGET_ARCH:-${TARGETARCH:-unknown}})"
        ;;
    esac
    ;;

  media-inputs)
    echo "=== Media inputs stage integrity check ==="
    verify_dir_not_empty "${ONNXRUNTIME_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}/lib" "ONNX CPU libs in media-inputs"
    if ! verify_dir_not_empty "${OPENCV_OUTPUT_DIR:-/opt/opencv5}/lib" "OpenCV libs in media-inputs" 2>/dev/null; then
      verify_dir_not_empty "${OPENCV_OUTPUT_DIR:-/opt/opencv5}/lib64" "OpenCV lib64 in media-inputs" || true
    fi
    verify_file_exists "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg" "ffmpeg in media-inputs" || true
    case "${TARGET_ARCH:-${TARGETARCH:-}}" in
      arm64|aarch64)
        verify_dir_not_empty "/opt/armnn/lib" "Arm NN in media-inputs" || true
        verify_dir_not_empty "/opt/acl/lib" "ACL in media-inputs" || true
        ;;
    esac
    ;;

  *)
    echo "ERROR: Unknown verification stage: ${STAGE}" >&2
    echo "Known stages: onnxruntime-cpu, onnxruntime-genai, onnxruntime-gpu, onnxruntime-pkgconfig, litert, litert-headers, opencv, opencv-core, ffmpeg, gstreamer, libcamera, app-wheels, armnn, media-inputs" >&2
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
