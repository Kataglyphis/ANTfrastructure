#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# rebuild-spirv-tools.sh
#
# Rebuilds SPIRV-Tools static libraries for both the target architecture and
# the host architecture.  The Vulkan SDK ships x86_64-only SPIRV-Tools;
# foreign arches (arm64/riscv64) need a cross-compiled libSPIRV-Tools.a for
# TVM to link without x86_64 arch mismatch.  The host rebuild fixes -Werror
# issues in the shipped host binary.
#
# Skipped entirely for amd64 (uses the SDK's prebuilt x86_64 SPIRV-Tools as-is).
#
# Called from Dockerfile.sdk after the Vulkan SDK is installed.

TARGET_ARCH="${TARGET_ARCH:-${TARGETARCH:-amd64}}"

find_spirv_source() {
  local d
  for d in /opt/vulkan/*/source/spirv-tools /opt/vulkan/*/source/SPIRV-Tools; do
    [ -d "$d" ] && printf '%s' "$d" && return 0
  done
  return 1
}

find_spirv_headers() {
  local src="$1" dir
  for dir in "$(dirname "$src")/SPIRV-Headers" "$(dirname "$src")/spirv-headers"; do
    [ -d "$dir" ] && printf '%s' "$dir" && return 0
  done
  return 1
}

# Print the first file matching find args, without pipefail issues.
find_first_file() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && printf '%s' "$f" && return 0
  done < <(find "$@" -type f 2>/dev/null || true)
  return 1
}

# Find the first subdirectory under /opt/vulkan (the SDK version dir).
find_vulkan_base() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] && printf '%s' "$d" && return 0
  done < <(find /opt/vulkan -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true)
  return 1
}

# Build SPIRV-Tools static lib in a subshell (isolates cd).
# Prints the path to libSPIRV-Tools.a on success.
build_spirv_tools() {
  local src="$1" headers="$2" build_dir="$3" cc="$4" cxx="$5"
  local -a cmake_args=(
    "$src"
    -DCMAKE_BUILD_TYPE=Release
    -DSPIRV_SKIP_TESTS=ON
    -DSPIRV_WERROR=OFF
    -DSPIRV-Headers_SOURCE_DIR="$headers"
    -DSPIRVHeaders_DIR="$headers"
  )
  [ -n "$cc"  ] && cmake_args+=(-DCMAKE_C_COMPILER="$cc")
  [ -n "$cxx" ] && cmake_args+=(-DCMAKE_CXX_COMPILER="$cxx")

  (
    mkdir -p "$build_dir"
    cd "$build_dir"
    cmake "${cmake_args[@]}"
    cmake --build . -j"$(nproc)" --target SPIRV-Tools-static
  )

  local lib
  lib="$(find_first_file "$build_dir" -name 'libSPIRV-Tools.a')" || return 1
  [ -n "$lib" ] || return 1
  printf '%s' "$lib"
}

main() {
  [ "$TARGET_ARCH" = "amd64" ] && {
    echo "SPIRV-Tools rebuild skipped for amd64 (using SDK prebuilt)"
    exit 0
  }

  local spirv_src spirv_headers
  spirv_src="$(find_spirv_source)" || {
    echo "SPIRV-Tools source not found under /opt/vulkan; rebuild skipped"
    exit 0
  }
  spirv_headers="$(find_spirv_headers "$spirv_src")" || {
    echo "ERROR: SPIRV-Headers not found near $spirv_src" >&2
    exit 1
  }

  local cross_tuple="" arch_dir=""
  case "$TARGET_ARCH" in
    arm64)   cross_tuple="aarch64-linux-gnu"; arch_dir="aarch64" ;;
    riscv64) cross_tuple="riscv64-linux-gnu";  arch_dir="riscv64" ;;
    *) echo "ERROR: Unsupported arch: $TARGET_ARCH" >&2; exit 1 ;;
  esac

  # --- Target-arch rebuild ---
  echo "Rebuilding SPIRV-Tools for target arch ${TARGET_ARCH} from ${spirv_src}"
  local target_lib
  target_lib="$(build_spirv_tools "$spirv_src" "$spirv_headers" \
    "/tmp/spirv-tools-${TARGET_ARCH}-build" \
    "${cross_tuple}-gcc" "${cross_tuple}-g++")" || {
    echo "ERROR: SPIRV-Tools target-arch build failed for ${TARGET_ARCH}" >&2
    exit 1
  }

  local vk_base
  vk_base="$(find_vulkan_base)" || {
    echo "ERROR: Vulkan SDK base dir not found under /opt/vulkan" >&2
    exit 1
  }
  mkdir -p "${vk_base}/${arch_dir}/lib"
  cp "$target_lib" "${vk_base}/${arch_dir}/lib/"
  echo "SPIRV-Tools rebuilt for target arch ${TARGET_ARCH}"

  # --- Host rebuild (always, for foreign arches) ---
  echo "Rebuilding SPIRV-Tools for host arch from ${spirv_src}"
  unset CC CXX CMAKE_C_COMPILER CMAKE_CXX_COMPILER || true
  local host_lib
  host_lib="$(build_spirv_tools "$spirv_src" "$spirv_headers" \
    "/tmp/spirv-tools-hostbuild" "" "")" || {
    echo "ERROR: SPIRV-Tools host-arch build failed" >&2
    exit 1
  }

  local vk_libdir="${vk_base}/x86_64/lib"
  [ -d "$vk_libdir" ] || {
    echo "ERROR: Vulkan SDK x86_64 lib dir not found at ${vk_libdir}" >&2
    exit 1
  }
  cp "$host_lib" "$vk_libdir/"
  echo "SPIRV-Tools rebuilt for host arch"
}

main "$@"
