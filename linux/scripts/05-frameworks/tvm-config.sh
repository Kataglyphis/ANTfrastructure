#!/usr/bin/env bash
# tvm-config.sh - CMake argument construction helpers for TVM builds
# Split out of tvm.sh (pure structural refactor; no behavior change).
# Source-only helper; sourced by tvm.sh — expects its shell options.

cross_linker_search_flags() {
  local triplet=""
  local flags=""
  local dir

  if ! cross_build_is_active; then
    printf '%s' ""
    return 0
  fi

  triplet="$(cross_target_triplet 2>/dev/null || true)"
  [ -n "${triplet}" ] || {
    printf '%s' ""
    return 0
  }

  for dir in \
    "/usr/lib/${triplet}" \
    "/lib/${triplet}" \
    "/usr/${triplet}/lib"; do
    [ -d "${dir}" ] || continue
    flags="${flags:+${flags} }-L${dir}"
  done

  printf '%s' "${flags}"
}

append_tvm_cmake_args() {
  local out_name="$1"
  local python_module="$2"
  local build_type="$3"
  local desired_cc="$4"
  local desired_cxx="$5"
  local llvm_cmake_value="$6"
  local llvm_dir="$7"
  local llvm_ignore_paths="$8"
  local use_vulkan="$9"
  local use_cuda="${10:-0}"
  local use_opencl="${11:-0}"
  local spirv_tools_lib="${12:-}"
  local cross_link_flags="${13:-}"
  local -n out_ref="${out_name}"

  # Normalize 0/1 booleans to OFF/ON for TVM's CMake (which accepts both forms,
  # but ON/OFF is what its docs and validate scripts print).
  local cuda_flag="OFF"
  local opencl_flag="OFF"
  if [ "${use_cuda:-0}" -eq 1 ]; then cuda_flag="ON"; fi
  if [ "${use_opencl:-0}" -eq 1 ]; then opencl_flag="ON"; fi

  out_ref+=(
    -DCMAKE_BUILD_TYPE="$build_type"
    -DUSE_OPENCL="${opencl_flag}"
    -DUSE_CUDA="${cuda_flag}"
    "-DTVM_BUILD_PYTHON_MODULE=${python_module}"
  )

  if cross_build_is_active; then
    append_cmake_cross_args "${out_name}"
    out_ref+=( -DUSE_ALTERNATIVE_LINKER=OFF )
    if [ -n "${cross_link_flags:-}" ]; then
      out_ref+=(
        "-DCMAKE_EXE_LINKER_FLAGS=${cross_link_flags}${CMAKE_EXE_LINKER_FLAGS:+ ${CMAKE_EXE_LINKER_FLAGS}}"
        "-DCMAKE_SHARED_LINKER_FLAGS=${cross_link_flags}${CMAKE_SHARED_LINKER_FLAGS:+ ${CMAKE_SHARED_LINKER_FLAGS}}"
        "-DCMAKE_MODULE_LINKER_FLAGS=${cross_link_flags}${CMAKE_MODULE_LINKER_FLAGS:+ ${CMAKE_MODULE_LINKER_FLAGS}}"
      )
    fi
  fi

  if [ -n "${llvm_dir}" ]; then
    out_ref+=( -DLLVM_DIR="${llvm_dir}" )
    if [ -n "${llvm_ignore_paths}" ]; then
      out_ref+=( "-DCMAKE_IGNORE_PATH=${llvm_ignore_paths}${CMAKE_IGNORE_PATH:+;${CMAKE_IGNORE_PATH}}" )
    fi
  fi

  out_ref+=(
    -DCMAKE_C_COMPILER="$desired_cc"
    -DCMAKE_CXX_COMPILER="$desired_cxx"
  )

  if [ "$use_vulkan" -eq 1 ]; then
    out_ref+=( -DUSE_VULKAN=ON )
    if [ -n "${spirv_tools_lib:-}" ]; then
      out_ref+=( -DVulkan_SPIRV_TOOLS_LIBRARY="${spirv_tools_lib}" )
    fi
  else
    out_ref+=( -DUSE_VULKAN=OFF )
  fi

  out_ref+=( -DUSE_LLVM="$llvm_cmake_value" )
}
