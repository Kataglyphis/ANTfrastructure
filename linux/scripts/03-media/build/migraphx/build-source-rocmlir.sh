#!/usr/bin/env bash
# Build the required rocMLIR package; this does not complete binary licence review or GPU/image acceptance.
set -euo pipefail
# Preparation stays in this shell so compiler, Python and cache bindings reach the vendor build.
# shellcheck source=linux/scripts/03-media/build/migraphx/prepare-source-rocmlir.sh
source "$(dirname "${BASH_SOURCE[0]}")/prepare-source-rocmlir.sh" "$@"
[[ -n "${CMAKE_COMPILER_CACHE_PIN:-}" ]] || { printf 'Missing rocMLIR build compiler-cache pin\n' >&2; exit 1; }
jobs="$(compute_cpp_heavy_jobs "${JOBS:-}")"
"${HOST_PYTHON_BIN}" "${SCRIPT_DIR}/inspect-rocmlir-build.py" \
  --build "${work}/build" --output "${work}/build-plan" \
  --clang-prefix "${clang_root}" --gcc-prefix "${gcc_root}" --cache-launcher "${CMAKE_COMPILER_CACHE_PIN}"
cmake --build "${work}/build" --target librockCompiler --parallel "${jobs}"
cmake --install "${work}/build/mlir/tools/rocmlir-lib"
migraphx_rocmlir_prefix_contract "${work}/host-deps" "${clang_root}/bin/llvm-ar" "${work}/installed-archive-members.txt"
mkdir -p "${work}/host-deps/share/licenses"
migraphx_stage_rocmlir_notices "${work}/source" "${work}/host-deps/share/licenses/rocmlir" "${SCRIPT_DIR}/rocmlir-source-notices.sha256"
bash "${SCRIPT_DIR}/verify-source-rocmlir.sh" "${work}/api-check" "${work}/host-deps" "${work}/source"
printf 'ROCMLIR LIBRARY BUILT: %s/host-deps; binary licence review and ordinary backend/image acceptance remain required\n' "${work}"
