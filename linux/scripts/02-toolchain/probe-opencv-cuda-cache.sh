#!/usr/bin/env bash
# A private FindCUDA replay proves local compilation reuse, not the full OpenCV build, remote cache or GPU execution.
set -euo pipefail
PROBE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_OUTPUT="${1:?usage: probe-opencv-cuda-cache.sh NEW_OUTPUT_DIRECTORY}"
mkdir "${PROBE_OUTPUT}"
PROBE_OUTPUT="$(cd "${PROBE_OUTPUT}" && pwd)"
export SCCACHE_DIR="${PROBE_OUTPUT}/private-cache" SCCACHE_SERVER_UDS="${PROBE_OUTPUT}/sccache.sock" SCCACHE_IDLE_TIMEOUT=0
export KATAGLYPHIS_SCCACHE_S3=off SCCACHE_ERROR_LOG="${PROBE_OUTPUT}/sccache-error.log"
unset SCCACHE_SERVER_PORT SCCACHE_MULTILEVEL_CHAIN SCCACHE_BUCKET SCCACHE_ENDPOINT SCCACHE_REGION SCCACHE_S3_USE_SSL
# shellcheck source=linux/scripts/03-media/core/common.sh
source "${PROBE_SCRIPT_DIR}/../03-media/core/common.sh"
media_common_init "${PROBE_SCRIPT_DIR}"
probe_opencv_cache_cleanup() {
    local status=$?
    trap - EXIT
    dump_compiler_cache_stats || true
    sccache --stop-server > "${PROBE_OUTPUT}/stop-server.txt" 2>&1 || status=1
    printf '%s\n' "${status}" > "${PROBE_OUTPUT}/cleanup-status.txt"
    exit "${status}"
}
trap probe_opencv_cache_cleanup EXIT
# shellcheck source=linux/scripts/03-media/build/opencv/opencv-cuda-cache.sh
source "${PROBE_SCRIPT_DIR}/../03-media/build/opencv/opencv-cuda-cache.sh"
source_module cross-cuda.sh
compiler_cache_launcher_env 2>/dev/null || true
launcher="$(compiler_cache_launcher)"
case "${launcher}" in *sccache*) ;; *) printf 'ERROR: probe needs the sccache-class resolver result\n' >&2; exit 1 ;; esac
export CXX="/opt/gcc-${GCC_VERSION}/bin/g++"
args=("-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-75;86;87;89;120}" "-DCMAKE_CXX_COMPILER=${CXX}")
if cuda_cross_active; then
    setup_linux_cross_env
    cuda_cross_load
    append_cmake_cross_args args
    append_cmake_cuda_cross_args args
    args+=("-DCUDA_TOOLKIT_TARGET_DIR=${CUDA_CROSS_TARGET_ROOT}" "-DCUDA_NVCC_FLAGS=--target-directory=${CUDA_CROSS_TARGET_DIR}" "-DCUDA_HOST_COMPILER=${CXX}")
fi
opencv_cuda_cache_args args "${launcher}" "${CUDA_HOME:-/usr/local/cuda}"
fixture="${PROBE_SCRIPT_DIR}/probes/opencv-cuda-cache"
mkdir "${PROBE_OUTPUT}/source"
cp -a "${fixture}/." "${PROBE_OUTPUT}/source/"
printf 'CXX=%s\nCUDAHOSTCXX=%s\n' "${CXX}" "${CUDAHOSTCXX:-}" > "${PROBE_OUTPUT}/selected-compilers.txt"
sccache --version > "${PROBE_OUTPUT}/sccache-version.txt"
cmake -S "${PROBE_OUTPUT}/source" -B "${PROBE_OUTPUT}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release "${args[@]}"
opencv_cuda_cache_assert "${PROBE_OUTPUT}/build"
for phase in cold repeat; do
    if [ "${phase}" = repeat ]; then cmake --build "${PROBE_OUTPUT}/build" --target clean; fi
    sccache --zero-stats
    cmake --build "${PROBE_OUTPUT}/build" --parallel 2 --verbose
    sccache --show-stats --stats-format=json > "${PROBE_OUTPUT}/${phase}-stats.json"
done
readelf -h -W "${PROBE_OUTPUT}/build/libcache_kernel.a" > "${PROBE_OUTPUT}/object-headers.txt"
"${CUDA_HOME:-/usr/local/cuda}/bin/cuobjdump" --list-elf "${PROBE_OUTPUT}/build/libcache_kernel.a" > "${PROBE_OUTPUT}/cuda-elf-list.txt"
IFS=';' read -r -a architectures <<< "${CUDA_ARCHITECTURES:-75;86;87;89;120}"
opencv_cuda_cache_stats_assert "${PROBE_OUTPUT}/cold-stats.json" "${PROBE_OUTPUT}/repeat-stats.json" "${#architectures[@]}"
