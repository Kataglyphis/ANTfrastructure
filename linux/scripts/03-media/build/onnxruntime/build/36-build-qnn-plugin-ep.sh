#!/usr/bin/env bash
# Qualcomm's plugin QNN EP, built from its pinned ORT fork against the chain's ORT prefix and the QAIRT Community zip: docs/qnn-linux.md#the-plugin-ep
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QNNEP_OUTPUT_DIR="${QNNEP_OUTPUT_DIR:-/usr/local/lib/onnxruntime-ep-qnn}"
QNNEP_ORT_DIR="${QNNEP_ORT_DIR:-/usr/local/lib/onnxruntime-cpu}"
QNNEP_WORK_DIR="${QNNEP_WORK_DIR:-/tmp/onnxruntime-ep-qnn}"
# shellcheck source=35-build-migraphx-plugin-ep.sh
source "${SCRIPT_DIR}/35-build-migraphx-plugin-ep.sh"

# The media RUN carries TARGET_ARCH; a sourced 01-core gives arch_oci. Either names the image the plugin is built for.
qnnep_target_arch() { if command -v arch_oci >/dev/null 2>&1; then arch_oci; else printf '%s' "${TARGET_ARCH:-${TARGETARCH:-}}"; fi; }

# <fork src>: the ORT version the fork's deps.txt names as ort_core; its prebuilt step copies libonnxruntime.so.<this> out of --ort_home.
qnnep_ort_core_version() {
  local v
  v="$(sed -n 's|^ort_core;.*/v\([0-9][0-9.]*\)\.zip;.*|\1|p' "$1/cmake/deps.txt" | head -n 1)"
  [ -n "${v}" ] || { printf 'ERROR: %s/cmake/deps.txt names no ort_core tag\n' "$1" >&2; return 1; }
  printf '%s' "${v}"
}

# <chain prefix> <dest> <ort_core version>: an --ort_home whose library is the chain's under the names the fork's copy step expects; its include/ is filled after configure.
qnnep_ort_home() {
  local chain="$1" dest="$2" ver="$3" real
  real="$(find "${chain}/lib" -maxdepth 1 -name 'libonnxruntime.so.[0-9]*.[0-9]*' -type f | head -n 1)"
  [ -n "${real}" ] || { printf 'ERROR: no libonnxruntime.so.N.N.N under %s/lib\n' "${chain}" >&2; return 1; }
  rm -rf "${dest}"; mkdir -p "${dest}/lib" "${dest}/include"
  ln -s "${real}" "${dest}/lib/libonnxruntime.so"
  ln -s "${real}" "${dest}/lib/libonnxruntime.so.1"
  ln -s "${real}" "${dest}/lib/libonnxruntime.so.${ver}"
  ln -s "${chain}/lib/libonnxruntime_providers_shared.so" "${dest}/lib/libonnxruntime_providers_shared.so"
  printf '%s' "${dest}"
}

# <ort home> <ort_core source dir>: the fork compiles against the ORT headers it was developed for, flat as a release package lays them out.
qnnep_ort_home_headers() {
  local dest="$1" inc="$2/include/onnxruntime" d f n=0
  [ -f "${inc}/core/session/onnxruntime_c_api.h" ] || { printf 'ERROR: %s holds no ORT public headers; the fork did not populate ort_core\n' "$2" >&2; return 1; }
  for d in core/session core/providers/cpu core/framework; do
    for f in "${inc}/${d}"/*; do [ -f "${f}" ] || continue; ln -sf "${f}" "${dest}/include/"; n=$((n + 1)); done
  done
  printf '%s' "${n}"
}

# <build dir> <chain prefix>: the fork's prebuilt step copies --ort_home's library into the build dir, so copies of the chain's bytes are fine; any other libonnxruntime there is a core the chain did not build.
qnnep_assert_no_foreign_core() {
  local build="$1" chain="$2" real chain_sha f
  real="$(find "${chain}/lib" -maxdepth 1 -name 'libonnxruntime.so.[0-9]*.[0-9]*' -type f | head -n 1)"
  [ -n "${real}" ] || { printf 'ERROR: no libonnxruntime.so.N.N.N under %s/lib\n' "${chain}" >&2; return 1; }
  chain_sha="$(sha256sum "${real}" | cut -c1-64)"
  while IFS= read -r f; do
    [ "$(sha256sum "${f}" | cut -c1-64)" = "${chain_sha}" ] || { printf 'ERROR: %s is an ONNX Runtime core library the chain did not build\n' "${f}" >&2; return 1; }
  done < <(find "${build}" -name 'libonnxruntime.so*' -type f 2>/dev/null)
}

qnnep_source_url() { printf 'https://github.com/onnxruntime/onnxruntime-qnn/archive/refs/tags/v%s.tar.gz' "$1"; }

# <so>: every NEEDED name is the chain's, a QAIRT backend beside it or the target's C/C++ runtime; ldd cannot run a cross-built module.
qnnep_closure_ok() {
  local so="$1" rc=0 n
  while IFS= read -r n; do
    case "${n}" in
      libonnxruntime*) [ -e "${QNNEP_ORT_DIR}/lib/${n}" ] || { printf 'ERROR: %s needs %s, which the chain prefix %s does not hold\n' "${so}" "${n}" "${QNNEP_ORT_DIR}" >&2; rc=1; } ;;
      libQnn*) [ -e "${so%/*}/${n}" ] || { printf 'ERROR: %s needs %s, not staged beside it\n' "${so}" "${n}" >&2; rc=1; } ;;
      libc.so* | libm.so* | libdl.so* | librt.so* | libpthread.so* | libgcc_s.so* | libstdc++.so* | libatomic.so* | ld-linux*) ;;
      *) printf 'ERROR: %s needs %s, which is neither the chain, QAIRT nor the C/C++ runtime\n' "${so}" "${n}" >&2; rc=1 ;;
    esac
  done < <(readelf -d -W "${so}" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
  return "${rc}"
}

# <so>: the two plugin exports and the NEEDED walk above.
qnnep_verify_library() { plugin_ep_verify_library "$1" qnnep_closure_ok; }

# The QAIRT SDK, the pinned fork and the --ort_home shim; sets QNNEP_QAIRT, QNNEP_VERSION, QNNEP_SHA, QNNEP_SRC and QNNEP_ORT_HOME.
qnnep_sources() {
  local work="${QNNEP_WORK_DIR}"
  QNNEP_QAIRT="$(resolve_qnn_sdk)"
  [ -n "${QNNEP_QAIRT}" ] || err "arm64 builds the plugin QNN EP, but no QAIRT SDK resolved (QNN_SDK_VERSION pin or a zip in linux/qnn-sdk/)"
  QNNEP_VERSION="$(mgxep_pin ORT_QNN_EP_VERSION)"; QNNEP_SHA="$(plugin_ep_sha_pin ORT_QNN_EP_SOURCE_SHA256)"
  QNNEP_SRC="$(plugin_ep_source onnxruntime-qnn "$(qnnep_source_url "${QNNEP_VERSION}")" ORT_QNN_EP_SOURCE_SHA256 "${work}")"
  QNNEP_ORT_HOME="$(qnnep_ort_home "${QNNEP_ORT_DIR}" "${work}/ort-home" "$(qnnep_ort_core_version "${QNNEP_SRC}")")"
}

# The fork's build.py, configure then build, with the fork's own headers in --ort_home between the two; names the module in QNNEP_SO.
qnnep_compile() {
  local work="${QNNEP_WORK_DIR}"
  if command -v setup_linux_cross_env >/dev/null 2>&1; then setup_linux_cross_env; fi
  setup_host_python_environment
  # --ort_home makes the fork take the chain's library and build no ORT core of its own (cmake/external/onnxruntime_prebuilt.cmake).
  local -a args=(
    --build_dir "${work}/build" --config Release --build_shared_lib --parallel "${JOBS}"
    --skip_tests --skip_submodule_sync --compile_no_warning_as_error --allow_running_as_root
    --cmake_generator Ninja
    --use_qnn --qnn_home "${QNNEP_QAIRT}" --ort_home "${QNNEP_ORT_HOME}"
    --cmake_extra_defines "QNN_ARCH_ABI=${QNN_SDK_LINUX_LIBDIR}" CMAKE_BUILD_RPATH_USE_ORIGIN:BOOL=TRUE
    "CMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM:-3.5}" onnxruntime_BUILD_UNIT_TESTS=OFF
  )
  if cross_build_is_active; then append_onnx_cross_cmake_build_args args; fi
  append_onnx_ccache_build_args args
  info ">>> QNN plugin EP v${QNNEP_VERSION}: ${JOBS} jobs, QAIRT at ${QNNEP_QAIRT}, chain ORT at ${QNNEP_ORT_DIR}"
  # -S: the fork's tools/python/util imports a helper it no longer ships whenever torch is importable; build.py needs only the stdlib.
  "${HOST_PYTHON_BIN}" -S "${QNNEP_SRC}/tools/ci_build/build.py" "${args[@]}" --update 2>&1 | tee "${work}/build.log"
  # Configure fetches ort_core; the headers go into --ort_home before the compile reads them.
  info "ORT headers for the plugin: $(qnnep_ort_home_headers "${QNNEP_ORT_HOME}" "${work}/build/Release/_deps/ort_core-src") files from the fork's ort_core"
  "${HOST_PYTHON_BIN}" -S "${QNNEP_SRC}/tools/ci_build/build.py" "${args[@]}" --build 2>&1 | tee -a "${work}/build.log"
  cmake_assert_compiler_cache_pin "${work}/build/Release" "${_ort_launcher:-}"
  QNNEP_SO="$(plugin_ep_built_module "${work}/build/Release/onnxruntime_qnn" libonnxruntime_providers_qnn.so)"
  qnnep_assert_no_foreign_core "${work}/build" "${QNNEP_ORT_DIR}" || err "the plugin build produced an ONNX Runtime core library of its own"
}

# Install the module with the QAIRT backends and both licence sets beside it, and write the provenance.
qnnep_stage() {
  plugin_ep_install_module "${QNNEP_SO}" "${QNNEP_OUTPUT_DIR}" onnxruntime-qnn "${QNNEP_SRC}" LICENSE ThirdPartyNotices.txt
  stage_qnn_runtime "${QNNEP_QAIRT}" "${QNNEP_OUTPUT_DIR}" 'libonnxruntime_providers_qnn.so*'
  mkdir -p "${QNNEP_OUTPUT_DIR}/licenses/qairt"; find "${QNNEP_QAIRT}" -maxdepth 1 -iname 'LICENSE*' -type f -exec cp -a {} "${QNNEP_OUTPUT_DIR}/licenses/qairt/" \;
  plugin_ep_provenance "${QNNEP_OUTPUT_DIR}" "onnxruntime-qnn v${QNNEP_VERSION}" "source-sha256 ${QNNEP_SHA}" "qairt ${QNN_SDK_VERSION:-}"
}

qnnep_build() {
  # amd64 and riscv64 only need the placeholder tree; QAIRT has no Linux backend for them.
  if [ "$(qnnep_target_arch)" != arm64 ]; then plugin_ep_skip "${QNNEP_OUTPUT_DIR}" "Skipping the QNN plugin EP (arm64-only, target $(qnnep_target_arch))"; return 0; fi
  plugin_ep_build_env "${QNNEP_WORK_DIR}"
  qnnep_sources
  qnnep_compile
  qnnep_stage
  plugin_ep_finish "${QNNEP_OUTPUT_DIR}" libonnxruntime_providers_qnn.so "QNN plugin EP" qnnep_verify_library
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  plugin_ep_main qnnep_build qnnep_verify_library "${QNNEP_OUTPUT_DIR}/lib/libonnxruntime_providers_qnn.so" "$@"
fi
