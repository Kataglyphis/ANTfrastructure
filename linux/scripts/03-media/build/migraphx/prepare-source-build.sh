#!/usr/bin/env bash
# Source preparation configures the full GPU backend; it does not build, install or accept an image.
set -euo pipefail
# shellcheck source=linux/scripts/03-media/build/migraphx/cli-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/cli-common.sh" 'NEW_WORK MIGRAPHX_ARCHIVE ROCM_CMAKE_ARCHIVE MSGPACK_ARCHIVE ROCM_ROOT' 5 "$@"
archive="$2" rocm_cmake_archive="$3" msgpack_archive="$4" rocm="$5"
source "${SCRIPT_DIR}/entry-common.sh"
[[ "${MIGRAPHX_WINDOWS_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || { printf 'Missing pinned MIGraphX source commit\n' >&2; exit 1; }
[[ "${MIGRAPHX_WINDOWS_SOURCE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { printf 'Missing pinned MIGraphX source SHA256\n' >&2; exit 1; }
migraphx_new_work "${work}" work
migraphx_prepare_source_tree "${archive}" "${MIGRAPHX_WINDOWS_SOURCE_SHA256}" "${work}/source"
grep -Fx "rocm_setup_version(VERSION ${MIGRAPHX_VERSION})" "${work}/source/CMakeLists.txt"
git -C "${work}/source" init --quiet
patch_file="${SCRIPT_DIR}/../../../patches/migraphx/001-preserve-zero-pad-maxpool.patch"
core="$(_media_find_core_dir "${SCRIPT_DIR}")"
bash "${core}/apply-patch.sh" "${patch_file}" "${work}/source"
python_patch_file="${SCRIPT_DIR}/../../../patches/migraphx/002-select-pinned-python.patch"
bash "${core}/apply-patch.sh" "${python_patch_file}" "${work}/source"
grep -F "abseil/abseil-cpp@${MIGRAPHX_WINDOWS_ABSEIL_VERSION} " "${work}/source/requirements.txt"
grep -F "google/protobuf@v${MIGRAPHX_WINDOWS_PROTOBUF_VERSION} " "${work}/source/requirements.txt"
grep -F "ROCm/composable_kernel@${MIGRAPHX_CK_COMMIT} --cmake subdir" "${work}/source/requirements.txt"
grep -Fx "ROCm/rocm-cmake@${MIGRAPHX_ROCM_CMAKE_COMMIT} --build" "${work}/source/requirements.txt"
migraphx_prepare_rocm_cmake "${work}" "${rocm_cmake_archive}"
clang_root='' gcc_root=''
migraphx_compiler_setup clang_root gcc_root "${work}/compiler.txt"
setup_host_python_environment
pybind_dir="$("${HOST_PYTHON_BIN}" -m pybind11 --cmakedir)"
grep -F "msgpack/msgpack-c@cpp-${MIGRAPHX_WINDOWS_MSGPACK_VERSION} " "${work}/source/requirements.txt"
migraphx_prepare_source_tree "${msgpack_archive}" "${MIGRAPHX_WINDOWS_MSGPACK_SHA256}" "${work}/msgpack-source"
declare -a msgpack_cmake_args=(
  -S "${work}/msgpack-source" -B "${work}/msgpack-build" -G Ninja
  "-DCMAKE_INSTALL_PREFIX=${work}/host-tools" "-DCMAKE_POLICY_VERSION_MINIMUM=${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"
  -DMSGPACK_CXX_ONLY:BOOL=OFF -DMSGPACK_ENABLE_SHARED:BOOL=OFF -DMSGPACK_ENABLE_STATIC:BOOL=ON
  -DMSGPACK_BUILD_TESTS:BOOL=OFF -DMSGPACK_BUILD_EXAMPLES:BOOL=OFF
)
migraphx_native_cmake_args msgpack_cmake_args "${clang_root}" "${gcc_root}"
append_cmake_cache_linker_args msgpack_cmake_args
cmake "${msgpack_cmake_args[@]}"
cmake --build "${work}/msgpack-build" --parallel "${JOBS:-2}"
cmake --install "${work}/msgpack-build"
mkdir -p "${work}/host-tools/share/licenses/msgpack"
cp "${work}/msgpack-source/"{COPYING,LICENSE_1_0.txt} "${work}/host-tools/share/licenses/msgpack/"
: "${MIGRAPHX_SOURCE_PREFIX:=/opt/rocm/migraphx}"
: "${MIGRAPHX_DEPS_PREFIX:=${work}/host-deps}"
deps_prefix="${MIGRAPHX_DEPS_PREFIX}"
cmake_args=(
  -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=${MIGRAPHX_SOURCE_PREFIX}"
  -DCMAKE_INSTALL_LIBDIR=lib
  "-DROCmCMakeBuildTools_DIR=${work}/host-tools/share/rocmcmakebuildtools/cmake"
  "-DCMAKE_PREFIX_PATH=${deps_prefix};${work}/host-tools;${rocm};${rocm}/core;${rocm}/core/lib/rocm_sysdeps;${rocm}/extras-${ROCM_VERSION%%.*}/lib/migraphx"
  "-DPython_EXECUTABLE=${HOST_PYTHON_BIN}" "-DPython3_EXECUTABLE=${HOST_PYTHON_BIN}"
  "-Dpybind11_DIR=${pybind_dir}" "-DMIGRAPHX_REQUIRED_PYBIND11_VERSION=${PY_PYBIND11_VERSION}"
  "-DMIGRAPHX_REQUIRED_PYTHON_VERSION=${PYTHON_VERSION}"
  -DMIGRAPHX_PACKAGE_BACKEND=therock "-DMIGRAPHX_THEROCK_ROCM_VERSION=${ROCM_VERSION}"
  -DBUILD_TESTING:BOOL=OFF -DBUILD_SHARED_LIBS:BOOL=ON
)
features=(MIGRAPHX_ENABLE_GPU MIGRAPHX_ENABLE_MLIR MIGRAPHX_USE_COMPOSABLEKERNEL
  MIGRAPHX_USE_ROCBLAS MIGRAPHX_USE_HIPBLASLT MIGRAPHX_USE_MIOPEN MIGRAPHX_USE_HIPRTC
  MIGRAPHX_ENABLE_PYTHON MIGRAPHX_ENABLE_ONNX MIGRAPHX_ENABLE_TENSORFLOW)
for feature in "${features[@]}"; do cmake_args+=("-D${feature}:BOOL=ON"); done
migraphx_prepare_cmake_plan cmake_args "${clang_root}" "${gcc_root}" "${work}/cmake-argv.nul" "${work}/source" "${work}/build"
sha256sum "${work}/source.tar.gz" "${work}/rocm-cmake-source.tar.gz" "${work}/msgpack-source.tar.gz" "${patch_file}" "${work}/source/src/eliminate_pad.cpp" \
  "${work}/source/test/eliminate_pad_test.cpp" "${python_patch_file}" "${work}/source/cmake/PythonModules.cmake" > "${work}/source-inputs.sha256"
cmake "${cmake_args[@]}"
cmake_assert_compiler_cache_pin "${work}/build" "${CMAKE_COMPILER_CACHE_PIN:-}"
required_features=("${features[@]/%/=ON}")
cmake_assert_configured_entries "${work}/build" bool "${required_features[@]}"
cmake_assert_configured_entries "${work}/build" first \
  "CMAKE_C_COMPILER=${clang_root}/bin/clang" "CMAKE_CXX_COMPILER=${clang_root}/bin/clang++" \
  "MIGRAPHX_SELECTED_PYTHON_EXECUTABLE=${HOST_PYTHON_BIN}"
grep -E '^HAS_HIP:INTERNAL=(1|TRUE)$' "${work}/build/CMakeCache.txt"
printf 'MIGRAPHX SOURCE CONFIGURED: full GPU feature selection; build and acceptance remain required\n'
