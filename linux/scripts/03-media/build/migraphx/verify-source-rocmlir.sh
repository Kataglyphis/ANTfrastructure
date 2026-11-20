#!/usr/bin/env bash
# Installed exports, selected original headers and host C API state do not prove GPU inference or licence closure.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK ROCMLIR_PREFIX ORIGINAL_SOURCE' 3 "$@"
rocmlir_prefix="$(cd "$2" && pwd)" original_source="$(cd "$3" && pwd)"
source "${SCRIPT_DIR}/entry-common.sh"
source "${SCRIPT_DIR}/source-rocmlir.sh"
clang_root='' gcc_root=''
migraphx_prepare_native_work "${work}" work clang_root gcc_root
migraphx_rocmlir_prefix_contract "${rocmlir_prefix}" "${clang_root}/bin/llvm-ar" "${work}/archive-members.txt"
declare -a input_files=() original_files=()
migraphx_rocmlir_payload_files input_files "${rocmlir_prefix}"
for installed in "${input_files[@]}"; do
  [[ "${installed}" == "${rocmlir_prefix}/include/rocmlir/"* ]] || continue
  relative="${installed#"${rocmlir_prefix}/include/rocmlir/"}"
  if [[ "${relative}" == external/include/* ]]; then
    original="${original_source}/external/llvm-project/mlir/include/${relative#external/include/}"
  else
    original="${original_source}/mlir/include/${relative}"
  fi
  cmp -- "${original}" "${installed}"
  original_files+=("${original}")
done
input_files+=("${original_files[@]}")
migraphx_verify_rocmlir_notices "${rocmlir_prefix}/share/licenses/rocmlir" "${SCRIPT_DIR}/rocmlir-source-notices.sha256"
sha256sum -- "${input_files[@]}" > "${work}/inputs-before.sha256"
cmake_args=(
  "-DROCMLIR_PREFIX=${rocmlir_prefix}" "-DROCMLIR_REQUIRED_VERSION=${MIGRAPHX_ROCMLIR_VERSION}"
)
cmake_args+=(
  "-DROCMLIR_REQUIRED_API_VERSION=${MIGRAPHX_ROCMLIR_DIALECT_API_VERSION}"
  "-DrocMLIR_DIR=${rocmlir_prefix}/lib/cmake/rocmlir"
)
migraphx_configure_native_consumer cmake_args "${work}" "${SCRIPT_DIR}/rocmlir-host-consumer" "${clang_root}" "${gcc_root}" \
  17 "rocMLIR_DIR=${rocmlir_prefix}/lib/cmake/rocmlir"
migraphx_build_native_consumer "${work}" "${rocmlir_prefix}/lib/librockCompiler.a" "${JOBS:-2}"
"${work}/build/rocmlir-host-consumer" > "${work}/api-output.txt"
printf 'ROCMLIR API: version=%s dialect=migraphx pipeline=migraphx-to-tosa\n' "${MIGRAPHX_ROCMLIR_DIALECT_API_VERSION}" > "${work}/expected-output.txt"
cmp -- "${work}/expected-output.txt" "${work}/api-output.txt"
sha256sum -- "${input_files[@]}" > "${work}/inputs-after.sha256"
cmp -- "${work}/inputs-before.sha256" "${work}/inputs-after.sha256"
migraphx_verify_rocmlir_notices "${rocmlir_prefix}/share/licenses/rocmlir" "${SCRIPT_DIR}/rocmlir-source-notices.sha256"
printf 'ROCMLIR EXTERNAL CONSUMER PASSED: exact exports, original headers and host C API pipeline; GPU acceptance remains required\n'
