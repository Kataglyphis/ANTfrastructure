#!/usr/bin/env bash
# NVIDIA's out-of-tree ONNX Runtime plugin EP for TensorRT, built against the chain's ORT and the image's TensorRT runtime: docs/linux-accelerator-images.md#the-plugin-tensorrt-ep
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=35-build-migraphx-plugin-ep.sh
source "${SCRIPT_DIR}/35-build-migraphx-plugin-ep.sh"

TRTEP_OUTPUT_DIR="${TRTEP_OUTPUT_DIR:-/usr/local/lib/onnxruntime-ep-tensorrt}"
TRTEP_ORT_DIR="${TRTEP_ORT_DIR:-/usr/local/lib/onnxruntime-gpu}"
# The GPU build links every chain library into /usr/local/lib; G2 must know both prefixes or the CPU-only providers read as foreign.
TRTEP_ORT_CPU_DIR="${TRTEP_ORT_CPU_DIR:-/usr/local/lib/onnxruntime-cpu}"
TRTEP_WORK_DIR="${TRTEP_WORK_DIR:-/tmp/onnxruntime-ep-tensorrt}"
TRTEP_SO=libonnxruntime_ep_tensorrt.so
# Declared only under onnxruntime_ep_tensorrt_BUILD_TESTS, which stays OFF; a seed for it would pin bytes the build never reads.
TRTEP_INACTIVE_SEEDS="${TRTEP_INACTIVE_SEEDS:-googletest}"

# name|pin key|SHA256 key|archive URL with {0}|GIT_REPOSITORY as upstream declares it|GIT_TAG with {0}: the tensorrt rows of plugin-ep-seeds.txt.
trtep_seed_table() { plugin_ep_seed_table tensorrt; }

trtep_source_url() { printf 'https://github.com/onnxruntime/onnxruntime-ep-tensorrt/archive/%s.tar.gz' "$1"; }

# "name repository tag" per git FetchContent_Declare of a CMake file, lower-cased name (the plugin declares every dependency by git tag).
trtep_declared_git() {
  tr '\n' ' ' < "$1" | grep -oE 'FetchContent_Declare\([[:space:]]*[A-Za-z0-9_.+-]+[^)]*' \
    | sed -nE 's/FetchContent_Declare\([[:space:]]*([A-Za-z0-9_.+-]+).*GIT_REPOSITORY[[:space:]]+"?([^[:space:]")]+).*GIT_TAG[[:space:]]+"?([^[:space:]")]+).*/\L\1\E \2 \3/p'
}

# "name repository tag archive-URL sha256" per table row, every pin resolved and checked.
trtep_seed_rows() {
  local name vkey skey fmt repo tagfmt version sha
  while IFS='|' read -r name vkey skey fmt repo tagfmt; do
    version="$(mgxep_pin "${vkey}")" || return 1
    sha="$(plugin_ep_sha_pin "${skey}")" || return 1
    printf '%s %s %s %s %s\n' "${name}" "${repo}" "${tagfmt//\{0\}/${version}}" "${fmt//\{0\}/${version}}" "${sha}"
  done < <(trtep_seed_table)
}

# <work> <seeded-file> <defines-array-name>: fetch every pinned seed as its release archive and point FetchContent at it.
trtep_seed_all() {
  local work="$1" seeded="$2" name repo tag url sha dir
  local -n _trtep_defines="$3"
  : > "${seeded}"
  while IFS=' ' read -r name repo tag url sha; do
    printf '%s %s %s\n' "${name}" "${repo}" "${tag}" >> "${seeded}"
    dir="$(mgxep_fetch_seed "${name}" "${url}" "${sha}" "${work}")"
    _trtep_defines+=("-D$(mgxep_seed_define "${name}"):PATH=${dir}")
  done < <(trtep_seed_rows)
}

# <name> <dir>...: the first directory holding <name>, or a named failure.
trtep_first_file() {
  local name="$1" d
  shift
  for d in "$@"; do [ -f "${d}/${name}" ] && { printf '%s' "${d}/${name}"; return 0; }; done
  printf 'ERROR: no %s under any of: %s\n' "${name}" "$*" >&2
  return 1
}

# Prints NvInfer.h: TENSORRT_HOME's own first, else the first match under /usr/include and /usr/local through first_match_using; positional arguments stay the caller's, since a find alias may read them.
trtep_tensorrt_header() {
  local root="${TENSORRT_HOME:-/usr/local/tensorrt}" header="${TENSORRT_HOME:-/usr/local/tensorrt}/include/NvInfer.h"
  if [ ! -f "${header}" ]; then
    if ! declare -F first_match_using >/dev/null; then
      printf 'ERROR: TensorRT header discovery requires first_match_using from guard-helpers.sh\n' >&2
      exit 1
    fi
    header=$(
      _trtep_header_caller_argv=("$@")
      _trtep_header_find() {
        local -a _trtep_header_exec_argv=("$@")
        set -- "${_trtep_header_caller_argv[@]}"
        find "${_trtep_header_exec_argv[@]}"
      }
      first_match_using _trtep_header_find /usr/include /usr/local -name "NvInfer.h"
    )
    [ -n "${header}" ] || { printf 'ERROR: no NvInfer.h under %s/include, /usr/include or /usr/local\n' "${root}" >&2; return 1; }
  fi
  printf '%s' "${header}"
}

# The plugin wants TENSORRT_HOME/include and the three runtime libraries directly in TENSORRT_HOME; the apt packages split them, so link a tree under the work dir and print it.
trtep_tensorrt_home() {
  local dir="${TRTEP_WORK_DIR}/tensorrt" major="${TENSORRT_VERSION:-}" root="${TENSORRT_HOME:-/usr/local/tensorrt}" header so name
  major="${major%%.*}"
  [ -n "${major}" ] || { printf 'ERROR: TENSORRT_VERSION is not set; the plugin needs its major for the library names\n' >&2; return 1; }
  header="$(trtep_tensorrt_header)" || return 1
  rm -rf "${dir}"; mkdir -p "${dir}"
  ln -s "${header%/*}" "${dir}/include"
  for name in libnvinfer libnvinfer_plugin libnvonnxparser; do
    so="$(trtep_first_file "${name}.so.${major}" "${root}/lib" /usr/lib/*-linux-gnu /usr/lib)" || return 1
    ln -s "${so}" "${dir}/${name}.so.${major}"
  done
  printf '%s' "${dir}"
}

# <so>: ldd resolves everything and the module links the image's TensorRT major (any major when TENSORRT_VERSION is unknown to a bare verify call).
trtep_closure_ok() {
  local major="${TENSORRT_VERSION:-}"; major="${major%%.*}"
  mgxep_closure_ok "$1" || return 1
  readelf -d -W "$1" 2>/dev/null | grep -qE "NEEDED.*\[libnvinfer\.so\.${major:-[0-9]+}\]" \
    || { printf 'ERROR: %s does not link libnvinfer.so.%s\n' "$1" "${major:-N}" >&2; return 1; }
}

trtep_verify_library() { plugin_ep_verify_library "$1" trtep_closure_ok; }

# The pinned source and every seed into the work tree; sets TRTEP_COMMIT, TRTEP_SHA, TRTEP_SRC and the TRTEP_DEFINES the configure takes.
trtep_sources() {
  local work="${TRTEP_WORK_DIR}" seeded declared
  TRTEP_COMMIT="$(mgxep_pin ORT_TENSORRT_EP_COMMIT)"; TRTEP_SHA="$(plugin_ep_sha_pin ORT_TENSORRT_EP_SOURCE_SHA256)"
  [[ "${TRTEP_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || err "ORT_TENSORRT_EP_COMMIT=${TRTEP_COMMIT} is not a 40-hex commit"
  TRTEP_SRC="$(plugin_ep_source onnxruntime-ep-tensorrt "$(trtep_source_url "${TRTEP_COMMIT}")" ORT_TENSORRT_EP_SOURCE_SHA256 "${work}")"
  declared="${work}/declared.txt"; seeded="${work}/seeded.txt"
  trtep_declared_git "${TRTEP_SRC}/CMakeLists.txt" > "${declared}"
  TRTEP_DEFINES=()
  trtep_seed_all "${work}" "${seeded}" TRTEP_DEFINES
  plugin_ep_assert_seeded "${declared}" "${seeded}" "${TRTEP_INACTIVE_SEEDS}"
}

# <array name>: nvcc through the resolver's sccache-class launcher (append_onnx_gpu_cache_args decides), as -D flags for a direct cmake call.
trtep_cuda_cache_args() {
  local -n _tcc_out="$1"
  local -a build_args=() arg
  append_onnx_gpu_cache_args build_args CUDA
  for arg in "${build_args[@]}"; do [ "${arg}" = --cmake_extra_defines ] || _tcc_out+=("-D${arg}"); done
}

# <array name>: a CUDA cross target (gpu stage, CROSS_NVIDIA_SBSA=1) takes the cross toolchain and nvcc's cross defines; a native build nothing.
trtep_cross_args() {
  local -n _tca_out="$1"
  cuda_cross_active || return 0
  cuda_cross_load || err "cuda_cross_load failed"
  # shellcheck source=../../../../01-core/cross-meson.sh
  command -v append_cmake_cross_args >/dev/null 2>&1 || source "${PLUGIN_EP_CORE}/cross-meson.sh"
  append_cmake_cross_args _tca_out
  append_cmake_cuda_cross_args _tca_out
}

# Configure against the chain ORT and the image's TensorRT, build, and name the module in TRTEP_SO_PATH.
trtep_compile() {
  local work="${TRTEP_WORK_DIR}" ort_prefix trt_home
  ort_prefix="$(mgxep_ort_prefix "${TRTEP_ORT_DIR}" "${work}/ort")"
  trt_home="$(trtep_tensorrt_home)"
  # shellcheck disable=SC2034  # read through the nameref in plugin_ep_configure_and_build
  local -a cmake_args=(
    -S "${TRTEP_SRC}" -B "${work}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
    "-DORT_HOME=${ort_prefix}" "-DTENSORRT_HOME=${trt_home}" "-DTRT_MAJOR_VERSION=${TENSORRT_VERSION%%.*}"
    "-DCMAKE_CUDA_COMPILER=${CUDA_HOME:-/usr/local/cuda}/bin/nvcc" "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-75;86;87;89;120}"
    -Donnxruntime_ep_tensorrt_INSTALL=OFF -Donnxruntime_ep_tensorrt_BUILD_TESTS=OFF -Donnxruntime_ep_tensorrt_OBJECT_CACHE=OFF
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  )
  append_cmake_cache_linker_args cmake_args
  trtep_cuda_cache_args cmake_args
  trtep_cross_args cmake_args
  info ">>> TensorRT plugin EP ${TRTEP_COMMIT:0:12}: ${#TRTEP_DEFINES[@]} pinned seeds, ${JOBS} jobs, TensorRT ${TENSORRT_VERSION} at ${trt_home}"
  plugin_ep_configure_and_build "${work}" cmake_args TRTEP_DEFINES
  TRTEP_SO_PATH="$(plugin_ep_built_module "${work}/build" "${TRTEP_SO}")"
}

# Install the module with every licence text linked into it, write the provenance, and pass G2.
trtep_stage() {
  local -a g2
  plugin_ep_install "${TRTEP_SO_PATH}" "${TRTEP_OUTPUT_DIR}" onnxruntime-ep-tensorrt "${TRTEP_SRC}" "${TRTEP_WORK_DIR}" LICENSE
  plugin_ep_provenance "${TRTEP_OUTPUT_DIR}" "onnxruntime-ep-tensorrt ${TRTEP_COMMIT}" "source-sha256 ${TRTEP_SHA}" "tensorrt ${TENSORRT_VERSION}"
  # G2 over both chain prefixes: the GPU build links every chain library into /usr/local/lib, so the CPU-only providers read as foreign otherwise.
  plugin_ep_g2_records g2 "${TRTEP_WORK_DIR}"
  ort_assert_chain_only tensorrt-ep --stamp "${TRTEP_OUTPUT_DIR}/ort-provenance/tensorrt-ep.json" --chain "${TRTEP_ORT_DIR}" --chain "${TRTEP_ORT_CPU_DIR}" "${g2[@]}" \
    || err "the TensorRT plugin's build inputs reach an ONNX Runtime other than the chain's"
}

trtep_build() {
  # The empty tree keeps the media merge's COPY --from=onnxruntime valid on the chains that do not build it.
  if [ "${ENABLE_NVIDIA:-false}" != "true" ] || [ "${ENABLE_TENSORRT:-true}" = "false" ]; then
    plugin_ep_skip "${TRTEP_OUTPUT_DIR}" "Skipping the TensorRT plugin EP (ENABLE_NVIDIA=${ENABLE_NVIDIA:-false}, ENABLE_TENSORRT=${ENABLE_TENSORRT:-true})"; return 0
  fi
  plugin_ep_build_env "${TRTEP_WORK_DIR}"
  # shellcheck source=../../../../01-core/cmake-cache-linker.sh
  source "${PLUGIN_EP_CORE}/cmake-cache-linker.sh"
  # shellcheck source=../../../ort-provenance.sh
  source "${SCRIPT_DIR}/../../../ort-provenance.sh"
  trtep_sources
  trtep_compile
  trtep_stage
  plugin_ep_finish "${TRTEP_OUTPUT_DIR}" "${TRTEP_SO}" "TensorRT plugin EP" trtep_verify_library
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  plugin_ep_main trtep_build trtep_verify_library "${TRTEP_OUTPUT_DIR}/lib/${TRTEP_SO}" "$@"
fi
