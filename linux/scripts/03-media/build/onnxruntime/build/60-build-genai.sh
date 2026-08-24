#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_common_args "$@"
detect_jobs

setup_host_python_environment
HOST_PYTHON="${HOST_PYTHON_BIN}"

# Early exit check - ensure output dir exists even when skipping so Docker
# COPY --from=onnxruntime won't fail when the GenAI build is intentionally
# skipped (e.g. BUILD_GENAI=false).
[[ "${BUILD_GENAI}" != "true" ]] && {
  info "Skipping GenAI build (BUILD_GENAI=${BUILD_GENAI})"
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  echo "[INFO] Created placeholder GenAI output dir: ${GENAI_OUTPUT_DIR}"
  exit 0
}

# Architecture guard: GenAI is not supported on riscv64. If we're building on
# riscv64, skip this stage with an informative message so the overall image
# build can continue.
ARCH="$(arch_oci 2>/dev/null || uname -m 2>/dev/null || echo unknown)"
if [ "${ARCH}" = "riscv64" ] || [ "${ARCH}" = "risc-v" ]; then
  info "Skipping onnxruntime-genai on ${ARCH} because it is not supported"
  # Create placeholder output directories so later Dockerfile COPYs succeed
  ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
  echo "[INFO] Created placeholder GenAI output dir for unsupported arch: ${GENAI_OUTPUT_DIR}" || true
  exit 0
fi

# GENAI-DRIFT producer half (2026-08-24): this gate used to skip GenAI on EVERY
# cross build, so the arm64 lane never produced a local onnxruntime_genai wheel
# and app assembly silently fell back to the uv.lock's PyPI 0.14.0 against the
# versions.env v0.15.2 pin (the smoke-torch-venv.sh tolerance line). arm64 now
# cross-compiles the wheel with the same machinery as the ORT CPU wheel in this
# lane (setup_linux_cross_env + the reduced ORT cross define set, see
# append_onnx_cross_cmake_build_args in lib/common.sh); the wheel lands in
# ${GENAI_OUTPUT_DIR}/wheels, collect-artifacts.sh gathers it into /opt/wheels
# and repair-wheels.sh retags it linux_aarch64 — the exact path the onnxruntime
# wheel already takes. Other cross targets keep the skip: riscv64 exited above
# (GEN1, documented), nothing else is validated.
GENAI_CROSS_BUILD=false
if cross_build_is_active; then
  if [ "${ARCH}" != "arm64" ]; then
    info "Skipping onnxruntime-genai cross build for ${ARCH}: only the arm64 cross lane is wired (see GENAI-DRIFT)"
    ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
    exit 0
  fi
  command -v setup_linux_cross_env >/dev/null 2>&1 \
    || err "cross mode but setup_linux_cross_env is unavailable (01-core cross-env.sh not loaded)"
  if ! { command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; }; then
    # Same gate the ORT cross wheel uses (30-build-native.sh): without target
    # Python dev files the binding would compile against HOST python headers.
    # Keep the documented skip rather than ship an unprovable binding.
    warn "Skipping onnxruntime-genai arm64 cross build: target Python dev files not ready (GENAI-DRIFT stays open; the app lock's PyPI genai fills in)"
    ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"
    exit 0
  fi
  setup_linux_cross_env
  GENAI_CROSS_BUILD=true
  info "Cross-building onnxruntime-genai for ${ARCH} (triplet ${CROSS_TARGET_TRIPLET}, rust target ${CROSS_RUST_TARGET})"
fi

# Validate native CPU build completed (GenAI depends on ORT)
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

# Check specifically for libonnxruntime.so (may be a symlink)
ensure_onnxruntime_symlink "${NATIVE_CPU_OUTPUT_DIR}"
if [[ ! -e "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]] && [[ ! -L "${NATIVE_CPU_OUTPUT_DIR}/lib/libonnxruntime.so" ]]; then
  err "No libonnxruntime.so* files found in ${NATIVE_CPU_OUTPUT_DIR}/lib"
fi

# Check for required header
if [[ ! -f "${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h" ]]; then
  err "ONNX Runtime header not found at ${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h. Run 30-build-native.sh first."
fi
info "Found onnxruntime_c_api.h at ${NATIVE_CPU_OUTPUT_DIR}/include/onnxruntime_c_api.h"

# Check GenAI source exists
[[ -d "${GENAI_SRC_DIR}" ]] || err "GenAI source not found at ${GENAI_SRC_DIR}. Run 20-fetch.sh first."

info ">>> GenAI build: ${GENAI_CONFIG} (${JOBS} parallel jobs)"

# Create Python virtual environment with uv
info "Using existing Python virtual environment (expected at /opt/python/.venv)"

# Install Python build dependencies with uv
info "Installing Python build dependencies (pip, numpy, wheel, setuptools, requests)"
ensure_uv_python_packages "${HOST_PYTHON}" pip numpy wheel setuptools requests

info "Using Python: ${HOST_PYTHON}"
info "NumPy version: $(${HOST_PYTHON} -c 'import numpy; print(numpy.__version__)')"

# Prepare output directories
ensure_onnx_output_tree "${GENAI_OUTPUT_DIR}"

# Build GenAI
cd "${GENAI_SRC_DIR}"

# Common base args shared between GPU and CPU builds
GENAI_BASE_ARGS=(
  --config "${GENAI_CONFIG}"
  --skip_tests
  --skip_examples
  --use_guidance
  # GenAI's ENABLE_TELEMETRY defaults ON (cmake/options.cmake) and FetchContent-
  # builds Microsoft's 1DS SDK (cpp_client_telemetry) — the same dep whose
  # vendored sqlite dies on GCC-16's stringop-overflow -Werror on arm64 (killed
  # the arm64 ORT media lane 3×; see the ORT-1.29 note in 30-build-native.sh).
  # Same policy as ORT: neither the arm64 build break NOR a telemetry SDK in
  # shipped images — off on every arch.
  --no_telemetry
  --cmake_extra_defines
  "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM}"
)

# Shared build acceleration (lld + ccache) — applied to GENAI_BASE_ARGS so they
# are actually passed to build.py (previously targeted an undeclared BUILD_ARGS
# array and silently no-op'd via `|| true`).
append_onnx_lld_build_args GENAI_BASE_ARGS
append_onnx_ccache_build_args GENAI_BASE_ARGS

_GENAI_MODULE_EXT=""
if [ "${GENAI_CROSS_BUILD}" = "true" ]; then
  _genai_target_py_include="$(cross_target_python_include_dir)" \
    || err "cross_target_python_include_dir failed despite cross_target_python_dev_ready passing"
  _genai_py_mm="$(host_python_major_minor)" || err "cannot resolve host python major.minor"
  # The TARGET python's EXT_SUFFIX, e.g. .cpython-314-aarch64-linux-gnu.so
  # (verified against the shipped arm64 image's /opt/venv python). Without this
  # pybind11 names the module with the HOST suffix (…-x86_64-linux-gnu.so),
  # which the target python never even considers at import time
  # (importlib.machinery.EXTENSION_SUFFIXES) — the wheel would install but
  # `import onnxruntime_genai` would die with ModuleNotFoundError on arm64.
  _GENAI_MODULE_EXT=".cpython-${_genai_py_mm//./}-${CROSS_TARGET_TRIPLET}.so"
  GENAI_BASE_ARGS+=(
    --cmake_extra_defines
    # The proven reduced ORT cross set (append_onnx_cross_cmake_build_args):
    # deliberately NO CMAKE_LIBRARY_ARCHITECTURE. /usr/local in this container
    # holds TARGET-arch libs, so LIBRARY/INCLUDE=ONLY against sysroot / finds
    # target artifacts (that is how the ORT cross wheel links).
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
    # Cross builds don't run tests/benchmarks; skip compiling them (upstream's
    # own cross targets — android/ios — pass exactly these OFF in build.py).
    ENABLE_TESTS=OFF
    ENABLE_MODEL_BENCHMARK=OFF
    # llguidance (--use_guidance) builds through Corrosion, which passes an
    # explicit `--target` to cargo — the CARGO_BUILD_TARGET env exported by
    # setup_linux_cross_env would be silently overridden by Corrosion's
    # host-triple default. Corrosion also FATALs cleanly if the rustup std for
    # this triple is missing, and wires CARGO_TARGET_<T>_LINKER to
    # CMAKE_C_COMPILER (the cross gcc) itself.
    "Rust_CARGO_TARGET=${CROSS_RUST_TARGET}"
    # Interpreter = the HOST venv python (runs `pip wheel`, matches the target
    # python's 3.14). pybind11 2.13 classic mode (FindPythonLibsNew) reads
    # everything else from that interpreter and OVERWRITES predefined values
    # unless PYBIND11_PYTHONLIBS_OVERWRITE=OFF — pybind11's own documented
    # cross-compile knob ("Turn off if cross-compiling and manually setting
    # these values"). With it off, the predefined include dir (TARGET python
    # headers) and module extension survive; its new-tools mode honors a
    # predefined PYTHON_MODULE_EXTENSION unconditionally.
    "Python_EXECUTABLE=${HOST_PYTHON}"
    "PYTHON_EXECUTABLE=${HOST_PYTHON}"
    "PYTHON_INCLUDE_DIR=${_genai_target_py_include}"
    PYBIND11_PYTHONLIBS_OVERWRITE=OFF
    "PYTHON_MODULE_EXTENSION=${_GENAI_MODULE_EXT}"
  )
  # Born with the right wheel platform tag (setuptools' get_platform() honors
  # _PYTHON_HOST_PLATFORM; same idiom as the torch/vision cross wheels in
  # build-app-wheelhouse.sh). repair-wheels.sh's blanket cross retag then
  # no-ops on this wheel instead of being its only line of defense.
  _PYTHON_HOST_PLATFORM="$(cross_wheel_platform_tag)" \
    || err "cross_wheel_platform_tag failed for ${ARCH}"
  export _PYTHON_HOST_PLATFORM
fi

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
  ORT_HOME="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
  info "Building onnxruntime-genai with GPU ORT from ${ORT_HOME}"

  ensure_onnxruntime_symlink "${ORT_HOME}"
  if [[ ! -e "${ORT_HOME}/lib/libonnxruntime.so" ]] && [[ ! -L "${ORT_HOME}/lib/libonnxruntime.so" ]]; then
    warn "No versioned libonnxruntime.so found in ${ORT_HOME}/lib"
  fi

  info "GenAI build args: ${GENAI_BASE_ARGS[*]}"
  retry 3 10 "ONNX Runtime GenAI GPU build" "${HOST_PYTHON}" build.py \
    "${GENAI_BASE_ARGS[@]}" \
    --ort_home "${ORT_HOME}" \
    --use_cuda \
    --cuda_home "${CUDA_HOME:-/usr/local/cuda}" \
    --use_trt_rtx
else
  ORT_HOME="${NATIVE_CPU_OUTPUT_DIR}"
  info "Building onnxruntime-genai with CPU ORT from ${ORT_HOME}"

  # HOST-LINK LEAK (wave7b 2026-08-24, first live run of the arm64 cross
  # build): setup_linux_cross_env exports LIBRARY_PATH with the TARGET libdirs
  # (cross-env.sh ~:534), and gcc's host `cc` honors LIBRARY_PATH for -m64
  # links too — so cargo's HOST build scripts (proc-macro2, anyhow, zerocopy,
  # rustversion…) died with "aarch64 libgcc_s.so.1 is incompatible with
  # elf64-x86-64" on every retry. The TARGET half never needed LIBRARY_PATH
  # here: cmake gets explicit cross compilers/sysroot flags and cargo links
  # the target through CARGO_TARGET_<T>_LINKER (Rust_CARGO_TARGET above). So
  # scrub it for the build.py invocation only — everything else in the cross
  # env stays untouched.
  if [ "${GENAI_CROSS_BUILD}" = "true" ]; then
    info "GenAI cross: clearing LIBRARY_PATH for the build (host build-script links; was: ${LIBRARY_PATH:-<unset>})"
    unset LIBRARY_PATH
  fi

  info "GenAI build args: ${GENAI_BASE_ARGS[*]}"
  retry 3 10 "ONNX Runtime GenAI CPU build" "${HOST_PYTHON}" build.py \
    "${GENAI_BASE_ARGS[@]}" \
    --ort_home "${ORT_HOME}"
fi

collect_wheels_from_tree "${GENAI_SRC_DIR}/build" "${GENAI_OUTPUT_DIR}" "GenAI wheel"

if [ "${GENAI_CROSS_BUILD}" = "true" ]; then
  # Gate honesty: on cross-arm64 the WHEEL is the whole point of this stage
  # (verify-media-artifacts.sh still SKIPs genai on cross), so a build that
  # "succeeded" without emitting one must fail HERE — not resurface at app
  # assembly as a silent PyPI-genai fallback. No host pip-wheel fallback
  # either: that would package an amd64 binding under an aarch64 tag.
  _genai_whl="$(ls "${GENAI_OUTPUT_DIR}/wheels"/onnxruntime_genai-*.whl 2>/dev/null | head -1 || true)"
  [ -n "${_genai_whl}" ] \
    || err "cross GenAI build produced no onnxruntime_genai wheel in ${GENAI_OUTPUT_DIR}/wheels"

  # Prove the shipped bytes: every .so inside the wheel must be TARGET-arch
  # ELF, and the pybind module must carry the TARGET EXT_SUFFIX (a host-suffixed
  # module would install fine and then ModuleNotFoundError at import).
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
  # Native only: attempt to build a wheel from the GenAI Python package
  maybe_build_source_wheel "${GENAI_SRC_DIR}" "${GENAI_OUTPUT_DIR}" "${HOST_PYTHON}" "GenAI"
fi

# Copy headers
if [[ -f "${GENAI_SRC_DIR}/src/ort_genai.h" ]]; then
  cp "${GENAI_SRC_DIR}/src/ort_genai.h" "${GENAI_OUTPUT_DIR}/include/"
  cp "${GENAI_SRC_DIR}/src/ort_genai_c.h" "${GENAI_OUTPUT_DIR}/include/" 2>/dev/null || true
  info "Copied GenAI headers to ${GENAI_OUTPUT_DIR}/include/"
else
  warn "GenAI headers not found at ${GENAI_SRC_DIR}/src/"
fi

# Copy libraries
# GenAI builds to build/Linux/Release/ (or similar based on config)
GENAI_LIB_DIR="${GENAI_SRC_DIR}/build/Linux/${GENAI_CONFIG}"
if [[ -d "${GENAI_LIB_DIR}" ]]; then
  find "${GENAI_LIB_DIR}" -maxdepth 1 -type f \
    \( -name "libonnxruntime-genai*.so*" -o -name "*.so" \) \
    -exec cp -t "${GENAI_OUTPUT_DIR}/lib/" {} + 2>/dev/null || true
fi

symlink_output_libraries_into_usr_local "${GENAI_OUTPUT_DIR}"

info "GenAI build complete. Artifacts in ${GENAI_OUTPUT_DIR}"
info "Wheels in ${GENAI_OUTPUT_DIR}/wheels"
ls -lh "${GENAI_OUTPUT_DIR}/wheels"/*.whl 2>/dev/null || true
find "${GENAI_OUTPUT_DIR}/lib" -maxdepth 1 -type f -name "*.so*" -printf '%f\n' 2>/dev/null | head -20 || true
