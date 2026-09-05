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

# ── emit blocks ──────────────────────────────────────────────────────────────
# Each takes the caller's array NAME as $1 and appends in place; emission order
# is semantics (later -D wins). Internals stay `_tvm_`-prefixed so a caller
# array never collides with the nameref.
# docs/refactoring-backlog-archive-2026-08-31.md

# $1=array name  $2=cross link flags
_tvm_emit_cross_args() {
  local -n _tvm_emit_ref="$1"
  if cross_build_is_active; then
    append_cmake_cross_args "$1"
    _tvm_emit_ref+=( -DUSE_ALTERNATIVE_LINKER=OFF )
    if [ -n "${2:-}" ]; then
      _tvm_emit_ref+=(
        "-DCMAKE_EXE_LINKER_FLAGS=${2}${CMAKE_EXE_LINKER_FLAGS:+ ${CMAKE_EXE_LINKER_FLAGS}}"
        "-DCMAKE_SHARED_LINKER_FLAGS=${2}${CMAKE_SHARED_LINKER_FLAGS:+ ${CMAKE_SHARED_LINKER_FLAGS}}"
        "-DCMAKE_MODULE_LINKER_FLAGS=${2}${CMAKE_MODULE_LINKER_FLAGS:+ ${CMAKE_MODULE_LINKER_FLAGS}}"
      )
    fi
  fi
}

# $1=array name  $2=llvm dir  $3=llvm ignore paths
_tvm_emit_llvm_args() {
  local -n _tvm_emit_ref="$1"
  if [ -n "${2:-}" ]; then
    _tvm_emit_ref+=( -DLLVM_DIR="${2}" )
    if [ -n "${3:-}" ]; then
      _tvm_emit_ref+=( "-DCMAKE_IGNORE_PATH=${3}${CMAKE_IGNORE_PATH:+;${CMAKE_IGNORE_PATH}}" )
    fi
  fi
}

# $1=array name. Overrides TVM's internal USE_CCACHE=AUTO detection so the
# decision goes through compiler_cache_launcher() (sccache first, ccache
# fallback, guarded launcher when mounted).
_tvm_emit_compiler_cache_args() {
  local -n _tvm_emit_ref="$1"
  local _tvm_launcher
  compiler_cache_launcher_env 2>/dev/null || true
  _tvm_launcher="$(compiler_cache_launcher 2>/dev/null || true)"
  if [ -n "${_tvm_launcher}" ]; then
    _tvm_emit_ref+=(
      "-DCMAKE_C_COMPILER_LAUNCHER=${_tvm_launcher}"
      "-DCMAKE_CXX_COMPILER_LAUNCHER=${_tvm_launcher}"
    )
  fi
}

# $1=array name  $2=use vulkan (0/1)  $3=Vulkan_LIBRARY  $4=Vulkan_INCLUDE_DIR
# $5=Vulkan_SPIRV_TOOLS_LIBRARY
# For cross builds, point find_package(Vulkan) at the target-arch loader/
# headers (resolve_tvm_vulkan); otherwise it resolves the host x86_64 loader
# from the sourced SDK env and the target link fails "file in wrong format".
_tvm_emit_vulkan_args() {
  local -n _tvm_emit_ref="$1"
  if [ "${2}" -eq 1 ]; then
    _tvm_emit_ref+=( -DUSE_VULKAN=ON )
    if [ -n "${3:-}" ]; then
      _tvm_emit_ref+=( -DVulkan_LIBRARY="${3}" )
    fi
    if [ -n "${4:-}" ]; then
      _tvm_emit_ref+=( -DVulkan_INCLUDE_DIR="${4}" )
    fi
    if [ -n "${5:-}" ]; then
      _tvm_emit_ref+=( -DVulkan_SPIRV_TOOLS_LIBRARY="${5}" )
    fi
  else
    _tvm_emit_ref+=( -DUSE_VULKAN=OFF )
  fi
}

# Emits NOTHING. TVM_QNN_HOME is deliberately NOT local: tvm.sh reads it after
# the build to stage the QAIRT runtime beside the install.
# NO QNN FLAGS (corrected 2026-08-31, Windows backlog #154). USE_QNN and QNN_HOME
# are not TVM options and never were -- "no zip = USE_QNN=OFF (the upstream default)"
# was wrong twice: there is no such option and therefore no such default. TVM's own
# `qnn` is the Quantized Neural Network op dialect, an unrelated name; its Snapdragon
# path is USE_HEXAGON plus the separate Hexagon SDK, which is Linux-host/Android-target
# and needs USE_LLVM. TVM_QNN_HOME is still resolved: tvm.sh uses it to stage the QAIRT
# runtime beside the install, where the ORT QNN EP is what loads it.
_tvm_resolve_qnn_home() {
  TVM_QNN_HOME="${TVM_QNN_HOME:-}"
  if [ -z "${TVM_QNN_HOME}" ] && command -v resolve_qnn_sdk >/dev/null 2>&1; then
    TVM_QNN_HOME="$(resolve_qnn_sdk)"
  fi
}

# append_tvm_cmake_args --out ARRAY_NAME [--option VALUE ...]
# Option contract, and why locals are `_tvm_`-prefixed:
# docs/refactoring-backlog-archive-2026-08-31.md
append_tvm_cmake_args() {
  local _tvm_out_name=""
  local _tvm_python_module=""
  local _tvm_build_type=""
  local _tvm_desired_cc=""
  local _tvm_desired_cxx=""
  local _tvm_llvm_cmake_value=""
  local _tvm_llvm_dir=""
  local _tvm_llvm_ignore_paths=""
  local _tvm_use_vulkan=""
  local _tvm_use_cuda=0
  local _tvm_use_opencl=0
  local _tvm_spirv_tools_lib=""
  local _tvm_cross_link_flags=""
  local _tvm_vulkan_library=""
  local _tvm_vulkan_include=""
  local -A _tvm_seen=()
  local _tvm_opt

  while [ $# -gt 0 ]; do
    _tvm_opt="$1"
    [ $# -ge 2 ] || die "append_tvm_cmake_args: option '${_tvm_opt}' requires a value"
    case "${_tvm_opt}" in
      --out)               _tvm_out_name="$2" ;;
      --python-module)     _tvm_python_module="$2" ;;
      --build-type)        _tvm_build_type="$2" ;;
      --cc)                _tvm_desired_cc="$2" ;;
      --cxx)               _tvm_desired_cxx="$2" ;;
      --llvm-cmake-value)  _tvm_llvm_cmake_value="$2" ;;
      --llvm-dir)          _tvm_llvm_dir="$2" ;;
      --llvm-ignore-paths) _tvm_llvm_ignore_paths="$2" ;;
      --use-vulkan)        _tvm_use_vulkan="$2" ;;
      --use-cuda)          _tvm_use_cuda="$2" ;;
      --use-opencl)        _tvm_use_opencl="$2" ;;
      --spirv-tools-lib)   _tvm_spirv_tools_lib="$2" ;;
      --cross-link-flags)  _tvm_cross_link_flags="$2" ;;
      --vulkan-library)    _tvm_vulkan_library="$2" ;;
      --vulkan-include)    _tvm_vulkan_include="$2" ;;
      *) die "append_tvm_cmake_args: unknown option '${_tvm_opt}' (a typo here would otherwise silently emit the wrong TVM feature set)" ;;
    esac
    _tvm_seen["${_tvm_opt}"]=1
    shift 2
  done

  # A dropped option must fail HERE, not as a wrong -D flag hours into the compile.
  for _tvm_opt in --out --python-module --build-type --cc --cxx \
                  --llvm-cmake-value --llvm-dir --llvm-ignore-paths --use-vulkan; do
    # `+x` (not `:-`): unset key must be safe under `set -u` on bash 4.3.
    [ -n "${_tvm_seen[${_tvm_opt}]+x}" ] \
      || die "append_tvm_cmake_args: missing required option '${_tvm_opt}'"
  done
  [ -n "${_tvm_out_name}" ] || die "append_tvm_cmake_args: --out needs the NAME of the caller's array"

  local -n _tvm_out_ref="${_tvm_out_name}"

  # Normalize 0/1 booleans to OFF/ON for TVM's CMake (which accepts both forms,
  # but ON/OFF is what its docs and validate scripts print).
  local _tvm_cuda_flag="OFF"
  local _tvm_opencl_flag="OFF"
  if [ "${_tvm_use_cuda:-0}" -eq 1 ]; then _tvm_cuda_flag="ON"; fi
  if [ "${_tvm_use_opencl:-0}" -eq 1 ]; then _tvm_opencl_flag="ON"; fi

  _tvm_out_ref+=(
    -DCMAKE_BUILD_TYPE="${_tvm_build_type}"
    -DUSE_OPENCL="${_tvm_opencl_flag}"
    -DUSE_CUDA="${_tvm_cuda_flag}"
    "-DTVM_BUILD_PYTHON_MODULE=${_tvm_python_module}"
  )

  _tvm_emit_cross_args "${_tvm_out_name}" "${_tvm_cross_link_flags}"
  _tvm_emit_llvm_args "${_tvm_out_name}" "${_tvm_llvm_dir}" "${_tvm_llvm_ignore_paths}"

  _tvm_out_ref+=(
    -DCMAKE_C_COMPILER="${_tvm_desired_cc}"
    -DCMAKE_CXX_COMPILER="${_tvm_desired_cxx}"
  )

  _tvm_emit_compiler_cache_args "${_tvm_out_name}"
  _tvm_emit_vulkan_args "${_tvm_out_name}" "${_tvm_use_vulkan}" \
    "${_tvm_vulkan_library}" "${_tvm_vulkan_include}" "${_tvm_spirv_tools_lib}"
  _tvm_resolve_qnn_home

  _tvm_out_ref+=( -DUSE_LLVM="${_tvm_llvm_cmake_value}" )
}
