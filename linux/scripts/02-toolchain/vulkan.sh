#!/usr/bin/env bash
set -euo pipefail
# vulkan.sh - Vulkan SDK install source-only helper.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

# download_file lives in 01-core/downloads.sh (normally loaded via common.sh);
# load it directly when a caller sourced this file without the module chain.
if ! command -v download_file >/dev/null 2>&1; then
  for _vulkan_dl in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/downloads.sh" \
    "/opt/scripts/core/downloads.sh"; do
    if [ -f "${_vulkan_dl}" ]; then
      # shellcheck disable=SC1090
      source "${_vulkan_dl}"
      break
    fi
  done
  unset _vulkan_dl
fi

install_vulkan_prereqs() {
  log "Installing Vulkan SDK prerequisites"
  local -a host_packages=(
    xz-utils libglm-dev libxcb-dri3-0
    libxcb-present0 libpciaccess0 libpng-dev libxcb1-dev libxcb-keysyms1-dev
    libxcb-dri3-dev libx11-dev g++ gcc libwayland-dev
    libxrandr-dev libxcb-randr0-dev libxcb-ewmh-dev git
    python3 bison libx11-xcb-dev liblz4-dev libzstd-dev
    ocaml ninja-build pkg-config libxml2-dev
    wayland-protocols python3-jsonschema clang-format qtbase5-dev qt6-base-dev
    libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev
  )
  local -a target_pkgconfig_packages=(
    libpng-dev
    libpciaccess-dev
    libxcb1-dev
    libxcb-keysyms1-dev
    libxcb-dri3-dev
    libxcb-present-dev
    libxcb-randr0-dev
    libxcb-ewmh-dev
    libxcb-cursor-dev
    libxcb-xinput-dev
    libxcb-xinerama0-dev
    libx11-dev
    libx11-xcb-dev
    libwayland-dev
    libxrandr-dev
    liblz4-dev
    libzstd-dev
    libxml2-dev
    wayland-protocols
  )

  apt_install "${host_packages[@]}"

  if cross_build_is_active && \
     command -v install_target_packages >/dev/null 2>&1; then
    # Cross Vulkan builds keep pkg-config pointed at target multiarch roots.
    # Install the WSI and compression dev packages for that target too.
    install_target_packages "${target_pkgconfig_packages[@]}"
  fi
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

  if [ "${VULKAN_KEEP_SDK_LIBS:-${TVM_VULKAN_KEEP_SDK_LIBS:-0}}" = "1" ]; then
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

source_vulkan_sdk_env() {
  local prefix="${1:-${VULKAN_PREFIX:-${VULKAN_INSTALL_ROOT}}}"
  local sanitize_mode="${2:-keep-libs}"
  local setup_path=""
  local candidate

  if [ -n "${VULKAN_VERSION:-}" ] && [ -r "${prefix}/${VULKAN_VERSION}/setup-env.sh" ]; then
    setup_path="${prefix}/${VULKAN_VERSION}/setup-env.sh"
  else
    for candidate in "${prefix}"/*/setup-env.sh; do
      [ -r "${candidate}" ] || continue
      setup_path="${candidate}"
      break
    done
  fi

  [ -n "${setup_path}" ] || return 1

  # setup-env.sh may inspect $1/$2, so clear this helper's function args first.
  set --
  # shellcheck disable=SC1090,SC1091
  source "${setup_path}"
  case "${sanitize_mode}" in
    sanitize-libs)
      sanitize_vulkan_sdk_env "${prefix}/"
      ;;
  esac
  return 0
}

_vulkan_setup_gcc_runtime() {
  ARCH_LIB_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "${ARCH}-linux-gnu")"
  ${SUDO:-sudo} mkdir -p "${ARCH_LIB_DIR}" /usr/lib
  if [[ -n "${LIBRARY_PATH:-}" ]]; then
    log "Setting up GCC runtime library symlinks for linking..."
    for libdir in ${LIBRARY_PATH//:/ }; do
      for lib in libgcc_s.so.1 libgcc_s.so libstdc++.so.6 libstdc++.so; do
        if [[ -f "${libdir}/${lib}" ]]; then
          if [[ ! -e "${ARCH_LIB_DIR}/${lib}" ]]; then
            ${SUDO:-sudo} ln -sf "${libdir}/${lib}" "${ARCH_LIB_DIR}/${lib}" 2>/dev/null || true
          fi
          if [[ ! -e "/usr/lib/${lib}" ]]; then
            ${SUDO:-sudo} ln -sf "${libdir}/${lib}" "/usr/lib/${lib}" 2>/dev/null || true
          fi
        fi
      done
    done
    log "Symlinked GCC runtime libraries to ${ARCH_LIB_DIR} and /usr/lib"
  fi
  ${SUDO:-sudo} ldconfig 2>/dev/null || true
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
      ${SUDO:-sudo} mkdir -p /usr/include /usr/local/include "${target_include_dir}"
      for entry in X11 xcb; do
        if [[ -e "/usr/include/${entry}" && ! -e "${target_include_dir}/${entry}" ]]; then
          ${SUDO:-sudo} ln -s "/usr/include/${entry}" "${target_include_dir}/${entry}"
        fi
      done
      local header base
      for header in /usr/include/wayland*.h /usr/include/xf86drm*.h; do
        [[ -e "${header}" ]] || continue
        base="$(basename "${header}")"
        if [[ ! -e "${target_include_dir}/${base}" ]]; then
          ${SUDO:-sudo} ln -s "${header}" "${target_include_dir}/${base}"
        fi
      done
      export CMAKE_INCLUDE_PATH="${SDK_ARCHDIR}/include:/usr/include${CMAKE_INCLUDE_PATH:+:${CMAKE_INCLUDE_PATH}}"
      # Do NOT add /usr/include to the compiler include-path vars below. It is
      # already a default system dir; forcing it in via CPATH/C_INCLUDE_PATH/
      # CPLUS_INCLUDE_PATH makes GCC search it *before* the C++ header dir, so
      # libstdc++'s `#include_next <stdlib.h>` (from <cstdlib>) skips it and
      # fails with "stdlib.h: No such file or directory" when building the host
      # SDK tools (e.g. SPIRV-Tools). Only prepend the Vulkan SDK headers.
      export CPATH="${SDK_ARCHDIR}/include${CPATH:+:${CPATH}}"
      export C_INCLUDE_PATH="${SDK_ARCHDIR}/include${C_INCLUDE_PATH:+:${C_INCLUDE_PATH}}"
      export CPLUS_INCLUDE_PATH="${SDK_ARCHDIR}/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
    fi

    _symlink_sdk_include() {
      local name="$1" target_include_dir="$2" sdkincludedir="$3"
      if [ -d "${sdkincludedir}/include/${name}" ]; then
        ${SUDO:-sudo} mkdir -p /usr/include /usr/local/include "${target_include_dir}"
        ${SUDO:-sudo} rm -rf "/usr/include/${name}" "/usr/local/include/${name}" "${target_include_dir}/${name}"
        ${SUDO:-sudo} ln -s "${sdkincludedir}/include/${name}" "/usr/include/${name}"
        ${SUDO:-sudo} ln -s "${sdkincludedir}/include/${name}" "/usr/local/include/${name}"
        ${SUDO:-sudo} ln -s "${sdkincludedir}/include/${name}" "${target_include_dir}/${name}"
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
      host_multiarch="$(dpkg-architecture -qDEB_BUILD_MULTIARCH 2>/dev/null || uname -m | sed 's/x86_64/x86_64-linux-gnu/; s/aarch64/aarch64-linux-gnu/; s/riscv64/riscv64-linux-gnu/')"
    fi
    if [ -n "${host_multiarch}" ]; then
      host_pkgconfig="/usr/lib/${host_multiarch}/pkgconfig:/usr/share/pkgconfig:/usr/local/lib/pkgconfig"
    fi
    if command -v cross_pkg_config_libdir >/dev/null 2>&1; then
      export PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${target_triplet}"):${host_pkgconfig}"
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

  # Per-component skip rules: key=component, value=skip reason (empty=include)
  local -A _vulkan_skip=()
  if cross_build_enabled; then
    _vulkan_skip[vulkan-tools]="foreign-arch cross builds"
    _vulkan_skip[gfxreconstruct]="foreign-arch cross builds"
    _vulkan_skip[vcv]="foreign-arch cross builds"
    _vulkan_skip[slang]="foreign-arch cross builds"
  elif [ "${arch_suffix}" = "riscv64" ]; then
    _vulkan_skip[slang]="riscv64 (not yet ported)"
  fi

  for comp in vulkan-tools gfxreconstruct vcv slang; do
    if [ -n "${_vulkan_skip[${comp}]:-}" ]; then
      log "Skipping ${comp} for ${_vulkan_skip[${comp}]}"
    else
      _vulkan_sdk_components_ref+=("${comp}")
    fi
  done
}

_vulkan_run_vulkansdk() {
  # LunarG's ./vulkansdk installs its own build dependencies via a bare
  # `apt-get install` (no -y). In a non-interactive container build that aborts
  # at the "Do you want to continue? [Y/n]" prompt. Make apt auto-confirm and
  # run non-interactively for that nested install (global config so the sudo'd
  # apt-get inside vulkansdk picks it up regardless of env).
  ${SUDO:-sudo} tee /etc/apt/apt.conf.d/90assume-yes >/dev/null <<'EOF'
APT::Get::Assume-Yes "true";
EOF
  export DEBIAN_FRONTEND=noninteractive

  # The vulkansdk builds HOST-arch tools. Save/restore cross CC/CXX
  # so CMake uses the HOST compiler, not the cross-compiler.
  local _saved_cc="${CC:-}" _saved_cxx="${CXX:-}"
  local _saved_cmake_cc="${CMAKE_C_COMPILER:-}" _saved_cmake_cxx="${CMAKE_CXX_COMPILER:-}"
  unset CC CXX CMAKE_C_COMPILER CMAKE_CXX_COMPILER

  # GCC 16 promotes several new -W diagnostics that fire (often as false
  # positives) on the older SDK component sources — e.g. -Warray-bounds on
  # SPIRV-Tools' timer.h. Those components build with -Werror, so the build
  # dies. CXXFLAGS can't fix it: CMake places env flags BEFORE each project's
  # own `-Wall -Werror`, so a later -Werror wins. Instead, shim the host
  # compilers to append `-Wno-error` LAST on every invocation, which always
  # wins and neutralises -Werror for all SDK components (host tools only; our
  # own builds are unaffected). vulkansdk auto-detects cc/c++ from PATH.
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

  ${SUDO:-sudo} --preserve-env=PATH,LD_LIBRARY_PATH,LIBRARY_PATH,PKG_CONFIG_PATH,PKG_CONFIG_LIBDIR,PKG_CONFIG_ALLOW_CROSS,PKG_CONFIG_SYSROOT_DIR,CMAKE_PREFIX_PATH,CMAKE_INCLUDE_PATH,CPATH,C_INCLUDE_PATH,CPLUS_INCLUDE_PATH,DEBIAN_FRONTEND \
    ./vulkansdk -j "$JOBS" "$@"
  export CC="${_saved_cc}" CXX="${_saved_cxx}"
  [ -n "${_saved_cmake_cc}" ] && export CMAKE_C_COMPILER="${_saved_cmake_cc}" || unset CMAKE_C_COMPILER
  [ -n "${_saved_cmake_cxx}" ] && export CMAKE_CXX_COMPILER="${_saved_cmake_cxx}" || unset CMAKE_CXX_COMPILER
}

_build_vulkan_sdk_cross() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"

  (
    cd "${target_dir}"
    ${SUDO:-sudo} chmod +x vulkansdk

    log "Building vulkansdk for cross-build..."

    _vulkan_setup_gcc_runtime
    _vulkan_setup_sdk_includes "${arch_suffix}" "${target_triplet}" "${target_dir}"
    _vulkan_setup_cross_pkgconfig "${target_triplet}"

    local sdk_components=()
    _vulkan_build_components "${arch_suffix}" sdk_components
    _vulkan_run_vulkansdk "${sdk_components[@]}"

    # ./vulkansdk only built HOST (x86_64) tools; also produce a TARGET-arch
    # libvulkan so cross consumers (e.g. TVM) can link a matching loader.
    _build_vulkan_loader_target "${arch_suffix}" "${target_dir}" "${target_triplet}"
  )
}

# Cross-build the Vulkan loader (libvulkan.so) for the target arch and install it,
# plus the (arch-independent) Vulkan headers, under the target arch dir. LunarG's
# ./vulkansdk only produces HOST (x86_64) tools, so without this a cross build has
# no target libvulkan to link against: find_package(Vulkan) resolves the x86_64
# loader and the target link fails with "file in wrong format" (e.g. TVM's
# libtvm_runtime_vulkan.so). WSI is disabled — Vulkan is used here for compute, so
# we avoid needing target windowing-system dev libraries. Non-fatal: on any failure
# the target arch dir simply lacks libvulkan and consumers (e.g. tvm.sh) fall back
# to disabling Vulkan for the cross target rather than failing the whole stage.
_build_vulkan_loader_target() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"
  local loader_src="${target_dir}/source/Vulkan-Loader"
  local host_archdir="${target_dir}/x86_64"
  local archdir="${target_dir}/${arch_suffix}"
  local cc cxx cmake_proc build_dir

  [ -d "${loader_src}" ] || {
    log "Vulkan-Loader source not at ${loader_src}; skipping target loader build (cross Vulkan will be disabled downstream)"
    return 0
  }
  [ -d "${host_archdir}/include/vulkan" ] || {
    log "Host Vulkan headers not at ${host_archdir}/include; skipping target loader build"
    return 0
  }

  cc="${CC:-${target_triplet}-gcc}"
  cxx="${CXX:-${target_triplet}-g++}"
  case "${arch_suffix}" in
    aarch64) cmake_proc="aarch64" ;;
    riscv64) cmake_proc="riscv64" ;;
    *)       cmake_proc="${arch_suffix}" ;;
  esac
  build_dir="$(mktemp -d)/vulkan-loader-${arch_suffix}"

  log "Cross-building Vulkan loader for ${arch_suffix} -> ${archdir}/lib/libvulkan.so"
  ${SUDO:-sudo} mkdir -p "${archdir}/lib" "${archdir}/include"
  # Vulkan headers are arch-independent: reuse the host archdir's installed copy.
  ${SUDO:-sudo} cp -a "${host_archdir}/include/vulkan" "${archdir}/include/" 2>/dev/null || true
  [ -d "${host_archdir}/include/vk_video" ] && \
    ${SUDO:-sudo} cp -a "${host_archdir}/include/vk_video" "${archdir}/include/" 2>/dev/null || true

  if ! cmake -S "${loader_src}" -B "${build_dir}" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR="${cmake_proc}" \
      -DCMAKE_C_COMPILER="${cc}" \
      -DCMAKE_CXX_COMPILER="${cxx}" \
      -DCMAKE_INSTALL_PREFIX="${archdir}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DVULKAN_HEADERS_INSTALL_DIR="${host_archdir}" \
      -DBUILD_TESTS=OFF \
      -DBUILD_WSI_XCB_SUPPORT=OFF \
      -DBUILD_WSI_XLIB_SUPPORT=OFF \
      -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
      -DBUILD_WSI_DIRECTFB_SUPPORT=OFF; then
    log "Vulkan loader cross-configure failed; cross Vulkan will be disabled downstream"
    return 0
  fi
  if ! cmake --build "${build_dir}" --parallel "$(compute_jobs "${JOBS:-}")"; then
    log "Vulkan loader cross-build failed; cross Vulkan will be disabled downstream"
    return 0
  fi
  if ! ${SUDO:-sudo} cmake --install "${build_dir}"; then
    log "Vulkan loader install failed; cross Vulkan will be disabled downstream"
    return 0
  fi
  log "Installed target Vulkan loader: $(ls "${archdir}"/lib/libvulkan.so* 2>/dev/null | tr '\n' ' ')"
}

install_vulkan_sdk() {
  local version="${1:-$VULKAN_VERSION_DEFAULT}"
  log "Installing Vulkan SDK ${version} via tarball"
  install_vulkan_prereqs

  local normalized_arch="$(arch_normalize "${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}")"
  local arch_suffix="$(arch_uname_name_for "${normalized_arch}")"
  local target_triplet="$(arch_deb_multiarch_triplet_for "${normalized_arch}")"
  [ -n "${arch_suffix}" ] || die "Unknown or unsupported architecture: ${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}"
  [ -n "${target_triplet}" ] || die "Unknown or unsupported architecture: ${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}"

  local tarball="vulkansdk-linux-x86_64-${version}.tar.xz"
  local url="https://sdk.lunarg.com/sdk/download/${version}/linux/${tarball}"
  log "Downloading ${tarball} from ${url}"
  download_file "$url" "$tarball" 3 30 || die "Failed to download Vulkan SDK"
  [ -s "$tarball" ] || die "Downloaded tarball is empty"

  log "Extracting Vulkan SDK to ${VULKAN_INSTALL_ROOT}/${version}..."
  ${SUDO:-sudo} mkdir -p "$VULKAN_TMP_DIR" || die "Failed to create ${VULKAN_TMP_DIR}"
  ${SUDO:-sudo} chmod 1777 "$VULKAN_TMP_DIR" || die "Failed to set permissions on ${VULKAN_TMP_DIR}"

  tmpd="$(mktemp -d -p "$VULKAN_TMP_DIR" vulkan-sdk-XXXXXX 2>/dev/null)" || die "mktemp failed in ${VULKAN_TMP_DIR}"
  tar -xJf "$tarball" -C "$tmpd" || die "tar extraction failed"

  ${SUDO:-sudo} mkdir -p "$VULKAN_INSTALL_ROOT" || die "Failed to create ${VULKAN_INSTALL_ROOT}"
  entries=( "$tmpd"/* )
  target_dir="${VULKAN_INSTALL_ROOT}/${version}"
  if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
    ${SUDO:-sudo} rm -rf "${target_dir}"
    ${SUDO:-sudo} mv "${entries[0]}" "${target_dir}" || die "Failed to move SDK to ${target_dir}"
  else
    ${SUDO:-sudo} rm -rf "${target_dir}"
    ${SUDO:-sudo} mkdir -p "${target_dir}"
    ${SUDO:-sudo} mv "$tmpd"/* "${target_dir}/" || die "Failed to move SDK contents to ${target_dir}"
  fi

  rm -rf "$tmpd"
  rm -f "$tarball"

  ${SUDO:-sudo} chown -R root:root "${target_dir}"
  ${SUDO:-sudo} chmod -R a+rX "${target_dir}"
  log "Extracted to: ${target_dir}"
  log "To use in a shell: source ${target_dir}/setup-env.sh"

  if [[ "$arch_suffix" == "aarch64" || "$arch_suffix" == "riscv64" ]]; then
    _build_vulkan_sdk_cross "$arch_suffix" "$target_dir" "$target_triplet"
  fi
}
