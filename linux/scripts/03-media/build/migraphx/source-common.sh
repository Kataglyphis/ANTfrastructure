#!/usr/bin/env bash
# Preparation and dependency builds share verified extraction and the same source-built native compiler.
migraphx_prepare_source_tree() {
  cp "$1" "$3.tar.gz" || return
  download_verify_sha256 "$2" "$3.tar.gz" || return
  mkdir "$3" || return
  tar -xzf "$3.tar.gz" --strip-components=1 -C "$3"
}

migraphx_compiler_setup() {
  : "${MIGRAPHX_CLANG_PREFIX:=/opt/llvm-target}"
  local mgx_selected_clang="${MIGRAPHX_CLANG_PREFIX}" compiler_version mgx_selected_gcc
  compiler_version="$("${mgx_selected_clang}/bin/clang++" --version)" || return
  [[ "${compiler_version%%$'\n'*}" == "clang version ${LLVM_RELEASE} "* ]] || {
    printf 'MIGraphX requires the pinned source-built LLVM %s\n' "${LLVM_RELEASE}" >&2
    return 1
  }
  mgx_selected_gcc="$(gcc_toolchain_resolve_prefix)" || return
  printf -v "$1" '%s' "${mgx_selected_clang}"
  printf -v "$2" '%s' "${mgx_selected_gcc}"
  printf '%s\n' "${compiler_version}" > "$3"
}

migraphx_native_cmake_args() {
  local -n native_args="$1"
  local clang_prefix="$2" gcc_prefix="$3"
  native_args+=(
    "-DCMAKE_C_COMPILER=${clang_prefix}/bin/clang" "-DCMAKE_CXX_COMPILER=${clang_prefix}/bin/clang++"
    "-DCMAKE_C_COMPILER_EXTERNAL_TOOLCHAIN=${gcc_prefix}" "-DCMAKE_CXX_COMPILER_EXTERNAL_TOOLCHAIN=${gcc_prefix}"
  )
}

migraphx_new_work() {
  local mgx_work
  mkdir "$1" || return
  mgx_work="$(cd "$1" && pwd)" || return
  printf -v "$2" '%s' "${mgx_work}"
}

migraphx_prepare_native_work() {
  migraphx_new_work "$1" "$2" || return
  local -n selected_work="$2"
  migraphx_compiler_setup "$3" "$4" "${selected_work}/compiler.txt"
}

migraphx_prepare_rocm_cmake() {
  local tools_work="$1" tools_archive="$2"
  migraphx_prepare_source_tree "${tools_archive}" "${MIGRAPHX_ROCM_CMAKE_SOURCE_SHA256}" "${tools_work}/rocm-cmake-source" || return
  grep -Fx "rocm_setup_version(VERSION ${MIGRAPHX_ROCM_CMAKE_VERSION})" "${tools_work}/rocm-cmake-source/CMakeLists.txt" || return
  cmake -S "${tools_work}/rocm-cmake-source" -B "${tools_work}/rocm-cmake-build" -G Ninja \
    "-DCMAKE_INSTALL_PREFIX=${tools_work}/host-tools" || return
  cmake --install "${tools_work}/rocm-cmake-build" || return
  mkdir -p "${tools_work}/host-tools/share/licenses/rocm-cmake" || return
  cp "${tools_work}/rocm-cmake-source/LICENSE" "${tools_work}/host-tools/share/licenses/rocm-cmake/LICENSE"
}

migraphx_prepare_cmake_plan() {
  migraphx_cmake_directories "$1" "$5" "$6" || return
  migraphx_native_cmake_args "$1" "$2" "$3" || return
  append_cmake_cache_linker_args "$1" || return
  local -n planned_args="$1"
  printf '%s\0' "${planned_args[@]}" > "$4"
}

# Prepending the directory tuple retains caller option bytes and the array binding.
migraphx_cmake_directories() {
  local -n cmake_directory_args="$1"
  cmake_directory_args=(-S "$2" -B "$3" -G Ninja "${cmake_directory_args[@]}")
}

# Consumer configuration shares transport while retaining each caller's cache-entry and prefix verdicts.
migraphx_configure_native_consumer() {
  local -n mgx_native_consumer_argv="$1"
  mgx_native_consumer_argv=(-DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_STANDARD=$6" "${mgx_native_consumer_argv[@]}")
  migraphx_prepare_cmake_plan "$1" "$4" "$5" "$2/cmake-argv.nul" "$3" "$2/build" || return
  cmake "${mgx_native_consumer_argv[@]}" || return
  cmake_assert_compiler_cache_pin "$2/build" "${CMAKE_COMPILER_CACHE_PIN:-}" || return
  cmake_assert_configured_entries "$2/build" first "CMAKE_CXX_COMPILER=$4/bin/clang++" "CMAKE_CXX_STANDARD=$6" "${@:7}"
}

# One archive-selection verdict precedes both native consumer builds and preserves optional caller publication.
migraphx_build_native_consumer() {
  local mgx_selected_consumer_library
  mgx_selected_consumer_library="$(cat "$1/build/imported-library.txt")" || return
  [[ "${mgx_selected_consumer_library}" == "$2" ]] || {
    printf 'Consumer archive selection mismatch: got %s, expected %s\n' "${mgx_selected_consumer_library}" "$2" >&2
    return 1
  }
  if (( $# > 3 )); then
    printf -v "$4" '%s' "${mgx_selected_consumer_library}" || return
  fi
  cmake --build "$1/build" --parallel "$3"
}
