#!/usr/bin/env bash
# Classic FindCUDA ignores the modern launcher; wiring checks do not prove cache hits or GPU inference.
_opencv_cuda_cache_required=0

opencv_cuda_cache_args() {
    local -n _occa_args="$1"
    local launcher="$2" toolkit="$3"
    export OPENCV_CUDA_CACHE_LAUNCHER="${launcher}" OPENCV_CUDA_CACHE_NVCC="${toolkit}/bin/nvcc"
    export CUDA_NVCC_EXECUTABLE="${BASH_SOURCE[0]}"
    _opencv_cuda_cache_required=1
    _occa_args+=(
        "-DCMAKE_CUDA_COMPILER_LAUNCHER=${launcher}"
        "-DCUDA_TOOLKIT_ROOT_DIR=${toolkit}"
        "-DCUDA_NVCC_EXECUTABLE=${BASH_SOURCE[0]}"
    )
}

opencv_cuda_cache_assert() {
    local build_dir="$1" wrapper="${BASH_SOURCE[0]}" rules rule count=0 rc=0
    [ "${_opencv_cuda_cache_required}" = 1 ] || return 0
    if ! grep -Fxq -e "CUDA_NVCC_EXECUTABLE:FILEPATH=${wrapper}" \
        -e "CUDA_NVCC_EXECUTABLE:UNINITIALIZED=${wrapper}" "${build_dir}/CMakeCache.txt"; then
        printf 'ERROR: OpenCV FindCUDA did not retain its nvcc cache wrapper\n' >&2
        return 1
    fi
    rules="$(find "${build_dir}" -type f -name '*_generated_*.cu.o*.cmake')" || return $?
    while IFS= read -r rule; do
        [ -n "${rule}" ] || continue
        count=$((count + 1))
        if ! grep -Fxq -e "set(CUDA_NVCC_EXECUTABLE \"${wrapper}\") # path" "${rule}"; then
            printf 'ERROR: OpenCV CUDA rule bypasses the cache wrapper: %s\n' "${rule}" >&2
            rc=1
        fi
    done <<< "${rules}"
    if [ "${count}" -eq 0 ]; then
        printf 'ERROR: OpenCV has no generated FindCUDA object rules to verify\n' >&2
        return 1
    fi
    [ "${rc}" -ne 0 ] || printf '[CACHE] OpenCV: %s FindCUDA rules use %s\n' "${count}" "${wrapper}" >&2
    return "${rc}"
}

opencv_cuda_cache_stats_assert() {
    python3 -I - "$@" <<'PYTHON'
import json
import sys

cold, repeat = [json.load(open(path, encoding="utf-8"))["stats"] for path in sys.argv[1:3]]
arches = int(sys.argv[3])
for name in ("CUDA", "CUDA (Device code)", "PTX", "CUBIN"):
    minimum = arches if name in ("PTX", "CUBIN") else 1
    assert cold["cache_misses"]["counts"].get(name, 0) >= minimum, ("cold", name, cold)
    assert repeat["cache_hits"]["counts"].get(name, 0) >= minimum, ("repeat", name, repeat)
for phase in (cold, repeat):
    assert sum(phase["cache_errors"]["counts"].values()) == 0, phase
    assert phase["requests_not_cacheable"] == 1 and phase["not_cached"] == {"-M": 1}, phase
    assert phase["non_cacheable_compilations"] == 1, phase
    for name in ("compile_fails", "cache_write_errors", "forced_recaches"):
        assert phase[name] == 0, (name, phase)
assert sum(repeat["cache_misses"]["counts"].values()) == 0, repeat
print("PASS: FindCUDA cold misses and forced-repeat hits cover every requested CUDA architecture")
PYTHON
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    exec "${OPENCV_CUDA_CACHE_LAUNCHER:?missing OpenCV CUDA cache launcher}" \
        "${OPENCV_CUDA_CACHE_NVCC:?missing real OpenCV nvcc}" "$@"
fi
