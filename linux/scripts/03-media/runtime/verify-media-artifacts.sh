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
    echo "        ffmpeg, gstreamer, libcamera, app-wheels, sizes, media-inputs"
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
    echo "INFO [${STAGE}]: ${label} (${glob_pattern}) not found — may be a static-only build" >&2
    return 0
  fi
  pass_check "${label}: ${found}"
  return 0
}

# Side-effect-free probe: succeeds if <dir> contains a file matching <pattern>.
# Use for one-of/fallback logic — the verify_* helpers above increment FAILURES
# BEFORE returning 1, so `verify_x A || verify_x B` counts a failure even when
# B passes (that broken idiom is why this exists).
probe_lib() {
  local dir="$1" glob_pattern="$2"
  [ -n "$(find "${dir}" -maxdepth 2 -name "${glob_pattern}" -type f 2>/dev/null | head -1 || true)" ]
}

# Exactly one verdict for "at least one of these dir:pattern pairs must match".
verify_any_lib() {
  local label="$1"; shift
  local pair dir pattern
  for pair in "$@"; do
    dir="${pair%%:*}"; pattern="${pair#*:}"
    if probe_lib "${dir}" "${pattern}"; then
      pass_check "${label}: $(find "${dir}" -maxdepth 2 -name "${pattern}" -type f 2>/dev/null | head -1 || true)"
      return 0
    fi
  done
  fail_check "${label}: none of the expected libraries found ($*)"
  return 1
}

# AP7 (media half) — per-prefix size observability. INFORMATIONAL ONLY: never
# touches FAILURES, never returns non-zero. The media image is ~42 GB with no
# per-prefix breakdown anywhere; this prints one so every size item (AP1/AP4/S2/
# TG4) becomes a measured number on the very next build. Mirrors the runtime
# half's check_size_observability (smoke-runtime-image.sh). `|| true` on each
# probe so a missing prefix or a du hiccup can never abort the verifier.
report_prefix_sizes() {
  echo "--- Size: per-prefix disk usage (informational, ${TARGET_ARCH:-${TARGETARCH:-native}}) ---" >&2
  du -sh /opt/* 2>/dev/null | sort -h | sed 's/^/    /' >&2 || true
  # onnxruntime/litert install under /usr/local, not /opt — surface them too.
  du -sh /usr/local/lib/onnxruntime-* 2>/dev/null | sort -h | sed 's/^/    /' >&2 || true
  echo "    ---- total /opt ----" >&2
  du -sh /opt 2>/dev/null | sed 's/^/    /' >&2 || true
  echo "" >&2
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
    # 60-build-genai.sh legitimately skips on cross builds (exit 0 after
    # pre-creating an EMPTY output tree via ensure_onnx_output_tree) — mirror
    # that skip here instead of "verifying" the pre-created empty dirs.
    _vma_host="$(uname -m)"
    case "${_vma_host}" in x86_64) _vma_host=amd64 ;; aarch64) _vma_host=arm64 ;; esac
    if [ "${BUILD_MODE:-native}" = "cross" ] \
       && [ "${TARGET_ARCH:-${TARGETARCH:-${_vma_host}}}" != "${_vma_host}" ]; then
      echo "SKIP [${STAGE}]: GenAI does not cross-build (producer skips too)"
      exit 0
    fi
    # A dir that exists is no evidence — the producer mkdir -p's lib/ include/
    # wheels/ on every path. Require an actual artifact.
    verify_any_lib "ONNX Runtime GenAI artifact" \
      "${PREFIX}/lib:libonnxruntime-genai*.so*" \
      "${PREFIX}/lib:libonnxruntime_genai*.so*" \
      "${PREFIX}/wheels:*.whl"
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
    # NOT ${PREFIX}/include|lib generically: the base image already fills
    # /usr/local (from-source CPython), so those checks were unconditionally
    # true even when build-litert.sh installed nothing. Require LiteRT's OWN
    # evidence: its header tree plus at least one lib (shared or static).
    if [ ! -d "${PREFIX}/include/tensorflow/lite" ] && [ ! -d "${PREFIX}/include/tflite" ]; then
      fail_check "no LiteRT header tree under ${PREFIX}/include (tensorflow/lite or tflite)"
    else
      pass_check "LiteRT header tree present"
    fi
    verify_any_lib "LiteRT library (shared or static)" \
      "${PREFIX}/lib:libtensorflow-lite*.so*" \
      "${PREFIX}/lib:libtflite*.so*" \
      "${PREFIX}/lib:libtensorflow-lite*.a" \
      "${PREFIX}/lib:libtflite*.a"
    ;;

  litert-headers)
    PREFIX="${PREFIX:-/usr/local}"
    # One verdict for the one-of check (the old `verify_A || verify_B` idiom
    # counted A's failure even when B passed — fail_check increments first).
    if [ -d "${PREFIX}/include/tensorflow/lite" ] \
       && [ -n "$(ls -A "${PREFIX}/include/tensorflow/lite" 2>/dev/null || true)" ]; then
      pass_check "TFLite headers: ${PREFIX}/include/tensorflow/lite"
    elif [ -d "${PREFIX}/include/tflite" ] \
       && [ -n "$(ls -A "${PREFIX}/include/tflite" 2>/dev/null || true)" ]; then
      pass_check "LiteRT headers: ${PREFIX}/include/tflite"
    else
      fail_check "no non-empty LiteRT header dir under ${PREFIX}/include"
    fi
    ;;

  opencv-core)
    PREFIX="${PREFIX:-/opt/opencv5}"
    # Was two verify_shared_lib_optional calls — INFO-only, could never fail,
    # so a build that produced no libopencv_core at all passed. One-of, hard.
    verify_any_lib "libopencv_core.so" \
      "${PREFIX}/lib:libopencv_core.so*" \
      "${PREFIX}/lib64:libopencv_core.so*"
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
    # "not empty" was vacuous: the Dockerfile touches a .placeholder whenever
    # the wheelhouse build failed, so this gate passed on exactly the failures
    # it exists to catch. riscv64 has NO PyPI wheels — require a real .whl.
    # ALLOW_EMPTY_APP_WHEELS=1 is the explicit escape hatch for a deliberate
    # wheel-less image (same pattern as ALLOW_IREE_BUILD_FAIL).
    if probe_lib "${PREFIX}" "*.whl"; then
      pass_check "app wheelhouse contains wheels"
    elif [ "${ALLOW_EMPTY_APP_WHEELS:-0}" = "1" ]; then
      echo "INFO [${STAGE}]: wheelhouse empty but ALLOW_EMPTY_APP_WHEELS=1" >&2
    else
      fail_check "no *.whl in ${PREFIX} (riscv64 has no PyPI wheels; a placeholder-only wheelhouse ships a torch-less image). Set ALLOW_EMPTY_APP_WHEELS=1 only for a deliberate wheel-less image."
    fi
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

  sizes)
    # Explicit invocation of the informational size report (AP7). No integrity
    # checks, no failure path — just the per-prefix breakdown.
    report_prefix_sizes
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
    # AP7: emit the per-prefix size breakdown at the media consolidation point
    # (this arm runs on every media build) so the numbers land without a
    # dedicated Dockerfile RUN line. Informational — cannot affect FAILURES.
    report_prefix_sizes
    ;;

  *)
    echo "ERROR: Unknown verification stage: ${STAGE}" >&2
    echo "Known stages: onnxruntime-cpu, onnxruntime-genai, onnxruntime-gpu, onnxruntime-pkgconfig, litert, litert-headers, opencv, opencv-core, ffmpeg, gstreamer, libcamera, app-wheels, armnn, sizes, media-inputs" >&2
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
