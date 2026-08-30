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
  local vulkan_library="${14:-}"
  local vulkan_include="${15:-}"
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

  # Compiler cache launcher — overrides TVM's internal USE_CCACHE=AUTO
  # detection so the decision goes through compiler_cache_launcher() (sccache
  # first, ccache fallback, guarded launcher when mounted).
  local _tvm_launcher
  _tvm_launcher="$(compiler_cache_launcher 2>/dev/null || true)"
  if [ -n "${_tvm_launcher}" ]; then
    out_ref+=(
      "-DCMAKE_C_COMPILER_LAUNCHER=${_tvm_launcher}"
      "-DCMAKE_CXX_COMPILER_LAUNCHER=${_tvm_launcher}"
    )
  fi

  if [ "$use_vulkan" -eq 1 ]; then
    out_ref+=( -DUSE_VULKAN=ON )
    # For cross builds, point find_package(Vulkan) at the target-arch loader/
    # headers (resolve_tvm_vulkan); otherwise it resolves the host x86_64 loader
    # from the sourced SDK env and the target link fails "file in wrong format".
    if [ -n "${vulkan_library:-}" ]; then
      out_ref+=( -DVulkan_LIBRARY="${vulkan_library}" )
    fi
    if [ -n "${vulkan_include:-}" ]; then
      out_ref+=( -DVulkan_INCLUDE_DIR="${vulkan_include}" )
    fi
    if [ -n "${spirv_tools_lib:-}" ]; then
      out_ref+=( -DVulkan_SPIRV_TOOLS_LIBRARY="${spirv_tools_lib}" )
    fi
  else
    out_ref+=( -DUSE_VULKAN=OFF )
  fi

  # QNN runtime (backlog QNN-LINUX, mirrors Windows build-tvm #121): arm64-only,
  # opt-in by staging the QAIRT zip; no zip = USE_QNN=OFF (the upstream default).
  # TVM_QNN_HOME is also consumed by tvm.sh for the post-install staging.
  TVM_QNN_HOME="${TVM_QNN_HOME:-}"
  if [ -z "${TVM_QNN_HOME}" ] && command -v resolve_qnn_sdk >/dev/null 2>&1; then
    TVM_QNN_HOME="$(resolve_qnn_sdk)"
  fi
  if [ -n "${TVM_QNN_HOME}" ]; then
    info "TVM: QNN runtime ON (SDK root ${TVM_QNN_HOME})"
    out_ref+=( -DUSE_QNN=ON "-DQNN_HOME=${TVM_QNN_HOME}" )
  else
    out_ref+=( -DUSE_QNN=OFF )
  fi

  out_ref+=( -DUSE_LLVM="$llvm_cmake_value" )
}
