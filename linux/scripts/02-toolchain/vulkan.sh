#!/usr/bin/env bash
set -euo pipefail
# vulkan.sh - Vulkan SDK install source-only helper.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

# Load downloads.sh directly when this file is sourced without the common.sh module chain.
# shellcheck source=bootstrap-import.sh
source "$(dirname "${BASH_SOURCE[0]}")/bootstrap-import.sh" || return $?
source_toolchain_downloads "${BASH_SOURCE[0]}"
source_toolchain_required "$(dirname "${BASH_SOURCE[0]}")" path-helpers.sh exit core-paths-only path_symlink_missing

# Logs the link-time .so symlinks vulkan-tools needs, so a later "cannot find -lxcb" is diagnosable.
_vulkan_report_wsi_link_libs() {
  local t l
  t="$(arch_deb_multiarch_triplet_for "$(cross_target_arch)" 2>/dev/null || true)"
  [ -n "${t}" ] || return 0
  for l in libxcb libX11 libwayland-client; do
    if [ -e "/usr/lib/${t}/${l}.so" ]; then
      log "WSI link lib present: /usr/lib/${t}/${l}.so"
    else
      warn "WSI link lib MISSING: /usr/lib/${t}/${l}.so — vulkan-tools cannot link"
    fi
  done
}



# default install location - overrideable from environment
VULKAN_INSTALL_ROOT="${VULKAN_INSTALL_ROOT:-/opt/vulkan}"
# custom tmp directory - overrideable from environment
VULKAN_TMP_DIR="${VULKAN_TMP_DIR:-/opt/tmp}"

filter_colon_list_excluding_prefix() {
  local list="${1:-}"
  local prefix="${2:-}"
  local out=""
  local entry
  local old_ifs="${IFS}"
  local -a entries=()

  [ -n "${list}" ] || {
    printf '%s' ""
    return 0
  }

  IFS=':' read -r -a entries <<< "${list}"
  IFS="${old_ifs}"
  for entry in "${entries[@]}"; do
    [ -n "${entry}" ] || continue
    case "${entry}" in
      "${prefix}"*)
        continue
        ;;
    esac
    out="${out:+${out}:}${entry}"
  done

  printf '%s' "${out}"
}

sanitize_vulkan_sdk_env() {
  local prefix="${1:-/opt/vulkan/}"

  if [ "${VULKAN_KEEP_SDK_LIBS:-0}" = "1" ]; then
    return 0
  fi

  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    LD_LIBRARY_PATH="$(filter_colon_list_excluding_prefix "${LD_LIBRARY_PATH}" "${prefix}")"
    export LD_LIBRARY_PATH
  fi

  if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    CMAKE_PREFIX_PATH="$(filter_colon_list_excluding_prefix "${CMAKE_PREFIX_PATH}" "${prefix}")"
    export CMAKE_PREFIX_PATH
  fi
}

# vulkan-env.sh is split out so launchers can reuse it without this file's `set -euo pipefail`.
if ! declare -F vulkan_env_source >/dev/null 2>&1; then
  for _vulkan_env_mod in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/vulkan-env.sh" \
    "/opt/scripts/core/vulkan-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vulkan-env.sh"; do
    if [ -f "${_vulkan_env_mod}" ]; then
      # shellcheck disable=SC1090
      source "${_vulkan_env_mod}"
      break
    fi
  done
  unset _vulkan_env_mod
fi

source_vulkan_sdk_env() {
  local prefix="${1:-${VULKAN_PREFIX:-${VULKAN_INSTALL_ROOT}}}"
  local sanitize_mode="${2:-keep-libs}"

  # Report a miss so callers take their fallback instead of dying on exit 127.
  declare -F vulkan_env_source >/dev/null 2>&1 || return 1

  # strict=1 explicitly: this function's callers gate on its `return 1`.
  vulkan_env_source "${prefix}" "${sanitize_mode}" 1
}

# <multiarch dir> <library>: 0 when the library's ELF machine is the dir's arch; a foreign or unreadable one is refused (CON172: the host's x86-64 libstdc++ sat in /usr/lib/aarch64-linux-gnu).
_vulkan_lib_fits_dir() {
  local want machine
  case "${1##*/}" in
    x86_64-linux-gnu)  want="X86-64" ;;
    aarch64-linux-gnu) want="AArch64" ;;
    riscv64-linux-gnu) want="RISC-V" ;;
    *) return 0 ;;
  esac
  machine="$(elf_machine_name "$(readlink -f "$2")" 2>/dev/null || true)"
  case "${machine}" in *"${want}"*) return 0 ;; esac
  return 1
}

_vulkan_setup_gcc_runtime() {
  ARCH_LIB_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "${ARCH}-linux-gnu")"
  ${SUDO:-} mkdir -p "${ARCH_LIB_DIR}" /usr/lib
  if [[ -n "${LIBRARY_PATH:-}" ]]; then
    log "Setting up GCC runtime library symlinks for linking..."
    # IFS=':' read splits regardless of the caller's IFS; ${var//:/ } would not under IFS=$'\n\t'.
    local -a _vk_libdirs=()
    IFS=':' read -r -a _vk_libdirs <<< "${LIBRARY_PATH}"
    for libdir in "${_vk_libdirs[@]}"; do
      [ -n "${libdir}" ] || continue
      for lib in libgcc_s.so.1 libgcc_s.so libstdc++.so.6 libstdc++.so; do
        if [[ -f "${libdir}/${lib}" ]] && ! _vulkan_lib_fits_dir "${ARCH_LIB_DIR}" "${libdir}/${lib}"; then
          log "GCC runtime: ${libdir}/${lib} is not ${ARCH_LIB_DIR##*/}'s arch; not linked there (CON172)"
          continue
        fi
        if [[ -f "${libdir}/${lib}" ]]; then
          if [[ ! -e "${ARCH_LIB_DIR}/${lib}" ]]; then
            ${SUDO:-} ln -sf "${libdir}/${lib}" "${ARCH_LIB_DIR}/${lib}" 2>/dev/null || true
          fi
          if [[ ! -e "/usr/lib/${lib}" ]]; then
            ${SUDO:-} ln -sf "${libdir}/${lib}" "/usr/lib/${lib}" 2>/dev/null || true
          fi
        fi
      done
    done
    log "Symlinked GCC runtime libraries to ${ARCH_LIB_DIR} and /usr/lib"
  fi
  ${SUDO:-} ldconfig 2>/dev/null || true
}

_vulkan_setup_sdk_includes() {
  local arch_suffix="$1"
  local target_triplet="$2"
  local target_dir="$3"

  SDK_ARCHDIR="${target_dir}/${arch_suffix}"
  if [[ ! -d "${SDK_ARCHDIR}" ]]; then
    SDK_ARCHDIR="${target_dir}/$(uname -m)"
  fi
  if [[ -d "${SDK_ARCHDIR}" ]]; then
    local target_include_dir="/usr/${target_triplet}/include"
    log "Preferring Vulkan SDK headers and CMake packages from ${SDK_ARCHDIR}"
    export CMAKE_PREFIX_PATH="${SDK_ARCHDIR}:${SDK_ARCHDIR}/share/cmake:${SDK_ARCHDIR}/lib/cmake${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
    if [[ -d "${SDK_ARCHDIR}/include" ]]; then
      ${SUDO:-} mkdir -p /usr/include /usr/local/include "${target_include_dir}"
      for entry in X11 xcb GL KHR EGL GLES2 GLES3; do
        if [[ -e "/usr/include/${entry}" ]]; then
          path_symlink_missing "/usr/include/${entry}" "${target_include_dir}/${entry}" -s optional
        fi
      done
      local header base
      for header in /usr/include/wayland*.h /usr/include/xf86drm*.h; do
        [[ -e "${header}" ]] || continue
        base="$(basename "${header}")"
        path_symlink_missing "${header}" "${target_include_dir}/${base}" -s optional
      done
      export CMAKE_INCLUDE_PATH="${SDK_ARCHDIR}/include:/usr/include${CMAKE_INCLUDE_PATH:+:${CMAKE_INCLUDE_PATH}}"
      # Never put /usr/include in CPATH: it breaks libstdc++'s `#include_next <stdlib.h>`.
      export CPATH="${SDK_ARCHDIR}/include${CPATH:+:${CPATH}}"
      export C_INCLUDE_PATH="${SDK_ARCHDIR}/include${C_INCLUDE_PATH:+:${C_INCLUDE_PATH}}"
      export CPLUS_INCLUDE_PATH="${SDK_ARCHDIR}/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
    fi

    _symlink_sdk_include() {
      local name="$1" target_include_dir="$2" sdkincludedir="$3"
      if [ -d "${sdkincludedir}/include/${name}" ]; then
        ${SUDO:-} mkdir -p /usr/include /usr/local/include "${target_include_dir}"
        ${SUDO:-} rm -rf "/usr/include/${name}" "/usr/local/include/${name}" "${target_include_dir}/${name}"
        ${SUDO:-} ln -s "${sdkincludedir}/include/${name}" "/usr/include/${name}"
        ${SUDO:-} ln -s "${sdkincludedir}/include/${name}" "/usr/local/include/${name}"
        ${SUDO:-} ln -s "${sdkincludedir}/include/${name}" "${target_include_dir}/${name}"
      fi
    }
    log "Replacing standard Vulkan include paths with SDK headers"
    _symlink_sdk_include vulkan "${target_include_dir}" "${SDK_ARCHDIR}"
    _symlink_sdk_include vk_video "${target_include_dir}" "${SDK_ARCHDIR}"
  fi
}

_vulkan_setup_cross_pkgconfig() {
  local target_triplet="$1"

  if cross_build_is_active; then
    unset PKG_CONFIG_PATH
    export PKG_CONFIG_ALLOW_CROSS=1
    export PKG_CONFIG_SYSROOT_DIR=/
    local host_pkgconfig="/usr/share/pkgconfig:/usr/local/lib/pkgconfig"
    local host_multiarch="${DEB_BUILD_MULTIARCH:-}"
    if [ -z "${host_multiarch}" ]; then
      host_multiarch="$(dpkg-architecture -qDEB_BUILD_MULTIARCH 2>/dev/null || build_deb_multiarch_triplet)"
    fi
    if [ -n "${host_multiarch}" ]; then
      host_pkgconfig="/usr/lib/${host_multiarch}/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig"
    fi
    # _vulkan_run_vulkansdk builds HOST tools and must search ONLY this half.
    export VULKAN_HOST_PKG_CONFIG_LIBDIR="${host_pkgconfig}"
    if command -v cross_pkg_config_libdir >/dev/null 2>&1; then
      export PKG_CONFIG_LIBDIR; PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${target_triplet}"):${host_pkgconfig}"
    else
      export PKG_CONFIG_LIBDIR="/usr/${target_triplet}/lib/pkgconfig:/usr/lib/${target_triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
    fi
    log "Using cross pkg-config search path ${PKG_CONFIG_LIBDIR}"
  fi
}

_vulkan_build_components() {
  local arch_suffix="$1"
  local -n _vulkan_sdk_components_ref="$2"

  log "Building selected SDK components..."
  JOBS="$(compute_jobs "${JOBS:-}")"
  _vulkan_sdk_components_ref=(
    glslang vulkan-headers vulkan-loader
    vulkan-validationlayers shaderc spirv-headers spirv-tools
    vulkan-extensionlayer volk vma vul
    spirv-cross spirv-reflect vulkan-profiles
  )

  # Never arch-skip. See docs/vulkan-foreign-arch-sdk.md § amd64 is the reference: all three arches build the same set
  _vulkan_sdk_components_ref+=(vulkan-tools gfxreconstruct vcv slang vulkantools dxc cdl)
}

# Checkouts the target build wants when ./vulkansdk skipped them. See docs/vulkan-foreign-arch-sdk.md
_VK_SOURCE_ONLY="Vulkan-Tools:https://github.com/KhronosGroup/Vulkan-Tools.git"

_vulkan_fetch_source_only() {
  local target_dir="$1" version="$2" row name url dest

  [ -n "${version}" ] || { log "no Vulkan version in scope; skipping the source-only fetch"; return 0; }
  for row in ${_VK_SOURCE_ONLY}; do
    name="${row%%:*}"
    url="${row#*:}"
    dest="${target_dir}/source/${name}"
    [ -d "${dest}" ] && continue
    log "Fetching ${name} (vulkan-sdk-${version}) for the target build"
    ${SUDO:-} git clone --depth 1 --branch "vulkan-sdk-${version}" "${url}" "${dest}" \
      || log "${name}: source fetch failed; the target build will skip it"
  done
}

# See docs/vulkan-foreign-arch-sdk.md § The host build must not inherit the cross pkg-config path
_vulkan_pkgconfig_use_host() {
  [ -n "${VULKAN_HOST_PKG_CONFIG_LIBDIR:-}" ] || return 0
  export PKG_CONFIG_LIBDIR="${VULKAN_HOST_PKG_CONFIG_LIBDIR}"
  unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_ALLOW_CROSS
  log "Host SDK build uses host-only pkg-config path ${PKG_CONFIG_LIBDIR}"
}

_vulkan_pkgconfig_restore() {
  [ -n "$1" ] && export PKG_CONFIG_LIBDIR="$1" || unset PKG_CONFIG_LIBDIR
  [ -n "$2" ] && export PKG_CONFIG_SYSROOT_DIR="$2" || unset PKG_CONFIG_SYSROOT_DIR
  [ -n "$3" ] && export PKG_CONFIG_ALLOW_CROSS="$3" || unset PKG_CONFIG_ALLOW_CROSS
}

_vulkan_run_vulkansdk() {
  # ./vulkansdk runs a bare sudo'd `apt-get install` that aborts at the prompt without global assume-yes.
  ${SUDO:-} tee /etc/apt/apt.conf.d/90assume-yes >/dev/null <<'EOF'
APT::Get::Assume-Yes "true";
EOF
  export DEBIAN_FRONTEND=noninteractive

  # ./vulkansdk builds host tools, so it must not see the cross compilers.
  local _saved_cc="${CC:-}" _saved_cxx="${CXX:-}"
  local _saved_cmake_cc="${CMAKE_C_COMPILER:-}" _saved_cmake_cxx="${CMAKE_CXX_COMPILER:-}"
  unset CC CXX CMAKE_C_COMPILER CMAKE_CXX_COMPILER

  local _saved_pc_libdir="${PKG_CONFIG_LIBDIR:-}" _saved_pc_sysroot="${PKG_CONFIG_SYSROOT_DIR:-}"
  local _saved_pc_cross="${PKG_CONFIG_ALLOW_CROSS:-}"
  _vulkan_pkgconfig_use_host

  # Shims append -Wno-error last: GCC 16 false positives hit -Werror, and env CXXFLAGS land before it.
  local _cc_shim_dir _real_cc _real_cxx _shim
  _cc_shim_dir="$(mktemp -d)"
  _real_cc="$(command -v cc || command -v gcc || echo /usr/bin/cc)"
  _real_cxx="$(command -v c++ || command -v g++ || echo /usr/bin/c++)"
  for _shim in cc gcc; do
    printf '#!/bin/sh\nexec "%s" "$@" -Wno-error\n' "${_real_cc}" > "${_cc_shim_dir}/${_shim}"
  done
  for _shim in c++ g++; do
    printf '#!/bin/sh\nexec "%s" "$@" -Wno-error\n' "${_real_cxx}" > "${_cc_shim_dir}/${_shim}"
  done
  chmod +x "${_cc_shim_dir}"/*
  export PATH="${_cc_shim_dir}:${PATH}"

  # --preserve-env only with sudo: with SUDO empty the shell runs the flag as the command (exit 127).
  if [ -n "${SUDO:-}" ]; then
    ${SUDO} --preserve-env=PATH,CMAKE_C_COMPILER_LAUNCHER,CMAKE_CXX_COMPILER_LAUNCHER,SCCACHE_SERVER_UDS,SCCACHE_DIR,LD_LIBRARY_PATH,LIBRARY_PATH,PKG_CONFIG_PATH,PKG_CONFIG_LIBDIR,PKG_CONFIG_ALLOW_CROSS,PKG_CONFIG_SYSROOT_DIR,CMAKE_PREFIX_PATH,CMAKE_INCLUDE_PATH,CPATH,C_INCLUDE_PATH,CPLUS_INCLUDE_PATH,DEBIAN_FRONTEND \
      ./vulkansdk -j "$JOBS" "$@"
  else
    ./vulkansdk -j "$JOBS" "$@"
  fi
  _vulkan_pkgconfig_restore "${_saved_pc_libdir}" "${_saved_pc_sysroot}" "${_saved_pc_cross}"
  export CC="${_saved_cc}" CXX="${_saved_cxx}"
  [ -n "${_saved_cmake_cc}" ] && export CMAKE_C_COMPILER="${_saved_cmake_cc}" || unset CMAKE_C_COMPILER
  [ -n "${_saved_cmake_cxx}" ] && export CMAKE_CXX_COMPILER="${_saved_cmake_cxx}" || unset CMAKE_CXX_COMPILER
}

# See docs/artifact-copy-completeness.md § The Vulkan tree ships only what the image runs
_vulkan_prune_sdk_sources() {
  local target_dir="$1"

  [ -d "${target_dir}/source" ] || return 0
  log "Pruning the Vulkan SDK build tree at ${target_dir}/source"
  ${SUDO:-} rm -rf "${target_dir}/source"
}

# See docs/vulkan-foreign-arch-sdk.md § The DXC prune mirrors the vendor's own
_vulkan_target_prune_nonsdk_dxc() {
  local archdir="$1" rel

  [ -f "${archdir}/include/dxc/dxcapi.h" ] || return 0
  log "Pruning the DXC non-SDK files LunarG prunes from its own tarball under ${archdir}"
  for rel in include/clang include/clang-c include/llvm include/llvm-c \
             lib/libdxil.so lib/libLLVMDxilHash.a lib/libLLVMDxilValidation.a \
             lib/libdxcvalidator.a; do
    ${SUDO:-} rm -rf "${archdir:?}/${rel}"
  done
}

# ./vulkansdk runs its own cmake, which takes the launchers from the environment; the target builds also pin them.
_vulkan_export_compiler_cache() {
  local launcher=""
  if ! declare -F compiler_cache_launcher >/dev/null; then
    warn "compiler_cache_launcher is not loaded: the Vulkan SDK builds uncached"
    return 0
  fi
  compiler_cache_launcher_env 2>/dev/null || true
  launcher="$(compiler_cache_launcher 2>/dev/null || true)"
  [ -n "${launcher}" ] || return 0
  export CMAKE_C_COMPILER_LAUNCHER="${launcher}" CMAKE_CXX_COMPILER_LAUNCHER="${launcher}"
  log "Vulkan SDK compiles through ${launcher}"
}

_build_vulkan_sdk_cross() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"

  # Lazy, like setup-dependencies.sh's arms: the runtime image's copy of this file never cross-builds.
  source_toolchain_required "$(dirname "${BASH_SOURCE[0]}")" cmake-cache-linker.sh exit core-paths-only cmake_assert_compiler_cache_pin
  (
    cd "${target_dir}"
    ${SUDO:-} chmod +x vulkansdk

    log "Building vulkansdk for cross-build..."

    _vulkan_setup_gcc_runtime
    _vulkan_setup_sdk_includes "${arch_suffix}" "${target_triplet}" "${target_dir}"
    _vulkan_setup_cross_pkgconfig "${target_triplet}"

    local sdk_components=()
    _vulkan_build_components "${arch_suffix}" sdk_components
    _vulkan_export_compiler_cache
    _vulkan_run_vulkansdk "${sdk_components[@]}"

    # ./vulkansdk built host tools only. See docs/vulkan-foreign-arch-sdk.md
    _vulkan_fetch_source_only "${target_dir}" "${version:-${VULKAN_VERSION:-}}"
    _build_vulkan_targets "${arch_suffix}" "${target_dir}" "${target_triplet}"
    _vulkan_prune_sdk_sources "${target_dir}"
  )
}

# <ignore-ref> <ldflags-ref>: on a host whose arch is the target's; see docs/vulkan-foreign-arch-sdk.md § Building on a native arm64 host
_vulkan_native_host_link_args() {
  local -n _vnh_ignore="$1" _vnh_ldflags="$2"
  [ "${_xbuild_triplet}" = "$(arch_deb_multiarch_triplet_for "$(build_arch_oci)")" ] || return 0
  local _o _d
  for _o in x86_64-linux-gnu aarch64-linux-gnu riscv64-linux-gnu; do
    [ "${_o}" = "${_xbuild_triplet}" ] && continue
    [ -d "/usr/lib/${_o}" ] && _vnh_ignore="${_vnh_ignore:+${_vnh_ignore};}/usr/lib/${_o}"
  done
  [ -n "${_vnh_ignore}" ] && log "ignoring foreign multiarch lib dirs: ${_vnh_ignore}"
  # LIBRARY_PATH resolves a bare -lxcb without clobbering per-component CMake flags.
  for _d in "/usr/lib/${_xbuild_triplet}" "/lib/${_xbuild_triplet}"; do
    [ -d "${_d}" ] || continue
    case ":${LIBRARY_PATH:-}:" in *":${_d}:"*) ;; *) export LIBRARY_PATH="${_d}${LIBRARY_PATH:+:${LIBRARY_PATH}}" ;; esac
    _vnh_ldflags="${_vnh_ldflags:+${_vnh_ldflags} }-L${_d}"
  done
  return 0
}

# Usage: <src> <label> [cmake -D...]; reads the caller's _xbuild_* by dynamic scope, returns non-zero on failure.
_cross_build_sdk_component() {
  local src="$1" label="$2"
  shift 2
  local build_dir launcher="${CMAKE_CXX_COMPILER_LAUNCHER:-}"
  local -a cache_pin=()
  build_dir="$(mktemp -d)/${label}"
  append_cmake_compiler_cache_pin cache_pin "${launcher}"

  local _vk_ignore="" _vk_ldflags=""
  _vulkan_native_host_link_args _vk_ignore _vk_ldflags

  if ! cmake -S "${src}" -B "${build_dir}" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      ${_vk_ignore:+-DCMAKE_IGNORE_PATH="${_vk_ignore}"} \
      ${_vk_ldflags:+-DCMAKE_EXE_LINKER_FLAGS="${_vk_ldflags}"} \
      ${_vk_ldflags:+-DCMAKE_SHARED_LINKER_FLAGS="${_vk_ldflags}"} \
      ${_vk_ldflags:+-DCMAKE_MODULE_LINKER_FLAGS="${_vk_ldflags}"} \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR="${_xbuild_proc}" \
      -DCMAKE_C_COMPILER="${_xbuild_cc}" \
      -DCMAKE_CXX_COMPILER="${_xbuild_cxx}" \
      -DCMAKE_LIBRARY_ARCHITECTURE="${_xbuild_triplet}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      ${cache_pin[@]+"${cache_pin[@]}"} \
      "$@"; then
    log "${label}: cross-configure failed (non-fatal)"
    return 1
  fi
  cmake_assert_compiler_cache_pin "${build_dir}" "${launcher}" || err "${label}: the Vulkan component does not compile through ${launcher}"
  if ! cmake --build "${build_dir}" --parallel "$(compute_jobs "${JOBS:-}")"; then
    log "${label}: cross-build failed (non-fatal)"
    return 1
  fi
  local _t
  for _t in ${_xbuild_extra_targets[@]+"${_xbuild_extra_targets[@]}"}; do
    if ! cmake --build "${build_dir}" --target "${_t}"; then
      log "${label}: extra target ${_t} failed (non-fatal)"
      return 1
    fi
  done
  if ! ${SUDO:-} cmake --install "${build_dir}"; then
    log "${label}: install failed (non-fatal)"
    return 1
  fi
  return 0
}

# _build_vulkan_targets steps: plain-statement calls keep errexit live; _xbuild_*/_vk_* come by dynamic scope
_vulkan_target_copy_headers() {
  local arch_suffix="$1" host_archdir="$2" archdir="$3"

  ${SUDO:-} mkdir -p "${archdir}/lib" "${archdir}/include"
  # Headers are arch-independent; a failed cp with the source present is a real error, so warn.
  if [ -d "${host_archdir}/include/vulkan" ]; then
    ${SUDO:-} cp -a "${host_archdir}/include/vulkan" "${archdir}/include/" \
      || warn "vulkan headers present at ${host_archdir} but cp to ${archdir} failed (${arch_suffix})"
  fi
  if [ -d "${host_archdir}/include/vk_video" ]; then
    ${SUDO:-} cp -a "${host_archdir}/include/vk_video" "${archdir}/include/" \
      || warn "vk_video headers present at ${host_archdir} but cp to ${archdir} failed (${arch_suffix})"
  fi
}

# The loader's WSI entry points; each exists only when its BUILD_WSI_* option compiled in (docs/vulkan-foreign-arch-sdk.md#the-loader-carries-the-window-systems).
_VK_LOADER_WSI_SYMBOLS="vkCreateXcbSurfaceKHR vkCreateXlibSurfaceKHR vkCreateWaylandSurfaceKHR"

# Prints the WSI entry points the loader at $1 does not export; readelf, since it reads a foreign-arch ELF.
_vulkan_loader_wsi_missing() {
  local lib="$1" syms="" s missing=""
  if [ -f "${lib}" ]; then
    syms="$(readelf -W --dyn-syms "${lib}" 2>/dev/null || true)"
  fi
  for s in ${_VK_LOADER_WSI_SYMBOLS}; do
    grep -qw -- "${s}" <<<"${syms}" || missing="${missing} ${s}"
  done
  printf '%s' "${missing# }"
}

_vk_note_attempt() {
  _vk_attempted=$((_vk_attempted + 1))
  log "$*"
}

_vk_note_success() {
  _vk_ok=$((_vk_ok + 1))
  if [ "$#" -gt 0 ]; then log "$*"; fi
}

_vk_build_target_component() {
  local source="$1" label="$2" arch_suffix="$3" archdir="$4"
  shift 4
  _cross_build_sdk_component "$source" "${label}-${arch_suffix}" \
      -DCMAKE_INSTALL_PREFIX="$archdir" "$@"
}

# Loader with X11/XCB/Wayland WSI: the options are required pkg-config lookups, and the export check catches a silent drop.
_vulkan_target_build_loader() {
  local arch_suffix="$1" host_archdir="$2" archdir="$3" loader_src="$4"

  if [ -d "${loader_src}" ] && [ -d "${host_archdir}/include/vulkan" ]; then
    _vk_note_attempt "Cross-building Vulkan loader for ${arch_suffix}"
    if _vk_build_target_component "${loader_src}" "vulkan-loader" "${arch_suffix}" "${archdir}" \
        -DVULKAN_HEADERS_INSTALL_DIR="${host_archdir}" \
        -DBUILD_TESTS=OFF \
        -DBUILD_WSI_XCB_SUPPORT=ON \
        -DBUILD_WSI_XLIB_SUPPORT=ON \
        -DBUILD_WSI_XLIB_XRANDR_SUPPORT=ON \
        -DBUILD_WSI_WAYLAND_SUPPORT=ON \
        -DBUILD_WSI_DIRECTFB_SUPPORT=OFF; then
      local _wsi_missing
      _wsi_missing="$(_vulkan_loader_wsi_missing "${archdir}/lib/libvulkan.so.1")"
      if [ -n "${_wsi_missing}" ]; then
        _vk_note_failure vulkan-loader "Target Vulkan loader for ${arch_suffix} does not export ${_wsi_missing}; every windowed Vulkan app would abort"
      else
        _vk_note_success "Installed target Vulkan loader with X11/XCB/Wayland WSI: $(ls "${archdir}"/lib/libvulkan.so* 2>/dev/null | tr '\n' ' ')"
      fi
    else
      _vk_note_failure vulkan-loader "Target Vulkan loader unavailable; cross Vulkan will be disabled downstream"
    fi
  else
    log "Vulkan-Loader source or host headers missing; skipping target loader"
  fi
}

# SPIRV_WERROR=OFF: GCC 16's -Warray-bounds false positive on timer.h would fail -Werror.
_vulkan_target_build_spirv_tools() {
  local arch_suffix="$1" archdir="$2" spirv_tools_src="$3" spirv_headers_src="$4"

  if [ -d "${spirv_tools_src}" ]; then
    _vk_note_attempt "Cross-building SPIRV-Tools for ${arch_suffix}"
    if _vk_build_target_component "${spirv_tools_src}" "spirv-tools" "${arch_suffix}" "${archdir}" \
        -DSPIRV-Headers_SOURCE_DIR="${spirv_headers_src}" \
        -DSPIRV_SKIP_TESTS=ON \
        -DSPIRV_SKIP_EXECUTABLES=OFF \
        -DSPIRV_WERROR=OFF; then
      _vk_note_success "Installed target SPIRV-Tools: $(ls "${archdir}"/bin/spirv-* 2>/dev/null | wc -l) tools, $(ls "${archdir}"/lib/libSPIRV-Tools*.a 2>/dev/null | wc -l) libs"
    else
      _vk_note_failure spirv-tools "Target SPIRV-Tools unavailable; cross TVM Vulkan may fail to configure"
    fi
  else
    log "SPIRV-Tools source missing at ${spirv_tools_src}; skipping target SPIRV-Tools"
  fi
}

# Appends the label to the caller's _vk_failed (read by _vulkan_target_verdict) and logs the rest.
_vk_note_failure() {
  local label="$1"
  shift
  _vk_failed="${_vk_failed} ${label}"
  log "$*"
}

# See docs/vulkan-foreign-arch-sdk.md § Failures here are non-fatal on purpose
_vulkan_target_install_component() {
  local arch_suffix="$1" archdir="$2" src="$3" label="$4"
  shift 4

  [ -d "${src}" ] || { log "${label}: source missing at ${src}; skipping"; return 0; }
  _vk_note_attempt "Cross-building ${label} for ${arch_suffix}"
  if _vk_build_target_component "${src}" "${label}" "${arch_suffix}" "${archdir}" \
      -DCMAKE_PREFIX_PATH="${archdir}" \
      -DBUILD_TESTS=OFF \
      -DBUILD_TESTING=OFF \
      "$@"; then
    _vk_note_success
  else
    _vk_note_failure "${label}" "${label} unavailable on ${arch_suffix}; the target SDK ships without it"
  fi
}

# LunarG's checkout dir need not match the component name (shaderc's CMake project is in src/).
_vulkan_target_src() {
  local root="$1" d
  shift
  for d in "$@"; do
    [ -d "${root}/${d}" ] && { printf '%s' "${root}/${d}"; return 0; }
  done
  printf '%s' "${root}/$1"
}

# label | checkout candidates | cmake args; find_package(CONFIG) providers first, heavy rows last.
_VK_TARGET_COMPONENTS="
vulkan-headers|Vulkan-Headers|
spirv-headers|SPIRV-Headers|
vulkan-utility-libraries|Vulkan-Utility-Libraries|
volk|volk|-DVOLK_INSTALL=ON
vma|VulkanMemoryAllocator|
spirv-cross|SPIRV-Cross|-DSPIRV_CROSS_CLI=ON -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SHARED=ON
spirv-reflect|SPIRV-Reflect|-DSPIRV_REFLECT_EXECUTABLE=ON -DSPIRV_REFLECT_STATIC_LIB=ON
shaderc|shaderc/src,shaderc|-DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_ENABLE_INSTALL=ON
vulkan-tools|Vulkan-Tools|-DBUILD_VULKANINFO=ON -DBUILD_CUBE=ON
vulkan-extensionlayer|Vulkan-ExtensionLayer|
jsoncpp|jsoncpp|-DJSONCPP_WITH_TESTS=OFF -DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF -DJSONCPP_WITH_EXAMPLE=OFF -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON
valijson|valijson|-Dvalijson_BUILD_TESTS=OFF -Dvalijson_BUILD_EXAMPLES=OFF -Dvalijson_INSTALL_HEADERS=ON
yaml-cpp|yaml-cpp|-DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF -DYAML_CPP_BUILD_CONTRIB=OFF -DYAML_CPP_INSTALL=ON
vulkan-profiles|Vulkan-Profiles|-DPROFILES_BUILD_TESTS=OFF
vulkan-validationlayers|Vulkan-ValidationLayers|-DUPDATE_DEPS=OFF -DBUILD_WERROR=OFF
gfxreconstruct|gfxreconstruct|-DGFXRECON_BUILD_TESTS=OFF -DD3D12_SUPPORT=OFF -DGFXRECON_TOCPP_SUPPORT=OFF -DGFXRECON_INCLUDE_TEST_APPS=OFF -DGFXRECON_ENABLE_OPENXR=OFF
slang|slang|-DSLANG_ENABLE_TESTS=OFF -DSLANG_ENABLE_EXAMPLES=OFF -DSLANG_SLANG_LLVM_FLAVOR=DISABLE -DSLANG_ENABLE_DXIL=OFF
vulkancapsviewer|VulkanCapsViewer,vulkanCapsViewer,vcv|
vulkantools|VulkanTools|
crash-diagnostic-layer|CrashDiagnosticLayer|
dxc|DirectXShaderCompiler|-DLLVM_BUILD_TOOLS=OFF -DHLSL_COPY_GENERATED_SOURCES=ON -DCLANG_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF -DHLSL_INCLUDE_TESTS=OFF -DSPIRV_WERROR=OFF -DLLVM_ENABLE_WERROR=OFF
"

# $5 is an out-array name. See docs/vulkan-foreign-arch-sdk.md § Components that need a host tool
_vulkan_target_dynamic_args() {
  local label="$1" target_dir="$2" archdir="$3" triplet="$4"
  local -n _vk_dyn_ref="$5"
  local gen src

  _vk_dyn_ref=()
  _xbuild_extra_targets=()
  case "${label}" in
    slang)
      # Without the host generators the cross build runs a target slang-embed: exit 127.
      gen="${target_dir}/source/slang/build/generators/Release/bin"
      if [ -x "${gen}/slang-embed" ]; then
        _vk_dyn_ref+=(-DSLANG_GENERATORS_PATH="${gen}")
      else
        log "slang: no host generators at ${gen}; the cross build will try to run its own"
      fi
      # ./vulkansdk's build_slang() copies the .slang modules before install; the generic helper does not.
      _xbuild_extra_targets+=(copy-gfx-slang-modules)
      # slang-rhi's prebuilt Dawn is x86_64/aarch64 only; OFF stops the fetch, the empty URL the FATAL_ERROR.
      case "${triplet}" in
        x86_64-*|aarch64-*) ;;
        *) _vk_dyn_ref+=(-DSLANG_RHI_ENABLE_WGPU=OFF -DSLANG_RHI_DAWN_URL=) ;;
      esac
      ;;
    vulkancapsviewer)
      # Target Qt6 from the sysroot, host moc/rcc/uic from the build host's own.
      _vk_dyn_ref+=(-DQT_HOST_PATH=/usr)
      _vk_dyn_ref+=(-DCMAKE_PREFIX_PATH="${archdir};/usr/lib/${triplet}")
      # Upstream interpolates ${VULKAN_LOADER_INSTALL_DIR}/lib/libvulkan.so raw; unset, it is the host lib.
      _vk_dyn_ref+=(-DVULKAN_LOADER_INSTALL_DIR="${archdir}")
      ;;
    vulkantools)
      # REQUIRE_FIND_PACKAGE: upstream's find_package(Qt6 QUIET) silently drops vkconfig and still exits 0.
      _vk_dyn_ref+=(-DQT_HOST_PATH=/usr -DCMAKE_REQUIRE_FIND_PACKAGE_Qt6=TRUE)
      _vk_dyn_ref+=(-DCMAKE_PREFIX_PATH="${archdir};/usr/lib/${triplet}")
      _vk_dyn_ref+=(-DVULKAN_LOADER_INSTALL_DIR="${archdir}")
      _vk_dyn_ref+=(-DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="${archdir}")
      _vk_dyn_ref+=(-DJSONCPP_INSTALL_DIR="${archdir}" -DVALIJSON_INSTALL_DIR="${archdir}")
      _vk_dyn_ref+=(-DSDK_VERSION="${target_dir##*/}")
      ;;
    crash-diagnostic-layer)
      _vk_dyn_ref+=(-DVULKAN_UTILITY_LIBRARIES_INSTALL_DIR="${archdir}")
      _vk_dyn_ref+=(-DGLSLANG_INSTALL_DIR="${archdir}" -DYAML_CPP_INSTALL_DIR="${archdir}")
      ;;
    dxc)
      # DXC's options exist only once the vendor cache is read, and its tblgens must run on the host.
      src="$(_vulkan_target_src "${target_dir}/source" DirectXShaderCompiler)"
      [ -f "${src}/cmake/caches/PredefinedParams.cmake" ] \
        && _vk_dyn_ref+=(-C"${src}/cmake/caches/PredefinedParams.cmake")
      gen="${target_dir}/source/DirectXShaderCompiler/build/bin"
      if [ -x "${gen}/llvm-tblgen" ]; then
        _vk_dyn_ref+=(-DLLVM_TABLEGEN="${gen}/llvm-tblgen")
        [ -x "${gen}/clang-tblgen" ] && _vk_dyn_ref+=(-DCLANG_TABLEGEN="${gen}/clang-tblgen")
      else
        log "dxc: no host tblgen at ${gen}; the cross build will try to run its own"
      fi
      ;;
  esac
}

# See docs/vulkan-foreign-arch-sdk.md § Upstream patches: recheck on every SDK bump
_vulkan_patch_component() {
  local label="$1" src="$2" patch=""
  [ -n "${src}" ] && [ -d "${src}" ] || return 0
  # None carried since SDK 1.4.363.0, whose slang has PR #12305; a patch adds a case "${label}" arm setting patch.
  [ -n "${patch}" ] || return 0
  local dir="/opt/scripts/patches"
  [ -f "${dir}/${patch}" ] || { log "${label}: no ${patch} at ${dir}; skipping"; return 0; }
  bash "/opt/scripts/core/apply-patch.sh" "${dir}/${patch}" "${src}" "${label}: ${patch}"
}

# See docs/vulkan-foreign-arch-sdk.md
_vulkan_target_build_sdk_rest() {
  local arch_suffix="$1" archdir="$2" target_dir="$3" triplet="${4:-${_xbuild_triplet:-}}"
  local label cands extra src
  local -a dyn=() _xbuild_extra_targets=()

  while IFS='|' read -r label cands extra; do
    [ -n "${label}" ] || continue
    # shellcheck disable=SC2086  # both are deliberately word-split
    src="$(_vulkan_target_src "${target_dir}/source" ${cands//,/ })"
    _vulkan_patch_component "${label}" "${src}"
    _vulkan_target_dynamic_args "${label}" "${target_dir}" "${archdir}" "${triplet}" dyn
    # shellcheck disable=SC2086
    _vulkan_target_install_component "${arch_suffix}" "${archdir}" "${src}" "${label}" \
      -DVULKAN_HEADERS_INSTALL_DIR="${archdir}" \
      -DSPIRV_HEADERS_INSTALL_DIR="${archdir}" \
      ${extra} ${dyn[@]+"${dyn[@]}"}
  done <<EOF
${_VK_TARGET_COMPONENTS}
EOF
}

# Post-install name plumbing for the cross-built glslang.
_vulkan_target_link_glslang_aliases() {
  local archdir="$1"

  # New glslang installs `glslang`; KOMPUTE and older tooling look for `glslangValidator`.
  if [ -x "${archdir}/bin/glslang" ] && [ ! -e "${archdir}/bin/glslangValidator" ]; then
    ${SUDO:-} ln -s glslang "${archdir}/bin/glslangValidator"
  elif [ -x "${archdir}/bin/glslangValidator" ] && [ ! -e "${archdir}/bin/glslang" ]; then
    ${SUDO:-} ln -s glslangValidator "${archdir}/bin/glslang"
  fi
  # setup-env.sh puts only the x86_64 bin on PATH, so find_program() needs these in /usr/local/bin.
  for _b in glslang glslangValidator; do
    [ -e "${archdir}/bin/${_b}" ] && ${SUDO:-} ln -sf "${archdir}/bin/${_b}" "/usr/local/bin/${_b}"
  done
  # Load-bearing: the loop's last `[ -e ]` may be false and would trip errexit.
  return 0
}

# Builds that compile GLSL (KOMPUTE) need a glslangValidator that runs on the image's arch.
_vulkan_target_build_glslang() {
  local arch_suffix="$1" archdir="$2" target_dir="$3"

  local glslang_src="${target_dir}/source/glslang"
  [ -d "${glslang_src}" ] || glslang_src="${target_dir}/source/glslang-main"
  if [ -d "${glslang_src}" ]; then
    _vk_note_attempt "Cross-building glslang (glslangValidator) for ${arch_suffix}"
    # BUILD_SHARED_LIBS is exclusive, so two passes; static last, as it owns the exported CMake package.
    _vk_build_target_component "${glslang_src}" "glslang-shared" "${arch_suffix}" "${archdir}" \
        -DENABLE_OPT=OFF \
        -DGLSLANG_TESTS=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_GLSLANG_BINARIES=ON \
        -DENABLE_SPVREMAPPER=OFF \
        -DBUILD_SHARED_LIBS=ON \
      || log "glslang: shared pass failed; the prefix keeps the static half only"
    if _vk_build_target_component "${glslang_src}" "glslang" "${arch_suffix}" "${archdir}" \
        -DENABLE_OPT=OFF \
        -DGLSLANG_TESTS=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_GLSLANG_BINARIES=ON \
        -DENABLE_SPVREMAPPER=OFF \
        -DBUILD_SHARED_LIBS=OFF; then
      _vulkan_target_link_glslang_aliases "${archdir}"
      _vk_note_success "Installed target glslang: $(ls "${archdir}"/bin/glslang* 2>/dev/null | tr '\n' ' '); on PATH: $(command -v glslangValidator 2>/dev/null || echo none)"
    else
      _vk_note_failure glslang "Target glslang unavailable; GLSL shader compilation will fail on ${arch_suffix}"
    fi
  else
    log "glslang source missing at ${target_dir}/source/glslang; skipping target glslang"
  fi
}

# Without these the prefix is no Vulkan SDK, and each builds on both foreign lanes: a failure is a regression.
_VK_REQUIRED_COMPONENTS="${VULKAN_CROSS_REQUIRED-vulkan-loader spirv-tools glslang shaderc vulkan-tools vulkan-validationlayers}"

# A failed REQUIRED component is fatal here, not a baffling failure later; all-failed means a broken toolchain.
_vulkan_target_verdict() {
  local arch_suffix="$1" target_triplet="$2"
  local comp lost=""

  log "Vulkan cross-targets ${arch_suffix}: ${_vk_ok}/${_vk_attempted} component(s) built"
  for comp in ${_VK_REQUIRED_COMPONENTS}; do
    case " ${_vk_failed} " in *" ${comp} "*) lost="${lost} ${comp}" ;; esac
  done
  if [ -n "${lost}" ]; then
    die "REQUIRED Vulkan cross-component(s) failed for ${arch_suffix}:${lost} — the ${arch_suffix} prefix would ship without them and the runtime toolset gate would fail the lane later. Set VULKAN_CROSS_REQUIRED='' to build anyway."
  fi
  if [ "${_vk_attempted}" -gt 0 ] && [ "${_vk_ok}" -eq 0 ]; then
    warn "ALL ${_vk_attempted} Vulkan cross-component(s) FAILED for ${arch_suffix} (loader/SPIRV-Tools/glslang) — this is an env-shaped failure (broken ${target_triplet} toolchain?), not per-component optionality; downstream cross Vulkan will be disabled. Set VULKAN_CROSS_STRICT=1 to make this fatal."
    if [ "${VULKAN_CROSS_STRICT:-0}" = "1" ]; then
      die "VULKAN_CROSS_STRICT=1 and all ${_vk_attempted} Vulkan cross-components failed for ${arch_suffix}"
    fi
  fi
}

# Step order is a contract: headers before the loader. See docs/vulkan-foreign-arch-sdk.md
_build_vulkan_targets() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"
  local host_archdir="${target_dir}/x86_64"
  local archdir="${target_dir}/${arch_suffix}"
  local loader_src="${target_dir}/source/Vulkan-Loader"
  local spirv_tools_src="${target_dir}/source/SPIRV-Tools"
  local spirv_headers_src="${target_dir}/source/SPIRV-Headers"
  local _xbuild_cc _xbuild_cxx _xbuild_proc _xbuild_triplet="${target_triplet}"
  # Read by _vulkan_target_verdict through dynamic scope.
  local _vk_attempted=0 _vk_ok=0 _vk_failed=""

  _xbuild_cc="${CC:-${target_triplet}-gcc}"
  _xbuild_cxx="${CXX:-${target_triplet}-g++}"
  case "${arch_suffix}" in
    aarch64) _xbuild_proc="aarch64" ;;
    riscv64) _xbuild_proc="riscv64" ;;
    *)       _xbuild_proc="${arch_suffix}" ;;
  esac

  _vulkan_target_copy_headers "${arch_suffix}" "${host_archdir}" "${archdir}"
  _vulkan_target_build_loader "${arch_suffix}" "${host_archdir}" "${archdir}" "${loader_src}"
  _vulkan_target_build_spirv_tools "${arch_suffix}" "${archdir}" "${spirv_tools_src}" "${spirv_headers_src}"
  _vulkan_target_build_glslang "${arch_suffix}" "${archdir}" "${target_dir}"
  _vulkan_target_build_sdk_rest "${arch_suffix}" "${archdir}" "${target_dir}" "${target_triplet}"
  _vulkan_target_prune_nonsdk_dxc "${archdir}"
  _vulkan_target_verdict "${arch_suffix}" "${target_triplet}"
}



source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vulkan-install.sh"
