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
  llvm_host_target="$($llvm_config_path --host-target 2>/dev/null || true)"
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
    log "Sanitizing target LLVM CMake package: missing umbrella libLLVM under ${prefix}"
    sanitize_llvm_cmake_package_for_missing_umbrella_lib "${prefix}" "${llvm_dir}"
  fi
  llvm_cmake_package_has_component_metadata "${llvm_config_file}" || \
    die "Target LLVM package at ${llvm_dir} does not provide LLVM component metadata"
}

detect_llvm_major_version_from_metadata_file() {
  local metadata_file="$1"
  local line=""

  [ -f "${metadata_file}" ] || return 1

  while IFS= read -r line; do
    case "${line}" in
      *LLVM_VERSION_MAJOR* )
        if [[ "${line}" =~ LLVM_VERSION_MAJOR[^0-9]*([0-9]+) ]]; then
          printf '%s' "${BASH_REMATCH[1]}"
          return 0
        fi
        ;;
      *LLVM_PACKAGE_VERSION*|*PACKAGE_VERSION* )
        if [[ "${line}" =~ (LLVM_PACKAGE_VERSION|PACKAGE_VERSION)[^0-9]*([0-9]+) ]]; then
          printf '%s' "${BASH_REMATCH[2]}"
          return 0
        fi
        ;;
    esac
  done < "${metadata_file}"

  return 1
}

detect_llvm_major_version_from_cmake_package() {
  local llvm_dir="$1"
  local prefix=""
  local candidate=""
  local major=""

  [ -n "${llvm_dir}" ] || return 1

  for candidate in \
    "${llvm_dir}/LLVMConfigVersion.cmake" \
    "${llvm_dir}/LLVMConfig.cmake"; do
    major="$(detect_llvm_major_version_from_metadata_file "${candidate}" 2>/dev/null || true)"
    if [ -n "${major}" ]; then
      printf '%s' "${major}"
      return 0
    fi
  done

  prefix="$(llvm_cmake_package_prefix "${llvm_dir}" 2>/dev/null || true)"
  if [ -z "${prefix}" ]; then
    return 1
  fi

  for candidate in \
    "${prefix}/include/llvm/Config/llvm-config.h" \
    "${prefix}/include/llvm/Config/llvm-config.h.cmake"; do
    major="$(detect_llvm_major_version_from_metadata_file "${candidate}" 2>/dev/null || true)"
    if [ -n "${major}" ]; then
      printf '%s' "${major}"
      return 0
    fi
  done

  return 1
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
