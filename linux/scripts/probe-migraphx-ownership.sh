#!/usr/bin/env bash
# The bounded SDK probe proves tiny real sessions and ownership cleanup, not full image or consumer acceptance.
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${scripts}/lib/cli-value-options.sh"
cli_require_positionals 'OUTPUT WORK PREFIX MODEL [CORE_DIRECTORY]' 4 5 "$@"
hub="$(cd "${scripts}/../.." && pwd)"
output_directory="$(cd "$1" && pwd)"
export MGXEP_WORK_DIR="$2" MGXEP_OUTPUT_DIR="$3"
model="$4" core="${5:-/opt/scripts/core}"
export ENABLE_AMD=true JOBS="${JOBS:-4}"
export BUILD_JOBS="${JOBS}" MAX_JOBS="${JOBS}"
backends=(/opt/rocm/*/lib/migraphx/lib/libmigraphx_gpu.so)
[[ "${#backends[@]}" == 1 && -f "${backends[0]}" ]] || { printf 'Expected one MIGraphX GPU backend\n' >&2; exit 1; }
export LD_LIBRARY_PATH="/usr/local/lib/onnxruntime-cpu/lib:${backends[0]%/*}:${LD_LIBRARY_PATH:-}"
bash "${scripts}/03-media/build/onnxruntime/build/35-build-migraphx-plugin-ep.sh" build \
  2>&1 | tee "${output_directory}/module-build-phase.log"
export ORT_AMDGPU_EP_ROOT="${MGXEP_OUTPUT_DIR}"
source "${core}/compiler-cache-utils.sh"
source "${scripts}/01-core/cross-gcc.sh"
gcc_root="$(gcc_toolchain_resolve_prefix)"
toolchain=("--gcc-toolchain=${gcc_root}")
launcher="$(compiler_cache_guarded_launcher "${core}")"
"${launcher}" clang++ "${toolchain[@]}" -std=c++17 -g -O0 -fsanitize=address -fno-omit-frame-pointer \
  -I/usr/local/lib/onnxruntime-cpu/include -I"${hub}/shared/native" \
  -c "${hub}/shared/native/tests/ort_plugin_runtime_probe.cpp" -o "${output_directory}/probe.o"
clang++ "${toolchain[@]}" -fsanitize=address "${output_directory}/probe.o" -L/usr/local/lib/onnxruntime-cpu/lib \
  -Wl,-rpath,/usr/local/lib/onnxruntime-cpu/lib -lonnxruntime -ldl -pthread -o "${output_directory}/probe"
ASAN_OPTIONS=detect_leaks=1:alloc_dealloc_mismatch=1:new_delete_type_mismatch=1 \
  "${output_directory}/probe" "${model}" "${output_directory}" | tee "${output_directory}/sessions.tsv"
source "${core}/python-probe.sh"
ci_image_python_require migraphx-ownership-probe docs/consumer-image-contract.md
"${PREFLIGHT_PYTHON}" "${scripts}/audit-native-plugin-runtime.py" "${output_directory}"
sha256sum "${MGXEP_OUTPUT_DIR}/lib/libmigraphx-ep.so" \
  "${scripts}"/03-media/build/onnxruntime/build/patches/00*-lifetime.patch \
  "${hub}/shared/native/tests/ort_plugin_runtime_probe.cpp" "${output_directory}/probe" \
  > "${output_directory}/inputs.sha256"
