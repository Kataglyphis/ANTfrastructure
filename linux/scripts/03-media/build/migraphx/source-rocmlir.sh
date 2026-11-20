#!/usr/bin/env bash
# Source contracts and exact original notices do not establish a linked binary or its complete license closure.
migraphx_rocmlir_source_contract() {
  local tree="$1" selected
  grep -Fx "project(rocMLIR VERSION ${MIGRAPHX_ROCMLIR_VERSION} LANGUAGES CXX C)" "${tree}/CMakeLists.txt" || return
  for selected in external/llvm-project/llvm/CMakeLists.txt external/llvm-project/mlir/CMakeLists.txt external/llvm-project/lld/CMakeLists.txt external/triton/CMakeLists.txt cmake/triton.cmake; do
    [[ -f "${tree}/${selected}" ]] || { printf 'Incomplete rocmlirTriton source: %s\n' "${selected}" >&2; return 1; }
  done
}

migraphx_stage_rocmlir_notices() {
  local tree="$1" dest="$2" policy="$3" digest relative required
  mkdir "${dest}" || return
  while read -r digest relative; do
    [[ -n "${digest}${relative}" && "${digest}" != '#' ]] || continue
    [[ "${digest}" =~ ^[0-9a-f]{64}$ && -n "${relative}" ]] || { printf 'Malformed rocmlir notice policy\n' >&2; return 2; }
    case "${relative}" in /*|../*|*/../*|*/..) printf 'Invalid rocmlir notice path\n' >&2; return 2 ;; esac
    mkdir -p "${dest}/$(dirname "${relative}")" || return
    cp -- "${tree}/${relative}" "${dest}/${relative}" || return
    download_verify_sha256 "${digest}" "${dest}/${relative}" || return
  done < "${policy}"
  for required in LICENSE external/llvm-project/LICENSE.TXT external/triton/LICENSE; do
    [[ -f "${dest}/${required}" ]] || { printf 'Missing primary rocmlir notice: %s\n' "${required}" >&2; return 1; }
  done
  cp -- "${policy}" "${dest}/SOURCE-NOTICE-SHA256SUMS"
}

migraphx_rocmlir_cmake_plan() {
  local -n rocmlir_args="$1"
  local selected_work="$2" selected_rocm="$3"
  rocmlir_args=(
    -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=${selected_work}/host-deps"
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS:BOOL=OFF -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
    -DBUILD_FAT_LIBROCKCOMPILER:BOOL=ON -DLLVM_INCLUDE_TESTS:BOOL=OFF
    -DMLIR_ENABLE_ROCM_RUNNER:BOOL=OFF -DMLIR_INCLUDE_TESTS:BOOL=OFF
    "-DLLVM_TARGETS_TO_BUILD=X86;AMDGPU" -DTRITON_OFFLINE_BUILD:BOOL=ON
    -DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON -DFETCHCONTENT_UPDATES_DISCONNECTED:BOOL=ON
  )
  rocmlir_args+=(
    "-DROCM_PATH=${selected_rocm}"
    "-DCMAKE_PREFIX_PATH=${selected_work}/host-tools;${selected_rocm};${selected_rocm}/core;${selected_rocm}/core/lib/rocm_sysdeps"
    "-DROCmCMakeBuildTools_DIR=${selected_work}/host-tools/share/rocmcmakebuildtools/cmake"
    "-DPython_EXECUTABLE=$6" "-DPython3_EXECUTABLE=$6" "-DTRITON_CACHE_PATH=${selected_work}/triton-cache"
  )
  migraphx_prepare_cmake_plan "$1" "$4" "$5" "${selected_work}/cmake-argv.nul" "${selected_work}/source" "${selected_work}/build"
}

# These installed-file and archive checks do not prove external API linkage or binary licence completeness.
migraphx_rocmlir_prefix_contract() {
  local prefix="$1" ar="$2" record="$3" required
  local -a required_files=()
  migraphx_rocmlir_payload_files required_files "${prefix}" || return
  (( ${#required_files[@]} > 0 )) || { printf 'Empty rocMLIR payload selection\n' >&2; return 1; }
  for required in "${required_files[@]}"; do
    [[ -s "${required}" ]] || { printf 'Missing installed rocMLIR payload: %s\n' "${required}" >&2; return 1; }
  done
  [[ ! -e "${record}" ]] || { printf 'Refusing reused rocMLIR archive receipt\n' >&2; return 2; }
  "${ar}" t "${prefix}/lib/librockCompiler.a" > "${record}" || return
  [[ -s "${record}" ]] || { printf 'Empty installed rocMLIR archive\n' >&2; return 1; }
}

# Both input hashing and presence checks enumerate this same installed package closure.
migraphx_rocmlir_payload_files() {
  local -n selected_files="$1"
  local index
  selected_files=(
    lib/librockCompiler.a lib/cmake/rocmlir/rocmlir-config.cmake lib/cmake/rocmlir/rocmlir-config-version.cmake
    lib/cmake/rocmlir/rocmlir-targets.cmake include/rocmlir/mlir-c/RegisterRocMLIR.h
    include/rocmlir/mlir-c/Dialect/MIGraphX.h include/rocmlir/external/include/mlir-c/IR.h
  )
  for index in "${!selected_files[@]}"; do
    selected_files[index]="$2/${selected_files[index]}"
  done
}

# Hash validation is non-destructive because the installed prefix is an input to consumer proofs.
migraphx_verify_rocmlir_notices() {
  cmp -- "$1/SOURCE-NOTICE-SHA256SUMS" "$2" || return
  (cd "$1" && sha256sum --check "$2")
}
