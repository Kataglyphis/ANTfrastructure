#!/usr/bin/env bash
# Static parser dependencies retain original notices; this transport alone does not prove the GPU backend.
migraphx_dep_cxx_standard() {
  if [[ "$1" == ck ]]; then printf '20\n'; else printf '17\n'; fi
}

migraphx_static_dep_args() {
  local -n dep_args="$1"
  local dep="$2" dep_work="$3" dep_source="$3/$2-source" dep_prefix="$3/host-deps" standard
  standard="$(migraphx_dep_cxx_standard "${dep}")" || return
  if [[ "${dep}" == ck ]]; then dep_source+="/codegen"; dep_prefix+=";$3/host-tools"; fi
  dep_args=(
    "-DCMAKE_INSTALL_PREFIX=${dep_work}/host-deps" "-DCMAKE_PREFIX_PATH=${dep_prefix}"
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_STANDARD=${standard}"
    -DBUILD_SHARED_LIBS:BOOL=OFF -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
    -DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON -DFETCHCONTENT_UPDATES_DISCONNECTED:BOOL=ON
  )
  case "${dep}" in
    abseil)
      dep_args+=(-DABSL_ENABLE_INSTALL:BOOL=ON -DABSL_PROPAGATE_CXX_STD:BOOL=ON -DABSL_BUILD_TESTING:BOOL=OFF)
      ;;
    protobuf)
      dep_args+=(
        -Dprotobuf_BUILD_TESTS:BOOL=OFF -Dprotobuf_BUILD_SHARED_LIBS:BOOL=OFF -Dprotobuf_INSTALL:BOOL=ON
        -Dprotobuf_BUILD_LIBPROTOC:BOOL=ON -Dprotobuf_BUILD_PROTOC_BINARIES:BOOL=ON
        -Dprotobuf_BUILD_PROTOBUF_BINARIES:BOOL=ON -Dprotobuf_WITH_ZLIB:BOOL=OFF
        -Dprotobuf_LOCAL_DEPENDENCIES_ONLY:BOOL=ON -Dprotobuf_FORCE_FETCH_DEPENDENCIES:BOOL=OFF
      )
      ;;
    ck)
      dep_args+=(-DEMBED_USE:STRING=CArrays -DBUILD_TESTING:BOOL=OFF)
      ;;
    *) printf 'Unknown MIGraphX static dependency: %s\n' "${dep}" >&2; return 2 ;;
  esac
  migraphx_cmake_directories "$1" "${dep_source}" "${dep_work}/${dep}-build"
}

migraphx_stage_dep_notices() {
  local dep="$1" dep_work="$2" notice_root="$2/host-deps/share/licenses"
  mkdir -p "${notice_root}/${dep}" || return
  cp "${dep_work}/${dep}-source/LICENSE" "${notice_root}/${dep}/LICENSE" || return
  if [[ "${dep}" == protobuf ]]; then
    mkdir -p "${notice_root}/utf8_range" || return
    cp "${dep_work}/protobuf-source/third_party/utf8_range/LICENSE" "${notice_root}/utf8_range/LICENSE" || return
  fi
}

migraphx_build_static_dep() {
  local dep="$1" archive="$2" digest="$3" dep_work="$4"
  local -a selected_args=()
  migraphx_static_dep_args selected_args "${dep}" "${dep_work}" || return
  migraphx_native_cmake_args selected_args "$5" "$6" || return
  migraphx_prepare_source_tree "${archive}" "${digest}" "${dep_work}/${dep}-source" || return
  append_cmake_cache_linker_args selected_args || return
  [[ -n "${CMAKE_COMPILER_CACHE_PIN:-}" ]] || { printf 'Missing compiler-cache pin for parser dependency\n' >&2; return 1; }
  cmake "${selected_args[@]}" || return
  cmake_assert_compiler_cache_pin "${dep_work}/${dep}-build" "${CMAKE_COMPILER_CACHE_PIN:-}" || return
  cmake_assert_configured_entries "${dep_work}/${dep}-build" bool \
    BUILD_SHARED_LIBS=OFF CMAKE_POSITION_INDEPENDENT_CODE=ON FETCHCONTENT_FULLY_DISCONNECTED=ON || return
  cmake_assert_configured_entries "${dep_work}/${dep}-build" first \
    "CMAKE_C_COMPILER=$5/bin/clang" "CMAKE_CXX_COMPILER=$5/bin/clang++" "CMAKE_CXX_STANDARD=$(migraphx_dep_cxx_standard "${dep}")" || return
  cmake --build "${dep_work}/${dep}-build" --parallel "${JOBS:-2}" || return
  cmake --install "${dep_work}/${dep}-build" || return
  migraphx_stage_dep_notices "${dep}" "${dep_work}"
}
