#!/usr/bin/env bash
# tvm-detect.sh - LLVM and SPIRV-Tools/Vulkan detection helpers for TVM builds
# Split out of tvm.sh (pure structural refactor; no behavior change).
# Source-only helper; sourced by tvm.sh — expects its shell options.

detect_llvm_config() {
  if [ -n "${TVM_LLVM_CONFIG:-}" ]; then
    echo "$TVM_LLVM_CONFIG"
    return 0
  fi

  local candidates=(
    "llvm-config-22"
    "llvm-config-21"
    "llvm-config-20"
    "llvm-config-19"
    "llvm-config-18"
    "llvm-config"
  )

  local c
  for c in "${candidates[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done

  echo ""
}

sanitize_llvm_config_for_target() {
  local llvm_config_path="$1"
  local llvm_host_target=""
  local llvm_host_arch=""
  local target_arch=""

  [ -n "$llvm_config_path" ] || {
    printf '%s' ""
    return 0
  }

  if ! cross_build_is_active; then
    printf '%s' "$llvm_config_path"
    return 0
  fi

  target_arch="$(cross_target_arch 2>/dev/null || true)"

  # If llvm-config can't run on the build host, --host-target yields nothing.
  # This happens when it's the cross target's own llvm-config (an ELF the host
  # can't exec). Passing it through would make CMake's FindLLVM invoke it and
  # choke on a "Syntax error" as the shell reads the binary as a script. Treat a
  # non-runnable llvm-config as unusable for the cross build and continue without
  # LLVM (the target LLVM CMake package is preferred and checked separately).
  if ! llvm_host_target="$("$llvm_config_path" --host-target 2>/dev/null)" \
     || [ -z "$llvm_host_target" ]; then
    log "Disabling TVM LLVM for cross target ${target_arch}: ${llvm_config_path} is not runnable on the build host" >&2
    printf '%s' ""
    return 0
  fi
  llvm_host_arch="$(arch_from_target_triple "$llvm_host_target" 2>/dev/null || true)"

  if [ -n "$target_arch" ] && [ -n "$llvm_host_arch" ] && [ "$llvm_host_arch" != "$target_arch" ]; then
    log "Disabling TVM LLVM for cross target ${target_arch}: ${llvm_config_path} reports host target ${llvm_host_target}, so it would link build-host LLVM archives into target binaries" >&2
    printf '%s' ""
    return 0
  fi

  printf '%s' "$llvm_config_path"
}

normalize_llvm_cmake_dir() {
  local dir="$1"
  local alt=""
  local config_path=""
  local resolved_dir=""

  [ -n "${dir}" ] || {
    printf '%s' ""
    return 0
  }

  config_path="$(readlink -f "${dir}/LLVMConfig.cmake" 2>/dev/null || true)"
  if [ -n "${config_path}" ] && [ -f "${config_path}" ]; then
    resolved_dir="$(dirname "${config_path}")"
    if [ "${resolved_dir}" != "${dir}" ]; then
      log "Normalizing LLVM CMake package path from ${dir} to ${resolved_dir}"
    fi
    printf '%s' "${resolved_dir}"
    return 0
  fi

  case "${dir}" in
    */lib64/cmake/llvm)
      alt="${dir%/lib64/cmake/llvm}/lib/cmake/llvm"
      ;;
    */lib/cmake/llvm)
      alt="${dir%/lib/cmake/llvm}/lib64/cmake/llvm"
      ;;
  esac

  config_path="$(readlink -f "${alt}/LLVMConfig.cmake" 2>/dev/null || true)"
  if [ -n "${alt}" ] && [ -n "${config_path}" ] && [ -f "${config_path}" ]; then
    resolved_dir="$(dirname "${config_path}")"
    log "Correcting LLVM CMake package path from ${dir} to ${resolved_dir}"
    printf '%s' "${resolved_dir}"
    return 0
  fi

  die "LLVM CMake package path is invalid: ${dir}"
}

detect_cross_llvm_cmake_dir() {
  local target_arch=""
  local dir=""

  if [ -n "${TVM_LLVM_DIR:-}" ]; then
    normalize_llvm_cmake_dir "${TVM_LLVM_DIR}"
    return 0
  fi

  if ! cross_build_is_active; then
    printf '%s' ""
    return 0
  fi

  target_arch="$(cross_target_arch 2>/dev/null || true)"
  [ -n "${target_arch}" ] || {
    printf '%s' ""
    return 0
  }

  if command -v llvm_cross_cmake_dir >/dev/null 2>&1; then
    dir="$(llvm_cross_cmake_dir "${target_arch}" 2>/dev/null || true)"
  fi

  if [ -n "${dir}" ]; then
    normalize_llvm_cmake_dir "${dir}"
    return 0
  fi

  if [ -z "${dir}" ] && command -v llvm_cross_install_prefix >/dev/null 2>&1; then
    local prefix=""
    prefix="$(llvm_cross_install_prefix "${target_arch}" 2>/dev/null || true)"
    for dir in \
      "${prefix}/lib/cmake/llvm" \
      "${prefix}/lib64/cmake/llvm"; do
      [ -f "${dir}/LLVMConfig.cmake" ] || continue
      normalize_llvm_cmake_dir "${dir}"
      return 0
    done
  fi

  printf '%s' "${dir}"
}

detect_vulkan_llvm_cmake_ignore_paths() {
  local prefix="${VULKAN_PREFIX:-/opt/vulkan}"
  local dir=""
  local out=""

  shopt -s nullglob
  for dir in \
    "${prefix}"/*/*/share/llvm/cmake \
    "${prefix}"/*/share/llvm/cmake; do
    [ -f "${dir}/LLVMConfig.cmake" ] || continue
    if [ -z "${out}" ]; then
      out="${dir}"
    else
      out="${out};${dir}"
    fi
  done
  shopt -u nullglob

  printf '%s' "${out}"
}

llvm_cmake_package_prefix() {
  case "$1" in
    */lib/cmake/llvm) printf '%s' "${1%/lib/cmake/llvm}" ;;
    */lib64/cmake/llvm) printf '%s' "${1%/lib64/cmake/llvm}" ;;
    *) return 1 ;;
  esac
}

llvm_cmake_package_has_umbrella_lib() {
  local prefix="$1"
  local candidate

  for candidate in \
    "${prefix}/lib/libLLVM.so" \
    "${prefix}/lib/libLLVM.a" \
    "${prefix}/lib64/libLLVM.so" \
    "${prefix}/lib64/libLLVM.a"; do
    [ -e "${candidate}" ] || continue
    return 0
  done

  return 1
}

validate_detected_llvm_cmake_package() {
  local llvm_dir="$1"
  local prefix llvm_config_file

  [ -n "${llvm_dir}" ] || return 0
  llvm_dir="$(normalize_llvm_cmake_dir "${llvm_dir}")"
  prefix="$(llvm_cmake_package_prefix "${llvm_dir}" 2>/dev/null || true)"
  [ -n "${prefix}" ] || return 0

  llvm_config_file="${llvm_dir}/LLVMConfig.cmake"
  [ -f "${llvm_config_file}" ] || die "LLVMConfig.cmake missing at ${llvm_config_file}"
  if ! llvm_cmake_package_has_umbrella_lib "${prefix}"; then
    # Was a call to sanitize_llvm_cmake_package_for_missing_umbrella_lib(), which
    # has never been defined anywhere in the tree (predates the tvm.sh split) —
    # so this branch previously died with a cryptic "command not found" (exit
    # 127) whenever it was reached. Fail closed with an actionable message
    # instead. If the sanitize-and-continue behavior is ever needed, implement
    # that helper in 02-toolchain/llvm-cross.sh next to the other package helpers.
    die "Target LLVM CMake package under ${prefix} is missing the umbrella libLLVM. TVM's cross build needs a target LLVM that ships libLLVM.so (build it with LLVM_LINK_LLVM_DYLIB=ON) or a CMake package that provides it."
  fi
  llvm_cmake_package_has_component_metadata "${llvm_config_file}" || \
    die "Target LLVM package at ${llvm_dir} does not provide LLVM component metadata"
}

detect_spirv_tools_library() {
  # TVM's Vulkan build requires the SPIRV-Tools *library*.
  local candidates=()

  # Map canonical arch → Vulkan SDK arch directory name.
  local _arch_dir
  case "${CROSS_TARGET_ARCH:-${TARGET_ARCH:-${TARGETARCH:-}}}" in
    amd64|x86_64)  _arch_dir="x86_64" ;;
    arm64|aarch64) _arch_dir="aarch64" ;;
    riscv64)       _arch_dir="riscv64" ;;
    *)             _arch_dir="" ;;
  esac

  shopt -s nullglob
  # 1) Target-arch path from cross-rebuilt SPIRV-Tools (Dockerfile.sdk).
  #    Placed under /opt/vulkan/<version>/<arch_dir>/lib/.
  if [ -n "${_arch_dir}" ]; then
    candidates+=(/opt/vulkan/*/"${_arch_dir}"/lib/libSPIRV-Tools.a)
    candidates+=(/opt/vulkan/*/"${_arch_dir}"/lib/libSPIRV-Tools-shared.so)
    candidates+=(/opt/vulkan/*/"${_arch_dir}"/lib/libSPIRV-Tools.so)
  fi
  # 2) Generic Vulkan SDK copy — may be host-arch only.
  candidates+=(/opt/vulkan/*/*/lib/libSPIRV-Tools.a)
  candidates+=(/opt/vulkan/*/*/lib/libSPIRV-Tools-shared.so)
  candidates+=(/opt/vulkan/*/*/lib/libSPIRV-Tools.so)
  # 3) VULKAN_SDK override.
  if [ -n "${VULKAN_SDK:-}" ]; then
    candidates+=("${VULKAN_SDK}/lib/libSPIRV-Tools.a")
    candidates+=("${VULKAN_SDK}/lib/libSPIRV-Tools-shared.so")
    candidates+=("${VULKAN_SDK}/lib/libSPIRV-Tools.so")
  fi
  shopt -u nullglob

  local c
  for c in "${candidates[@]}"; do
    if [ -r "$c" ]; then
      echo "$c"
      return 0
    fi
  done

  echo ""
  return 1
}

is_under_opt_vulkan() {
  case "${1:-}" in
    /opt/vulkan/*) return 0 ;;
    *) return 1 ;;
  esac
}

try_source_vulkan_env() {
  source_vulkan_sdk_env "${VULKAN_PREFIX:-/opt/vulkan}" sanitize-libs
}
