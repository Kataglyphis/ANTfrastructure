#!/usr/bin/env bash
set -euo pipefail
# Usage: verify-media-artifacts.sh <stage> [prefix_dir]; stops the build before an empty stage is consumed.

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

# <prefix> <pc_name> <label> [optional]: "optional" downgrades a miss to INFO.
verify_pkgconfig() {
  local prefix="$1" pc_name="$2" label="$3" optional="${4:-}"
  local pc
  # `|| true`: an absent prefix must be a "not found" verdict, not a set -e abort.
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

# Side-effect-free, for one-of logic: `verify_x A || verify_x B` counts A's failure even when B passes.
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

# Informational only: never touches FAILURES or returns non-zero.
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
    # A QNN provider needs its backend libs beside it; no provider means QNN is off.
    if find "${PREFIX}/lib" -maxdepth 1 -name 'libonnxruntime_providers_qnn.so*' -type f 2>/dev/null | grep -q .; then
      if ! find "${PREFIX}/lib" -maxdepth 1 -name 'libQnn*.so' -type f 2>/dev/null | grep -q .; then
        echo "FAIL [${STAGE}]: libonnxruntime_providers_qnn.so present but no libQnn*.so staged — QNN runtime missing"
        exit 1
      fi
      echo "PASS [${STAGE}]: QNN EP present, backend libs staged"
    fi
    ;;

  onnxruntime-genai)
    PREFIX="${PREFIX:-/usr/local/lib/onnxruntime-genai}"
    if [ "${BUILD_GENAI:-true}" != "true" ]; then
      echo "SKIP [${STAGE}]: BUILD_GENAI is not true"
      exit 0
    fi
    # Mirror 60-build-genai.sh's skips; keep both cross allowlists in lockstep. See docs/gen1-riscv64-genai.md
    _vma_host="$(uname -m)"
    case "${_vma_host}" in x86_64) _vma_host=amd64 ;; aarch64) _vma_host=arm64 ;; esac
    _vma_target="${TARGET_ARCH:-${TARGETARCH:-${_vma_host}}}"
    case "${_vma_target}" in x86_64) _vma_target=amd64 ;; aarch64) _vma_target=arm64 ;; esac
    # The producer's marker wins; the env test is only a fallback.
    if [ "${_vma_target}" = "riscv64" ] \
       && { [ -f "${PREFIX}/.gen1-lane-off" ] \
            || [ "${GENAI_ALLOW_RISCV64:-false}" != "true" ]; }; then
      echo "SKIP [${STAGE}]: riscv64 GenAI lane is off (GEN1 escape hatch); producer created a placeholder tree"
      exit 0
    fi
    # Any other producer skip is still a failure with the lane on; say why.
    if [ -f "${PREFIX}/.gen1-skip-reason" ]; then
      echo "FAIL [${STAGE}]: producer skipped the GenAI build: $(cat "${PREFIX}/.gen1-skip-reason" 2>/dev/null)" >&2
      exit 1
    fi
    case "${_vma_target}" in
      arm64|riscv64) _vma_genai_cross_ok=1 ;;
      *)             _vma_genai_cross_ok=0 ;;
    esac
    if [ "${BUILD_MODE:-native}" = "cross" ] \
       && [ "${_vma_target}" != "${_vma_host}" ] \
       && [ "${_vma_genai_cross_ok}" = "0" ]; then
      echo "SKIP [${STAGE}]: only the arm64/riscv64 cross lanes build GenAI (producer skips ${_vma_target})"
      exit 0
    fi
    # The producer creates the dirs on every path, so require an artifact.
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
    # LiteRT's own files: CPython already fills /usr/local/include and lib.
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
    # One verdict: `verify_A || verify_B` would count A's failure.
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
    # Hard one-of: a build without libopencv_core must fail.
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
    # No -version run: configure-runtime.sh registers the libs with ldconfig later.
    verify_dir_not_empty "${PREFIX}/lib" "FFmpeg lib dir"
    ;;

  gstreamer)
    PREFIX="${PREFIX:-/opt/gstreamer}"
    verify_file_exists "${PREFIX}/bin/gst-launch-1.0" "gst-launch-1.0"
    verify_file_exists "${PREFIX}/bin/gst-inspect-1.0" "gst-inspect-1.0"
    # No --version run: configure-runtime.sh registers the libs with ldconfig later.
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
    # A real .whl, not "not empty": a failed wheelhouse build leaves a .placeholder.
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
    report_prefix_sizes
    ;;

  media-inputs)
    echo "=== Media inputs stage integrity check ==="
    verify_dir_not_empty "${ONNXRUNTIME_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}/lib" "ONNX CPU libs in media-inputs"
    # One verdict: `verify_A || verify_B` would count A's failure.
    verify_any_lib "OpenCV libs in media-inputs" \
      "${OPENCV_OUTPUT_DIR:-/opt/opencv5}/lib:libopencv_core.so*" \
      "${OPENCV_OUTPUT_DIR:-/opt/opencv5}/lib64:libopencv_core.so*"
    verify_file_exists "${FFMPEG_PREFIX:-/opt/ffmpeg}/bin/ffmpeg" "ffmpeg in media-inputs" || true
    # Optional TVM libs, checked here so a loss at the package COPY is attributable.
    for _tvm_lib in /usr/local/lib/libtvm.so /usr/local/lib/libtvm_runtime.so; do
      [ -e "${_tvm_lib}" ] && verify_file_exists "${_tvm_lib}" "TVM ${_tvm_lib##*/} in media-inputs" || true
    done
    case "${TARGET_ARCH:-${TARGETARCH:-}}" in
      arm64|aarch64)
        verify_dir_not_empty "/opt/armnn/lib" "Arm NN in media-inputs" || true
        verify_dir_not_empty "/opt/acl/lib" "ACL in media-inputs" || true
        ;;
    esac
    # This arm runs on every media build, so the size report needs no RUN line of its own.
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
