#!/usr/bin/env bash
# Fake nvcc and generated-rule fixtures prove wiring and raw statuses, not compiler cache hits or GPU inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MODULE="$(cd "${TESTS_DIR}/../03-media/build/opencv" && pwd)/opencv-cuda-cache.sh"
# shellcheck source=linux/scripts/03-media/build/opencv/opencv-cuda-cache.sh
source "${MODULE}" || exit 1
SUBJECT="${MODULE%/*}/build-opencv.sh"
t_source_functions "${SUBJECT}" _opencv_cmake_cuda_opts || exit 1
compiler_cache_launcher_env() { export CACHE_SETUP_REACHED=1; }
compiler_cache_launcher() { printf '%s' "${CACHE_LAUNCHER:-/cache/sccache launcher}"; }
cuda_cross_active() { [ "${CROSS:-0}" = 1 ] && return 0; return 1; }
append_cmake_cuda_cross_args() {
    local -n _cross_args="$1"
    _cross_args+=("-DCMAKE_CUDA_HOST_COMPILER=/target/aarch64-linux-gnu-g++")
}
_options() {
    local -a args=('caller value')
    _opencv_cmake_cuda_opts args
    printf 'ARGS'; printf ' <%s>' "${args[@]}"; printf '\n'
    printf 'ENV <%s> <%s> <%s> <%s>\n' "${OPENCV_CUDA_CACHE_LAUNCHER-}" "${OPENCV_CUDA_CACHE_NVCC-}" "${CACHE_SETUP_REACHED-}" "${CUDA_NVCC_EXECUTABLE-}"
}
export ENABLE_NVIDIA=true ENABLE_SCCACHE_CUDA=1 CUDA_HOME='/toolkit root'
t_case "classic FindCUDA and modern CUDA both retain the selected launcher"
_out="$(_options)"
t_assert_contains "${_out}" "<-DCUDA_NVCC_EXECUTABLE=${MODULE}>"
t_assert_contains "${_out}" '<-DCMAKE_CUDA_COMPILER_LAUNCHER=/cache/sccache launcher>'
t_assert_contains "${_out}" '<-DCUDA_TOOLKIT_ROOT_DIR=/toolkit root>'
t_assert_contains "${_out}" "ENV </cache/sccache launcher> </toolkit root/bin/nvcc> <1> <${MODULE}>"
t_assert_contains "${_out}" '<-DCMAKE_CUDA_ARCHITECTURES=75;86;87;89;120>'
t_assert_contains "${_out}" '<-DCUDA_ARCH_BIN=7.5;8.6;8.7;8.9;12.0>'
t_case "cross options preserve the target host compiler, target directory and all architectures"
_out="$(CROSS=1 CUDA_CROSS_TARGET_ROOT='/target root' CUDA_CROSS_TARGET_DIR=sbsa-linux CUDA_CROSS_CUDNN_HOME='/cudnn root' _options)"
t_assert_contains "${_out}" '<-DCMAKE_CUDA_HOST_COMPILER=/target/aarch64-linux-gnu-g++>'
t_assert_contains "${_out}" '<-DCUDA_NVCC_FLAGS=--target-directory=sbsa-linux>'
t_assert_contains "${_out}" '<-DCUDA_TOOLKIT_TARGET_DIR=/target root>'
t_assert_contains "${_out}" '<-DCMAKE_CUDA_ARCHITECTURES=75;86;87;89;120>'
t_case "opt-outs and a ccache fallback do not wrap nvcc"
t_assert_fails grep -F -e '-DCUDA_NVCC_EXECUTABLE=' <<< "$(ENABLE_NVIDIA=false _options)"
t_assert_fails grep -F -e '-DCUDA_NVCC_EXECUTABLE=' <<< "$(ENABLE_SCCACHE_CUDA=0 _options)"
t_assert_fails grep -F -e '-DCUDA_NVCC_EXECUTABLE=' <<< "$(CACHE_LAUNCHER=/cache/ccache _options)"
_work="$(t_mktemp -d)"
mkdir -p "${_work}/toolkit root/bin"
cat > "${_work}/sccache launcher" <<'LAUNCHER'
#!/usr/bin/env bash
printf 'LAUNCHER\n'
exec "$@"
LAUNCHER
cat > "${_work}/toolkit root/bin/nvcc" <<'NVCC'
#!/usr/bin/env bash
printf 'NVCC'; printf ' <%s>' "$@"; printf '\n'
exit "${NVCC_STATUS:-0}"
NVCC
chmod +x "${_work}/sccache launcher" "${_work}/toolkit root/bin/nvcc"
_args=()
opencv_cuda_cache_args _args "${_work}/sccache launcher" "${_work}/toolkit root"
t_case "the executable wrapper preserves compiler arguments and the raw failing status"
t_assert_eq $'LAUNCHER\nNVCC <-ccbin> </target compiler/g++> <-gencode=arch=compute_120,code=sm_120> <define with spaces>' \
    "$(bash "${MODULE}" -ccbin '/target compiler/g++' '-gencode=arch=compute_120,code=sm_120' 'define with spaces')"
t_assert_eq 37 "$(NVCC_STATUS=37 t_rc bash "${MODULE}" -c kernel.cu)"
t_assert_fails env -u OPENCV_CUDA_CACHE_LAUNCHER bash "${MODULE}" --version
t_assert_fails env -u OPENCV_CUDA_CACHE_NVCC bash "${MODULE}" --version
_build="${_work}/build with spaces"
mkdir -p "${_build}/nested dir"
printf 'CUDA_NVCC_EXECUTABLE:FILEPATH=%s\n' "${MODULE}" > "${_build}/CMakeCache.txt"
printf 'set(CUDA_NVCC_EXECUTABLE "%s") # path\n' "${MODULE}" > "${_build}/nested dir/cuda_compile_1_generated_kernel.cu.o.Release.cmake"
t_case "configured cache and every generated rule must retain the wrapper"
t_assert_ok opencv_cuda_cache_assert "${_build}"
printf 'CUDA_NVCC_EXECUTABLE:FILEPATH=/bare/nvcc\n' > "${_build}/CMakeCache.txt"
t_assert_fails opencv_cuda_cache_assert "${_build}"
printf 'CUDA_NVCC_EXECUTABLE:UNINITIALIZED=%s\n' "${MODULE}" > "${_build}/CMakeCache.txt"
t_assert_ok opencv_cuda_cache_assert "${_build}"
printf 'set(CUDA_NVCC_EXECUTABLE "/bare/nvcc") # path\n' > "${_build}/cuda_compile_2_generated_other.cu.o.Release.cmake"
t_assert_fails opencv_cuda_cache_assert "${_build}"
t_assert_fails opencv_cuda_cache_assert "${_work}/missing build"
t_case "a requested wrapper cannot pass with no generated CUDA rules"
mkdir -p "${_work}/empty"
printf 'CUDA_NVCC_EXECUTABLE:UNINITIALIZED=%s\n' "${MODULE}" > "${_work}/empty/CMakeCache.txt"
t_assert_fails opencv_cuda_cache_assert "${_work}/empty"
t_case "the non-CUDA or opted-out configure needs no CUDA cache files"
t_assert_ok env MODULE="${MODULE}" bash -c 'source "$MODULE"; opencv_cuda_cache_assert /nonexistent'
t_case "the build imports the companion and runs the configure gate"
t_assert_contains "$(cat "${SUBJECT}")" 'source "${SCRIPT_DIR}/opencv-cuda-cache.sh"'
t_assert_contains "$(t_fn_src "${SUBJECT}" configure_opencv)" 'opencv_cuda_cache_assert "${build_dir}"'
t_case "cache statistics require cold misses, per-architecture hits and no refusals or errors"
_stats="${_work}/stats"
mkdir -p "${_stats}"
python3 - "${_stats}" <<'PYTHON'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
base = {"cache_errors": {"counts": {}}, "compile_fails": 0, "cache_write_errors": 0, "requests_not_cacheable": 1, "not_cached": {"-M": 1}, "non_cacheable_compilations": 1, "forced_recaches": 0}
categories = {"CUDA": 1, "CUDA (Device code)": 1, "PTX": 5, "CUBIN": 5}
cold = dict(base, cache_misses={"counts": categories}, cache_hits={"counts": {}})
repeat = dict(base, cache_misses={"counts": {}}, cache_hits={"counts": categories})
(root / "cold.json").write_text(json.dumps({"stats": cold}))
(root / "repeat.json").write_text(json.dumps({"stats": repeat}))
for field in ("compile_fails", "cache_write_errors", "requests_not_cacheable", "forced_recaches"):
    (root / (field + ".json")).write_text(json.dumps({"stats": dict(repeat, **{field: 2})}))
(root / "missing.json").write_text(json.dumps({"stats": dict(repeat, cache_hits={"counts": {"CUDA": 1}})}))
(root / "miss.json").write_text(json.dumps({"stats": dict(repeat, cache_misses={"counts": {"CUDA": 1}})}))
(root / "error.json").write_text(json.dumps({"stats": dict(repeat, cache_errors={"counts": {"CUDA": 1}})}))
(root / "reason.json").write_text(json.dumps({"stats": dict(repeat, not_cached={"multiple input files": 1})}))
(root / "internal.json").write_text(json.dumps({"stats": dict(repeat, non_cacheable_compilations=2)}))
PYTHON
t_assert_ok opencv_cuda_cache_stats_assert "${_stats}/cold.json" "${_stats}/repeat.json" 5
for _bad in missing miss error reason internal compile_fails cache_write_errors requests_not_cacheable forced_recaches; do
    t_assert_fails opencv_cuda_cache_stats_assert "${_stats}/cold.json" "${_stats}/${_bad}.json" 5
done
t_assert_fails opencv_cuda_cache_stats_assert "${_stats}/repeat.json" "${_stats}/repeat.json" 5
t_assert_fails env PYTHONOPTIMIZE=1 MODULE="${MODULE}" COLD="${_stats}/cold.json" BAD="${_stats}/missing.json" bash -c 'source "$MODULE"; opencv_cuda_cache_stats_assert "$COLD" "$BAD" 5'
t_summary
