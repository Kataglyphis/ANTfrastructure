#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"

# A skip still creates the output tree, so the Dockerfile's COPY --from=onnxruntime succeeds.
[[ "${BUILD_GENAI}" != "true" ]] && {
  info "Skipping GenAI build (BUILD_GENAI=${BUILD_GENAI})"
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  echo "[INFO] Created placeholder GenAI output dir: ${GENAI_OUTPUT_DIR}"
  exit 0
}

ARCH="$(arch_oci 2>/dev/null || uname -m 2>/dev/null || echo unknown)"

# See docs/gen1-riscv64-genai.md § The escape hatch: `GENAI_ALLOW_RISCV64`
GENAI_ALLOW_RISCV64="${GENAI_ALLOW_RISCV64:-false}"
if [ "${ARCH}" = "riscv64" ] && [ "${GENAI_ALLOW_RISCV64}" != "true" ]; then
  info "Skipping onnxruntime-genai on ${ARCH}: GENAI_ALLOW_RISCV64=${GENAI_ALLOW_RISCV64} (GEN1 escape hatch)"
  # Create placeholder output directories so later Dockerfile COPYs succeed
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  # See docs/gen1-riscv64-genai.md § The `.gen1-lane-off` marker
  : > "${GENAI_OUTPUT_DIR}/.gen1-lane-off" 2>/dev/null || true
  echo "[INFO] Created placeholder GenAI output dir (GEN1 lane off): ${GENAI_OUTPUT_DIR}" || true
  exit 0
fi

# The cross allowlist must match verify-media-artifacts.sh's onnxruntime-genai arm.
GENAI_CROSS_BUILD=false
if cross_build_is_active; then
  case "${ARCH}" in
    arm64|riscv64) ;;
    *)
      info "Skipping onnxruntime-genai cross build for ${ARCH}: only the arm64/riscv64 cross lanes are wired (see GENAI-DRIFT, GEN1)"
      ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
      exit 0
      ;;
  esac
  command -v setup_linux_cross_env >/dev/null 2>&1 \
    || err "cross mode but setup_linux_cross_env is unavailable (01-core cross-env.sh not loaded)"
  if ! { command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; }; then
    # Without target Python dev files the binding would compile against the host's headers.
    warn "Skipping onnxruntime-genai ${ARCH} cross build: target Python dev files not ready (GENAI-DRIFT stays open; the app lock's PyPI genai fills in)"
    ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
    # The lane is on, so the verifier still fails; this file makes it name the real cause.
    printf 'target Python dev files not ready\n' \
      > "${GENAI_OUTPUT_DIR}/.gen1-skip-reason" 2>/dev/null || true
    exit 0
  fi
  setup_linux_cross_env
  GENAI_CROSS_BUILD=true
  info "Cross-building onnxruntime-genai for ${ARCH} (triplet ${CROSS_TARGET_TRIPLET}, rust target ${CROSS_RUST_TARGET})"
fi

info "Checking for ONNX Runtime at: ${NATIVE_CPU_OUTPUT_DIR}"
info "NATIVE_CPU_OUTPUT_DIR=${NATIVE_CPU_OUTPUT_DIR}"

if [[ ! -d "${NATIVE_CPU_OUTPUT_DIR}/lib" ]]; then
  err "Native CPU build lib directory not found at ${NATIVE_CPU_OUTPUT_DIR}/lib. Run 30-build-native.sh first."
fi

info "Contents of ${NATIVE_CPU_OUTPUT_DIR}/lib:"
ls -la "${NATIVE_CPU_OUTPUT_DIR}/lib/" || true

if [[ -z "$(ls -A "${NATIVE_CPU_OUTPUT_DIR}/lib"/*.so* 2>/dev/null)" ]]; then
  err "No .so files found in ${NATIVE_CPU_OUTPUT_DIR}/lib. Run 30-build-native.sh first."
fi

ensure_onnxruntime_symlink "${NATIVE_CPU_OUTPUT_DIR}"
if [[ ! -e "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]] && [[ ! -L "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  err "No libonnxruntime.so* files found in ${NATIVE_CPU_OUTPUT_DIR}/lib"
fi

if [[ ! -f "${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h" ]]; then
  err "ONNX Runtime header not found at ${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h. Run 30-build-native.sh first."
fi
info "Found onnxruntime_c_api.h at ${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h"

[[ -d "${GENAI_SRC_DIR}" ]] || err "GenAI source not found at ${GENAI_SRC_DIR}. Run 20-fetch.sh first."

# See docs/gen1-riscv64-genai.md § The upstream patch: `cmake/target_platform.cmake`
if [ "${ARCH}" = "riscv64" ]; then
  _genai_apply_patch="/opt/scripts/core/apply-patch.sh"
  _genai_patch_file="/opt/scripts/patches/onnxruntime-genai/001-riscv64-target-platform.patch"
  [ -f "${_genai_patch_file}" ] \
    || err "GEN1: riscv64 genai patch not found at ${_genai_patch_file} — is linux/scripts/patches bind-mounted into the genai RUN (Dockerfile.media)?"
  bash "${_genai_apply_patch}" "${_genai_patch_file}" "${GENAI_SRC_DIR}" \
    "onnxruntime-genai riscv64: teach cmake/target_platform.cmake the riscv64 arm (GEN1)"
fi

info ">>> GenAI build: ${GENAI_CONFIG} (${JOBS} parallel jobs)"

info "Using existing Python virtual environment (expected at /opt/python/.venv)"

# G2 grades this RUN's shared uv cache, so a PyPI ORT that an earlier build cached there must go first.
command -v uv >/dev/null 2>&1 && uv cache clean onnxruntime >/dev/null 2>&1 || true

info "Installing Python build dependencies (pip, numpy, wheel, setuptools, requests)"
ensure_uv_python_packages "${HOST_PYTHON}" pip numpy wheel setuptools requests

info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"

cd "${GENAI_SRC_DIR}"

# See docs/gen1-riscv64-genai.md § The riscv64-only preflight
GENAI_GUIDANCE_ARGS=(--use_guidance)
if [ "${ARCH}" = "riscv64" ]; then
  _genai_rust_target="${CROSS_RUST_TARGET:-}"
  if [ -z "${_genai_rust_target}" ] && command -v rust_target_triple_for_arch >/dev/null 2>&1; then
    _genai_rust_target="$(rust_target_triple_for_arch "${ARCH}" 2>/dev/null || true)"
  fi
  if [ -n "${_genai_rust_target}" ] && command -v rustup >/dev/null 2>&1 \
     && _genai_rust_installed="$(rustup target list --installed 2>/dev/null)" \
     && [ -n "${_genai_rust_installed}" ] \
     && ! printf '%s\n' "${_genai_rust_installed}" | grep -qx -- "${_genai_rust_target}"; then
    warn "GEN1: rustup has no std for ${_genai_rust_target} — dropping --use_guidance for ${ARCH} so Corrosion cannot abort the stage (the wheel ships WITHOUT llguidance; fix install-rust.sh/CROSS_TARGETS and rebuild to restore parity)"
    GENAI_GUIDANCE_ARGS=()
  fi
fi

GENAI_BASE_ARGS=(
  --config "${GENAI_CONFIG}"
  --skip_tests
  --skip_examples
  ${GENAI_GUIDANCE_ARGS[@]+"${GENAI_GUIDANCE_ARGS[@]}"}
  # GenAI's telemetry defaults on and fetches the 1DS SDK, whose vendored sqlite fails GCC 16's -Werror.
  --no_telemetry
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

append_onnx_lld_build_args GENAI_BASE_ARGS
append_onnx_ccache_build_args GENAI_BASE_ARGS

_GENAI_MODULE_EXT=""
if [ "${GENAI_CROSS_BUILD}" = "true" ]; then
  _genai_target_py_include="$(cross_target_python_include_dir)" \
    || err "cross_target_python_include_dir failed despite cross_target_python_dev_ready passing"
  _genai_py_mm="$(host_python_major_minor)" || err "cannot resolve host python major.minor"
  # Without the target's EXT_SUFFIX pybind11 names the module for the host, and the target Python cannot import it.
  _GENAI_MODULE_EXT=".cpython-${_genai_py_mm//./}-${CROSS_TARGET_TRIPLET}.so"
  GENAI_BASE_ARGS+=(
    --cmake_extra_defines
    # No CMAKE_LIBRARY_ARCHITECTURE: /usr/local holds target-arch libs, so ONLY-mode finds against / resolve there.
    CMAKE_SYSTEM_NAME=Linux
    CMAKE_SYSTEM_PROCESSOR="${CROSS_TARGET_PROCESSOR}"
    CMAKE_C_COMPILER="${CC}"
    CMAKE_CXX_COMPILER="${CXX}"
    CMAKE_ASM_COMPILER="${CC}"
    CMAKE_SYSROOT=/
    CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    # A cross build cannot run tests or benchmarks, so it does not compile them.
    ENABLE_TESTS=OFF
    ENABLE_MODEL_BENCHMARK=OFF
    # See docs/gen1-riscv64-genai.md § Corrosion cross wiring, for reference
    "Rust_CARGO_TARGET=${CROSS_RUST_TARGET}"
    # pybind11's classic mode overwrites the predefined target include dir and suffix unless PYBIND11_PYTHONLIBS_OVERWRITE=OFF.
    "Python_EXECUTABLE=${HOST_PYTHON}"
    "PYTHON_EXECUTABLE=${HOST_PYTHON}"
    "PYTHON_INCLUDE_DIR=${_genai_target_py_include}"
    PYBIND11_PYTHONLIBS_OVERWRITE=OFF
    "PYTHON_MODULE_EXTENSION=${_GENAI_MODULE_EXT}"
  )
  # setuptools honours _PYTHON_HOST_PLATFORM, so the wheel is born with the target platform tag.
  _PYTHON_HOST_PLATFORM="$(cross_wheel_platform_tag)" \
    || err "cross_wheel_platform_tag failed for ${ARCH}"
  export _PYTHON_HOST_PLATFORM
fi

# G2 (verify-genai-ort.sh) reads build.py's output for ORT fetch traces; each retry appends, so a fetch in a failed attempt counts.
GENAI_BUILD_LOG="${GENAI_SRC_DIR}/build/genai-build.log"
mkdir -p "${GENAI_SRC_DIR}/build"
: > "${GENAI_BUILD_LOG}"

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  ORT_HOME="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
  info "Building onnxruntime-genai with GPU ORT from ${ORT_HOME}"

  ensure_onnxruntime_symlink "${ORT_HOME}"
  if [[ ! -e "${ORT_HOME}/lib/libonnxruntime.so" ]] && [[ ! -L "${ORT_HOME}/lib/libonnxruntime.so" ]]; then
    warn "No versioned libonnxruntime.so found in ${ORT_HOME}/lib"
  fi

  # --use_trt_rtx makes the wheel require onnxruntime-trt-rtx, which nothing ships without TensorRT.
  _genai_gpu_args=(--use_cuda --cuda_home "${CUDA_HOME:-/usr/local/cuda}")
  [ "${ENABLE_TENSORRT:-true}" = "false" ] || _genai_gpu_args+=(--use_trt_rtx)
  info "GenAI build args: ${GENAI_BASE_ARGS[*]} ${_genai_gpu_args[*]}"
  retry 3 10 "ONNX Runtime GenAI GPU build" "${HOST_PYTHON}" build.py \
    "${GENAI_BASE_ARGS[@]}" \
    --ort_home "${ORT_HOME}" \
    "${_genai_gpu_args[@]}" 2>&1 | tee -a "${GENAI_BUILD_LOG}"
else
  ORT_HOME="${NATIVE_CPU_OUTPUT_DIR}"
  info "Building onnxruntime-genai with CPU ORT from ${ORT_HOME}"

  # The cross env's target LIBRARY_PATH breaks cargo's host build-script links; see docs/gen1-riscv64-genai.md § Corrosion cross wiring, for reference
  if [ "${GENAI_CROSS_BUILD}" = "true" ]; then
    info "GenAI cross: clearing LIBRARY_PATH for the build (host build-script links; was: ${LIBRARY_PATH:-<unset>})"
    unset LIBRARY_PATH
  fi

  info "GenAI build args: ${GENAI_BASE_ARGS[*]}"
  retry 3 10 "ONNX Runtime GenAI CPU build" "${HOST_PYTHON}" build.py \
    "${GENAI_BASE_ARGS[@]}" \
    --ort_home "${ORT_HOME}" 2>&1 | tee -a "${GENAI_BUILD_LOG}"
fi

collect_wheels_from_tree "${GENAI_SRC_DIR}/build" "${GENAI_OUTPUT_DIR}" "GenAI wheel"

if [ "${GENAI_CROSS_BUILD}" = "true" ]; then
  # See docs/gen1-riscv64-genai.md § The cross-wheel gate in the producer
  _genai_whl="$(ls "${GENAI_OUTPUT_DIR}/wheels"/onnxruntime_genai-*.whl 2>/dev/null | head -1 || true)"
  [ -n "${_genai_whl}" ] \
    || err "cross GenAI build produced no onnxruntime_genai wheel in ${GENAI_OUTPUT_DIR}/wheels"

  # A host-arch ELF or host-suffixed module would install fine and fail only at import.
  _genai_tmp="$(mktemp -d)"
  "${HOST_PYTHON}" -m zipfile -e "${_genai_whl}" "${_genai_tmp}/" \
    || err "cannot unpack ${_genai_whl} for verification"
  find "${_genai_tmp}" -type f -name "onnxruntime_genai${_GENAI_MODULE_EXT}" 2>/dev/null | grep -q . \
    || err "GenAI wheel's python module is not named onnxruntime_genai${_GENAI_MODULE_EXT} (host EXT_SUFFIX leaked in?): $(find "${_genai_tmp}" -name '*.so*' -printf '%f ' 2>/dev/null)"
  if command -v assert_elf_arch >/dev/null 2>&1; then
    while IFS= read -r _genai_so; do
      assert_elf_arch "${_genai_so}" "${ARCH}"
    done < <(find "${_genai_tmp}" -type f \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null)
    info "GenAI cross wheel verified: module suffix ${_GENAI_MODULE_EXT}, all ELF objects are ${ARCH}"
  else
    warn "assert_elf_arch unavailable; skipped ELF machine check on the GenAI cross wheel"
  fi
  rm -rf "${_genai_tmp}"
elif [ -z "$(ls -A "${GENAI_OUTPUT_DIR}/wheels" 2>/dev/null || true)" ]; then
  maybe_build_source_wheel "${GENAI_SRC_DIR}" "${GENAI_OUTPUT_DIR}" "${HOST_PYTHON}" "GenAI"
fi

if [[ -f "${GENAI_SRC_DIR}/src/ort_genai.h" ]]; then
  cp "${GENAI_SRC_DIR}/src/ort_genai.h" "${GENAI_OUTPUT_DIR}/include/"
  cp "${GENAI_SRC_DIR}/src/ort_genai_c.h" "${GENAI_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied GenAI headers to ${GENAI_OUTPUT_DIR}/include/"
else
  warn "GenAI headers not found at ${GENAI_SRC_DIR}/src/"
fi

GENAI_LIB_DIR="${GENAI_SRC_DIR}/build/Linux/${GENAI_CONFIG}"
if [[ -d "${GENAI_LIB_DIR}" ]]; then
  find "${GENAI_LIB_DIR}" -maxdepth 1 -type f \
    \( -name "libonnxruntime-genai*.so*" -o -name "*.so" \) \
    -exec cp -t "${GENAI_OUTPUT_DIR}/lib/" {} + 2>/dev/null || true
fi

# GenAI inherits ORT's QNN EP, so the QNN backend libs must sit beside the GenAI install too.
_genai_qnn_home="$(resolve_qnn_sdk)"
if [ -n "$_genai_qnn_home" ]; then
  info "GenAI: staging QNN backend libs beside the GenAI install (backlog QNN-LINUX)"
  stage_qnn_runtime "$_genai_qnn_home" "${GENAI_OUTPUT_DIR}"
fi

symlink_output_libraries_into_usr_local "${GENAI_OUTPUT_DIR}"

report_onnx_build_output "GenAI build complete" "${GENAI_OUTPUT_DIR}"
