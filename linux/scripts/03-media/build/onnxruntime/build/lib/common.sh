#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

_ONNX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Preserve caller's SCRIPT_DIR — this may be the build-onnxruntime.sh directory
# which dispatches to step scripts using SCRIPT_DIR. Do NOT overwrite it.
ONNX_SCRIPT_DIR="${_ONNX_LIB_DIR}"
: "${SCRIPT_DIR:=${ONNX_SCRIPT_DIR}}"

if [ -f /opt/scripts/03-media/core/common.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/03-media/core/common.sh
  media_common_init "${_ONNX_LIB_DIR}"
elif [ -f "${_ONNX_LIB_DIR}/../../../../core/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${_ONNX_LIB_DIR}/../../../../core/common.sh"
  media_common_init "${_ONNX_LIB_DIR}"
fi

# media_common_init (above) provides the canonical logging (info/warn/err),
# platform (arch_oci), cross (cross_build_enabled) and host-Python
# (host_python_bin/host_python_major_minor) helpers via the 01-core module
# framework — the same set armnn and every build-*.sh already rely on. The
# previously copy-pasted re-implementations of these are gone; guard instead
# that they actually loaded, so a broken bootstrap fails loudly HERE rather
# than much later with a confusing "command not found".
for _req_fn in info warn err arch_oci cross_build_enabled host_python_bin host_python_major_minor; do
  if ! command -v "${_req_fn}" >/dev/null 2>&1; then
    printf '[ERROR] onnxruntime lib/common.sh: required helper %s is undefined after media_common_init (01-core framework not loaded)\n' "${_req_fn}" >&2
    exit 1
  fi
done
unset _req_fn

# is_amd64_arch has no canonical 01-core definition (arch_oci does), so it is
# defined here — it is used by the sibling ONNX step scripts
# (build-onnxruntime.sh, 40-build-wasm.sh, 50-build-js.sh).
is_amd64_arch() { [ "$(arch_oci)" = "amd64" ]; }

# compute_jobs_with_mem_cap is loaded from the canonical parallelism.sh module
# (sourced above via source_module). Do not add a fallback here — the canonical
# version includes cgroup awareness, AGGRESSIVE_PARALLELISM, and PARALLEL_JOBS.

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found in PATH: $1"
}

usage_common() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --ort-version <tag>           ONNX Runtime git tag/branch to checkout (default: ${ORT_VERSION})
  --build-type <cfg>            Native CPU build type: Release|RelWithDebInfo|Debug|MinSizeRel (default: ${NATIVE_CPU_CONFIG})
  --wasm-config <cfg>           WASM build type: Release|RelWithDebInfo|Debug|MinSizeRel (default: ${WASM_CONFIG})
  --genai-version <tag>          ONNX Runtime GenAI git tag/branch to checkout (default: ${GENAI_VERSION})
  --genai-config <cfg>           GenAI build type: Release|RelWithDebInfo|Debug|MinSizeRel (default: ${GENAI_CONFIG})
  --skip-genai                   Skip GenAI build (default: enabled)
  -h, --help                    Show this help

Notes:
  - CLI args override environment variables.
  - GenAI is built by default. Use --skip-genai or BUILD_GENAI=false to disable.
  - You can also set ORT_VERSION, NATIVE_CPU_CONFIG, WASM_CONFIG, GENAI_VERSION, GENAI_CONFIG via env.
EOF
}

init_defaults() {
  ORT_VERSION="${ORT_VERSION:-${ONNXRUNTIME_VERSION:-v1.28.0}}"
  ORT_REPO="${ORT_REPO:-https://github.com/microsoft/onnxruntime.git}"
  ORT_SRC_DIR="${ORT_SRC_DIR:-/opt/onnxruntime}"

  WASM_OUTPUT_DIR="${WASM_OUTPUT_DIR:-/usr/local/lib/onnxruntime-web}"
  WASM_CONFIG="${WASM_CONFIG:-Release}"
  BUILD_DIR="${BUILD_DIR:-${ORT_SRC_DIR}/build_wasm_output}"

  NATIVE_CPU_BUILD_DIR="${NATIVE_CPU_BUILD_DIR:-${ORT_SRC_DIR}/build_native_cpu}"
  NATIVE_CPU_OUTPUT_DIR="${NATIVE_CPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-cpu}"
  NATIVE_GPU_OUTPUT_DIR="${NATIVE_GPU_OUTPUT_DIR:-/usr/local/lib/onnxruntime-gpu}"
  NATIVE_CPU_CONFIG="${NATIVE_CPU_CONFIG:-Release}"

  BUILD_NATIVE_CPU="${BUILD_NATIVE_CPU:-true}"
  BUILD_DNNL_EP="${BUILD_DNNL_EP:-true}"
  BUILD_XNNPACK_EP="${BUILD_XNNPACK_EP:-true}"

  BUILD_GENAI="${BUILD_GENAI:-true}"
  GENAI_VERSION="${GENAI_VERSION:-${ONNXRUNTIME_GENAI_VERSION:-v0.15.2}}"
  GENAI_REPO="${GENAI_REPO:-https://github.com/microsoft/onnxruntime-genai.git}"
  GENAI_SRC_DIR="${GENAI_SRC_DIR:-${ORT_SRC_DIR}-genai}"
  GENAI_BUILD_DIR="${GENAI_BUILD_DIR:-${GENAI_SRC_DIR}/build}"
  GENAI_OUTPUT_DIR="${GENAI_OUTPUT_DIR:-/usr/local/lib/onnxruntime-genai}"
  GENAI_CONFIG="${GENAI_CONFIG:-Release}"

  USE_UV_VENV="${USE_UV_VENV:-true}"
  UV_VENV_DIR="${UV_VENV_DIR:-${ORT_SRC_DIR}/.venv}"

  CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

  SKIP_DEP_INSTALL="${SKIP_DEP_INSTALL:-false}"
  # LOG2: build the browser-WebGPU wasm flavors (.asyncify + .jspi) in
  # 40-build-wasm.sh so 50-build-js.sh can emit the ort.webgpu*/ort.jspi* JS
  # bundles. Default ON; set false as the kill-switch if the flavor passes
  # ever have to be shed (the js step then trims those bundles, pre-LOG2
  # behavior). Replaces the removed ENABLE_ASYNCIFY/ASYNCIFY_STACK_SIZE knobs,
  # whose pass aliased a plain (WebGPU-less) build to the .asyncify filenames.
  ORT_WASM_WEBGPU_FLAVORS="${ORT_WASM_WEBGPU_FLAVORS:-true}"
}

parse_common_args() {
  init_defaults

  while [ $# -gt 0 ]; do
    case "$1" in
      --ort-version)
        [ $# -ge 2 ] || err "--ort-version requires a value"
        ORT_VERSION="$2"
        shift 2
        ;;
      --build-type|--native-cpu-config|--native-config)
        [ $# -ge 2 ] || err "$1 requires a value"
        NATIVE_CPU_CONFIG="$2"
        shift 2
        ;;
      --wasm-config)
        [ $# -ge 2 ] || err "--wasm-config requires a value"
        WASM_CONFIG="$2"
        shift 2
        ;;
      --genai-version)
        [ $# -ge 2 ] || err "--genai-version requires a value"
        GENAI_VERSION="$2"
        shift 2
        ;;
      --genai-config)
        [ $# -ge 2 ] || err "--genai-config requires a value"
        GENAI_CONFIG="$2"
        shift 2
        ;;
      --build-genai)
        BUILD_GENAI="true"
        shift
        ;;
      --skip-genai)
        BUILD_GENAI="false"
        shift
        ;;
      -h|--help)
        usage_common
        exit 0
        ;;
      *)
        err "Unknown argument: $1 (use --help)"
        ;;
    esac
  done

  validate_build_type "${NATIVE_CPU_CONFIG}" "--build-type"
  validate_build_type "${WASM_CONFIG}" "--wasm-config"
  validate_build_type "${GENAI_CONFIG}" "--genai-config"

  export ORT_VERSION ORT_REPO ORT_SRC_DIR
  export WASM_OUTPUT_DIR WASM_CONFIG BUILD_DIR
  export NATIVE_CPU_BUILD_DIR NATIVE_CPU_OUTPUT_DIR NATIVE_GPU_OUTPUT_DIR NATIVE_CPU_CONFIG
  export BUILD_NATIVE_CPU BUILD_DNNL_EP BUILD_XNNPACK_EP
  export BUILD_GENAI GENAI_VERSION GENAI_REPO GENAI_SRC_DIR GENAI_BUILD_DIR GENAI_OUTPUT_DIR GENAI_CONFIG
  export USE_UV_VENV UV_VENV_DIR
  export CMAKE_POLICY_VERSION_MINIMUM
  export SKIP_DEP_INSTALL ORT_WASM_WEBGPU_FLAVORS
}

validate_build_type() {
  local v="$1"
  local flag="$2"
  case "${v}" in
    Release|RelWithDebInfo|Debug|MinSizeRel) ;;
    *) err "Invalid ${flag} '${v}'" ;;
  esac
}

detect_jobs() {
  if [ -n "${JOBS:-}" ]; then
    export JOBS
    info "Using JOBS=${JOBS}"
    return 0
  fi

  JOBS="$(compute_jobs_with_mem_cap "" 2000)"
  export JOBS
  info "Using JOBS=${JOBS}"
}

source_build_acceleration_helpers() {
  local include_sccache="${1:-false}"
  local helper

  for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${_ONNX_LIB_DIR}/../../../../01-core/compiler-cache.sh"; do
    if [ -f "${helper}" ]; then
      # shellcheck disable=SC1090
      source "${helper}"
      setup_ccache
      if [ "${include_sccache}" = "true" ] && command -v setup_sccache >/dev/null 2>&1; then
        setup_sccache
      fi
      setup_lld_linker
      return 0
    fi
  done

  return 0
}

if ! declare -F setup_host_python_environment >/dev/null 2>&1; then
  setup_host_python_environment() {
    HOST_PYTHON_BIN="$(host_python_bin)"
    HOST_PYTHON="${HOST_PYTHON_BIN}"
    export HOST_PYTHON_BIN HOST_PYTHON
    export PYTHON_EXECUTABLE="${HOST_PYTHON_BIN}" \
           Python_EXECUTABLE="${HOST_PYTHON_BIN}" \
           Python3_EXECUTABLE="${HOST_PYTHON_BIN}"
  }
fi

ensure_uv_python_packages() {
  local python_bin="${1:-}"
  shift || true

  [ "$#" -gt 0 ] || return 0
  require_cmd uv

  if [ -z "${python_bin}" ]; then
    python_bin="$(host_python_bin)"
  fi

  uv pip install --python "${python_bin}" "$@"
}

ensure_onnx_output_tree() {
  local output_dir="${1:?output dir required}"

  mkdir -p "${output_dir}" "${output_dir}/lib" "${output_dir}/include" "${output_dir}/wheels"
}

ensure_onnx_gpu_placeholder_output_dir() {
  ensure_onnx_output_tree "${NATIVE_GPU_OUTPUT_DIR}"
}

collect_wheels_from_tree() {
  local search_root="${1:?search root required}"
  local output_dir="${2:?output dir required}"
  local wheel_label="${3:-wheel}"
  local wheel_path

  [ -d "${search_root}" ] || return 0
  mkdir -p "${output_dir}/wheels"

  local _wheels_found=0
  while read -r wheel_path; do
    _wheels_found=1
    info "Copying ${wheel_label}: ${wheel_path}"
    cp "${wheel_path}" "${output_dir}/wheels/"
    ls -lh "${output_dir}/wheels/$(basename "${wheel_path}")"
  done < <(find "${search_root}" -name "*.whl" -type f 2>/dev/null || true)
  [ "${_wheels_found}" -eq 1 ] || info "No wheels found in ${search_root}"
}

maybe_build_source_wheel() {
  local source_dir="${1:?source dir required}"
  local output_dir="${2:?output dir required}"
  local python_bin="${3:?python binary required}"
  local package_label="${4:-package}"

  if [ -n "$(ls -A "${output_dir}/wheels" 2>/dev/null || true)" ]; then
    return 0
  fi

  if [ -f "${source_dir}/pyproject.toml" ] || [ -f "${source_dir}/setup.py" ]; then
    info "No ${package_label} wheels found; attempting pip wheel build from source"
    mkdir -p "${output_dir}/wheels"
    "${python_bin}" -m pip wheel -w "${output_dir}/wheels" "${source_dir}" || info "pip wheel failed for ${package_label} source"
    ls -lh "${output_dir}/wheels"/*.whl 2>/dev/null || true
  else
    info "${package_label} python packaging not detected; skipping pip wheel"
  fi
}

copy_onnx_headers_to_output() {
  local output_dir="${1:?output dir required}"
  local search_dir header_path

  shift
  mkdir -p "${output_dir}/include"

  for search_dir in "$@"; do
    [ -d "${search_dir}/include" ] || continue
    cp -a "${search_dir}/include/." "${output_dir}/include/" 2>/dev/null || true
    info "Copied headers from ${search_dir}/include"
  done

  for search_dir in "$@"; do
    [ -d "${search_dir}/include" ] || continue
    while read -r header_path; do
      cp "${header_path}" "${output_dir}/include/" 2>/dev/null || true
    done < <(find "${search_dir}/include" \( -name "onnxruntime*.h" -o -name "onnxruntime*.inc" \) -type f 2>/dev/null || true)
    # `.inc` included too: onnxruntime_experimental_c_api.h (new in the ORT
    # 1.28 header set, pulled in by GenAI >= 0.15.2) does a RELATIVE
    # `#include "onnxruntime_experimental_c_api.inc"` — flattening only the .h
    # left that include dangling at the top level and GenAI died with
    # "onnxruntime_experimental_c_api.inc: No such file or directory".
  done
}

verify_onnxruntime_core_header() {
  local output_dir="${1:?output dir required}"
  shift || true

  if [ -f "${output_dir}/include/onnxruntime_c_api.h" ]; then
    info "Found onnxruntime_c_api.h in ${output_dir}/include"
    return 0
  fi

  warn "onnxruntime_c_api.h not found in ${output_dir}/include"
  for search_dir in "$@"; do
    [ -d "${search_dir}" ] || continue
    find "${search_dir}" -name "onnxruntime_c_api.h" 2>/dev/null | head -5 || true
  done
}

copy_onnx_libraries_to_output() {
  local build_dir="${1:?build dir required}"
  local build_config="${2:?build config required}"
  local output_dir="${3:?output dir required}"

  mkdir -p "${output_dir}/lib"
  find "${build_dir}/${build_config}" -maxdepth 1 -type f \
    \( -name "libonnxruntime*.so*" -o -name "libonnxruntime_providers_*.so*" \) \
    -exec cp -t "${output_dir}/lib/" {} + 2>/dev/null || true
}

ensure_onnxruntime_symlink() {
  local output_dir="${1:?output dir required}"
  local onnx_lib=""

  # Guarded: an absent lib dir must fall through to the warn below, not abort
  # the caller via set -e/pipefail (the GPU call site passes an unchecked dir).
  onnx_lib="$(find "${output_dir}/lib" -maxdepth 1 -name 'libonnxruntime.so.*' -type f 2>/dev/null | head -1 || true)"
  if [ -n "${onnx_lib}" ] && [ ! -e "${output_dir}/lib/libonnxruntime.so" ]; then
    ln -sf "$(basename "${onnx_lib}")" "${output_dir}/lib/libonnxruntime.so"
    info "Created symlink: libonnxruntime.so -> $(basename "${onnx_lib}")"
  fi
}

symlink_output_libraries_into_usr_local() {
  local output_dir="${1:?output dir required}"

  find "${output_dir}/lib" -type f -name "lib*.so*" -print0 2>/dev/null | \
    xargs -0 -r ln -sf -t /usr/local/lib/ 2>/dev/null || true

  ldconfig 2>/dev/null || true
}

# Shared BUILD_ARGS base for the native ONNX Runtime builds ------------------
#
# The three native build scripts (30-build-native{,-amd,-nvidia}.sh) share an
# identical leading set of build.sh flags; only the EP-specific flags
# (--use_dnnl / --use_migraphx / --use_cuda / ...), cross handling, retry and
# some diagnostics differ. This appends the common base to the named BUILD_ARGS
# array; each EP script then appends only its own EP flags afterwards. build.sh
# parses flags via argparse (no positionals), so flag order is not significant.
# Args: <build_args_array_name> <build_dir> <config> <jobs>.
append_onnx_native_base_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"
  local build_dir="$2" config="$3" jobs="$4"

  build_args_ref+=(
    --build_dir "${build_dir}"
    --config "${config}"
    --build_shared_lib
    --parallel "${jobs}"
    --compile_no_warning_as_error
    --skip_submodule_sync
    --skip_tests
    --allow_running_as_root
    --use_mimalloc
    --use_lock_free_queue
  )
}

# Shared artifact-finalization tail for the native ONNX Runtime builds -------
#
# The verify -> copy-libs -> ensure-symlink -> usr-local-symlink sequence is
# byte-identical across the three native build scripts. The preceding wheel and
# header copies (and each script's own diagnostics) differ, so those stay in
# the callers. Args: <build_dir> <config> <output_dir> <src_dir>.
finalize_onnx_native_output() {
  local build_dir="${1:?build dir required}"
  local build_config="${2:?build config required}"
  local output_dir="${3:?output dir required}"
  local src_dir="${4:?source dir required}"

  verify_onnxruntime_core_header "${output_dir}" "${src_dir}" "${build_dir}"
  copy_onnx_libraries_to_output "${build_dir}" "${build_config}" "${output_dir}"
  ensure_onnxruntime_symlink "${output_dir}"
  symlink_output_libraries_into_usr_local "${output_dir}"
}

append_onnx_cross_cmake_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  local enable_python="OFF"
  if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
    enable_python="ON"
    info "Target Python dev files available; enabling ONNX Runtime Python in cross mode"
  fi

  # Deliberately a REDUCED cross set — do NOT switch this to the shared
  # cross_cmake_define_pairs / append_cmake_cross_args set. In particular onnx must
  # NOT receive CMAKE_LIBRARY_ARCHITECTURE: it breaks ONNX Runtime's FindPython
  # NumPy detection (onnxruntime_python.cmake), failing the cross Python-wheel
  # build with "Target Python::NumPy ... not found". Proven by an arm64 cross-build
  # A/B: with CMAKE_LIBRARY_ARCHITECTURE the wheel build fails at cmake configure;
  # without it, onnx configures and compiles cleanly. (CMAKE_AR/RANLIB and
  # PKG_CONFIG_USE_CMAKE_PREFIX_PATH are harmless but omitted for parity with the
  # long-proven working set.)
  build_args_ref+=(
    --cmake_extra_defines
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
    "onnxruntime_ENABLE_PYTHON=${enable_python}"
    onnxruntime_BUILD_UNIT_TESTS=OFF
    onnxruntime_GENERATE_TEST_REPORTS=OFF
  )
}

# Append the optional LTO / WebGPU build flags, each gated on its ORT_ENABLE_*
# env toggle (default false). Shared by the native CPU and AMD builds, which
# opted into these identically. NOTE: the nvidia build inlines --use_webgpu
# unconditionally, so it deliberately does NOT use this helper.
append_onnx_optional_lto_webgpu_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  if [ "${ORT_ENABLE_LTO:-false}" = "true" ]; then
    build_args_ref+=(--enable_lto)
  fi
  if onnx_webgpu_enabled_for_target; then
    build_args_ref+=(--use_webgpu --use_external_dawn)
    # Dawn's tint generates constexpr matcher functions (data.cc) that call the
    # non-constexpr MatchMat helper. clang (Dawn's primary toolchain) ignores this;
    # GCC 16 raises -Winvalid-constexpr and treats it as an ERROR — 36 in data.cc
    # alone — because Dawn's build feeds clang-only -Wno-* flags (e.g.
    # -Wno-unknown-warning-option) that GCC silently drops, leaving the diagnostic
    # unsuppressed. It's the ONLY error blocking the Dawn build. Disable exactly
    # that diagnostic for this build so Dawn compiles under GCC 16; harmless
    # elsewhere (a single relaxed pedantic warning). Both spellings for safety:
    # -Wno-error demotes it if Dawn uses -Werror, -Wno- disables it if it's a
    # default-error.
    build_args_ref+=(--cmake_extra_defines "CMAKE_CXX_FLAGS=-Wno-error=invalid-constexpr -Wno-invalid-constexpr")
  fi
}

# Decide whether to enable the WebGPU (Dawn) execution provider for THIS target.
# Master toggle ORT_ENABLE_WEBGPU (default false). Dawn is validated on the amd64
# native build; cross-compiling Dawn to arm64/riscv64 is unproven and would
# hard-fail the onnx build, so on those arches WebGPU is enabled only when
# ORT_WEBGPU_ALLOW_CROSS=true is ALSO set. This lets "turn WebGPU on" light up
# amd64 without silently breaking the cross builds.
onnx_webgpu_enabled_for_target() {
  [ "${ORT_ENABLE_WEBGPU:-false}" = "true" ] || return 1
  local arch="${TARGET_ARCH:-${TARGETARCH:-amd64}}"
  case "${arch}" in
    amd64|x86_64) return 0 ;;
    *) [ "${ORT_WEBGPU_ALLOW_CROSS:-false}" = "true" ] ;;
  esac
}

append_onnx_lld_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  if command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
    build_args_ref+=(
      --cmake_extra_defines
      CMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld
      CMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld
      CMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld
    )
    info "Using lld linker for faster linking"
  fi
}

append_onnx_ccache_build_args() {
  local build_args_name="$1"
  # shellcheck disable=SC2178
  local -n build_args_ref="${build_args_name}"

  if command -v ccache >/dev/null 2>&1 && { case "${USE_CCACHE:-true}" in 0|false|FALSE|no|NO|off|OFF) false ;; *) true ;; esac; }; then
    if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ]; then
      # 2026-08-26: resolve the launcher instead of hardcoding ccache.
      _ort_launcher="$(compiler_cache_launcher 2>/dev/null || echo ccache)"
      build_args_ref+=(
        --cmake_extra_defines
        "CMAKE_C_COMPILER_LAUNCHER=${_ort_launcher}"
        "CMAKE_CXX_COMPILER_LAUNCHER=${_ort_launcher}"
      )
      info "Using ${_ort_launcher} for faster compilation (via cmake_extra_defines)"
    else
      info "ccache already configured via environment (CMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER})"
    fi
  fi
}

pc_numeric_version_from_ort_version() {
  local v="$1"
  local out
  
  # Check if this is the main branch
  if [ "${v}" = "main" ] || [ "${v}" = "master" ]; then
    # Fetch version from GitHub
    out="$(curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/microsoft/onnxruntime/main/VERSION_NUMBER | tr -d '\n\r' | sed -E 's/[^0-9.].*//')"
    if [ -z "${out}" ]; then
      printf '%s' "0.0.0"
    else
      printf '%s' "${out}"
    fi
  else
    # Original logic for version tags
    out="$(printf '%s' "${v}" | sed -E 's/^v//' | sed -E 's/[^0-9.].*$//')"
    if [ -z "${out}" ]; then
      printf '%s' "0.0.0"
    else
      printf '%s' "${out}"
    fi
  fi
}

detect_target_arch() { arch_oci; }
