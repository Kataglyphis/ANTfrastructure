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

  # LOG6 (2026-08-17): the Vulkan-Profiles generator validated ×0 profiles —
  # "`jsonschema` module is not installed, schema validation skip" — because the
  # SDK builder picks the ACTIVE python (the uv venv when present), where apt's
  # python3-jsonschema (system dist-packages, installed above) is invisible.
  # Best-effort install into the venv python too so the validation actually runs.
  if command -v uv >/dev/null 2>&1 && [ -x /opt/python/.venv/bin/python ]; then
    UV_PYTHON=/opt/python/.venv/bin/python uv pip install jsonschema >/dev/null 2>&1 \
      || log "jsonschema venv install failed (schema validation will be skipped — non-fatal)"
  fi

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

# The resolve-and-source half of source_vulkan_sdk_env now lives in
# 01-core/vulkan-env.sh, so dev-side launchers can reuse it (with the opposite,
# non-strict miss contract) without sourcing this 23 KB SDK installer and
# inheriting its file-scope `set -euo pipefail`. Load it exactly the way
# downloads.sh is loaded above: via the sibling 01-core dir in a repo checkout,
# or /opt/scripts/core in an image. Every image that ships
# /opt/scripts/toolchain/vulkan.sh (or the /usr/local/bin/vulkan.sh copy made by
# Dockerfile.torch) also ships the whole 01-core tree under /opt/scripts/core.
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

  # Without the module there is nothing to probe with; report a miss so the
  # callers below take their own fallback path instead of dying on exit 127.
  declare -F vulkan_env_source >/dev/null 2>&1 || return 1

  # strict=1 is passed explicitly (not left to ${VULKAN_ENV_STRICT}) because the
  # callers of THIS function gate on the `return 1`: 04-runtime/entrypoint.sh,
  # 05-frameworks/tvm-detect.sh::try_source_vulkan_env,
  # 03-media/build/gstreamer/install-deps.sh and .../common/pre-setup.sh.
  vulkan_env_source "${prefix}" "${sanitize_mode}" 1
}

_vulkan_setup_gcc_runtime() {
  ARCH_LIB_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "${ARCH}-linux-gnu")"
  ${SUDO:-} mkdir -p "${ARCH_LIB_DIR}" /usr/lib
  if [[ -n "${LIBRARY_PATH:-}" ]]; then
    log "Setting up GCC runtime library symlinks for linking..."
    # IFS=':' read (scoped to the builtin): splits regardless of the caller's
    # IFS — the ${var//:/ } spaces would not split under a strict IFS=$'\n\t'.
    local -a _vk_libdirs=()
    IFS=':' read -r -a _vk_libdirs <<< "${LIBRARY_PATH}"
    for libdir in "${_vk_libdirs[@]}"; do
      [ -n "${libdir}" ] || continue
      for lib in libgcc_s.so.1 libgcc_s.so libstdc++.so.6 libstdc++.so; do
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
      for entry in X11 xcb; do
        if [[ -e "/usr/include/${entry}" && ! -e "${target_include_dir}/${entry}" ]]; then
          ${SUDO:-} ln -s "/usr/include/${entry}" "${target_include_dir}/${entry}"
        fi
      done
      local header base
      for header in /usr/include/wayland*.h /usr/include/xf86drm*.h; do
        [[ -e "${header}" ]] || continue
        base="$(basename "${header}")"
        if [[ ! -e "${target_include_dir}/${base}" ]]; then
          ${SUDO:-} ln -s "${header}" "${target_include_dir}/${base}"
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
      # DUP1: prefer dpkg's authoritative DEB_BUILD_MULTIARCH; fall back to the
      # canonical build_deb_multiarch_triplet (platform.sh) instead of an inline
      # uname→sed copy of the arch map (proven identical output on this host).
      host_multiarch="$(dpkg-architecture -qDEB_BUILD_MULTIARCH 2>/dev/null || build_deb_multiarch_triplet)"
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
  local -n _vulkan_sdk_components_ref="$1"

  log "Building selected SDK components..."
  JOBS="$(compute_jobs "${JOBS:-}")"
  # Nothing is skipped. ./vulkansdk fetches a component's CHECKOUT only when it
  # builds it, and source/ is what every target-arch build below reads.
  # docs/vulkan-foreign-arch-sdk.md
  _vulkan_sdk_components_ref=(
    glslang vulkan-headers vulkan-loader
    vulkan-validationlayers shaderc spirv-headers spirv-tools
    vulkan-extensionlayer volk vma vul
    spirv-cross spirv-reflect vulkan-profiles
    vulkan-tools gfxreconstruct vcv slang
  )
}

_vulkan_run_vulkansdk() {
  # LunarG's ./vulkansdk installs its own build dependencies via a bare
  # `apt-get install` (no -y). In a non-interactive container build that aborts
  # at the "Do you want to continue? [Y/n]" prompt. Make apt auto-confirm and
  # run non-interactively for that nested install (global config so the sudo'd
  # apt-get inside vulkansdk picks it up regardless of env).
  ${SUDO:-} tee /etc/apt/apt.conf.d/90assume-yes >/dev/null <<'EOF'
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

  # --preserve-env is a sudo-only flag: it stops sudo from stripping the PATH
  # (compiler shims), PKG_CONFIG_*, CMAKE_* and other exports set above. When
  # SUDO is empty (already root, e.g. foreign-arch cross containers) there is no
  # sudo to strip anything, so run vulkansdk directly — prefixing a bare
  # `--preserve-env=...` there makes the shell treat the flag as the command
  # (exit 127). Guard the flag on SUDO being set.
  if [ -n "${SUDO:-}" ]; then
    ${SUDO} --preserve-env=PATH,LD_LIBRARY_PATH,LIBRARY_PATH,PKG_CONFIG_PATH,PKG_CONFIG_LIBDIR,PKG_CONFIG_ALLOW_CROSS,PKG_CONFIG_SYSROOT_DIR,CMAKE_PREFIX_PATH,CMAKE_INCLUDE_PATH,CPATH,C_INCLUDE_PATH,CPLUS_INCLUDE_PATH,DEBIAN_FRONTEND \
      ./vulkansdk -j "$JOBS" "$@"
  else
    ./vulkansdk -j "$JOBS" "$@"
  fi
  export CC="${_saved_cc}" CXX="${_saved_cxx}"
  [ -n "${_saved_cmake_cc}" ] && export CMAKE_C_COMPILER="${_saved_cmake_cc}" || unset CMAKE_C_COMPILER
  [ -n "${_saved_cmake_cxx}" ] && export CMAKE_CXX_COMPILER="${_saved_cmake_cxx}" || unset CMAKE_CXX_COMPILER
}

# The ./vulkansdk checkout-and-build tree under <ver>/source: 3.9 GB and 1256
# builder-arch objects per foreign lane, read by _build_vulkan_targets above and by
# nothing after it. Dropped in the SAME RUN, so no downstream layer carries it.
# docs/artifact-copy-completeness.md#the-vulkan-tree-ships-only-what-the-image-runs
_vulkan_prune_sdk_sources() {
  local target_dir="$1"

  [ -d "${target_dir}/source" ] || return 0
  log "Pruning the Vulkan SDK build tree at ${target_dir}/source"
  ${SUDO:-} rm -rf "${target_dir}/source"
}

_build_vulkan_sdk_cross() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"

  (
    cd "${target_dir}"
    ${SUDO:-} chmod +x vulkansdk

    log "Building vulkansdk for cross-build..."

    _vulkan_setup_gcc_runtime
    _vulkan_setup_sdk_includes "${arch_suffix}" "${target_triplet}" "${target_dir}"
    _vulkan_setup_cross_pkgconfig "${target_triplet}"

    local sdk_components=()
    _vulkan_build_components sdk_components
    _vulkan_run_vulkansdk "${sdk_components[@]}"

    # ./vulkansdk only built HOST (x86_64) tools; also produce TARGET-arch Vulkan
    # libs (loader + SPIRV-Tools) so cross consumers (e.g. TVM) can link them.
    _build_vulkan_targets "${arch_suffix}" "${target_dir}" "${target_triplet}"
    _vulkan_prune_sdk_sources "${target_dir}"
  )
}

# Cross-configure/build/install one bundled SDK component into the target arch dir.
# $1=source dir, $2=label (for logs + build subdir); remaining args are extra cmake
# -D flags (e.g. -DCMAKE_INSTALL_PREFIX=...). Reads the cross toolchain from the
# caller's _xbuild_cc/_xbuild_cxx/_xbuild_proc (dynamic scope). Non-fatal: returns
# non-zero on any failure so the caller can log and continue.
_cross_build_sdk_component() {
  local src="$1" label="$2"
  shift 2
  local build_dir
  build_dir="$(mktemp -d)/${label}"

  if ! cmake -S "${src}" -B "${build_dir}" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR="${_xbuild_proc}" \
      -DCMAKE_C_COMPILER="${_xbuild_cc}" \
      -DCMAKE_CXX_COMPILER="${_xbuild_cxx}" \
      -DCMAKE_INSTALL_LIBDIR=lib \
      "$@"; then
    log "${label}: cross-configure failed (non-fatal)"
    return 1
  fi
  if ! cmake --build "${build_dir}" --parallel "$(compute_jobs "${JOBS:-}")"; then
    log "${label}: cross-build failed (non-fatal)"
    return 1
  fi
  if ! ${SUDO:-} cmake --install "${build_dir}"; then
    log "${label}: install failed (non-fatal)"
    return 1
  fi
  return 0
}

# --- decomposed body of _build_vulkan_targets -------------------------------
# Plain-statement calls only (keeps errexit live); _xbuild_*/_vk_* come from the
# caller by dynamic scope. docs/refactoring-backlog-archive-2026-08-31.md
_vulkan_target_copy_headers() {
  local arch_suffix="$1" host_archdir="$2" archdir="$3"

  ${SUDO:-} mkdir -p "${archdir}/lib" "${archdir}/include"
  # Vulkan headers are arch-independent: reuse the host archdir's installed copy.
  # TS6: guard ONLY on the source dir being absent; a cp that FAILS with the dir
  # present is a real error (disk/perms) — the old `2>/dev/null || true` masked it
  # as "source absent". Surface it (non-fatal: the loader build below will fail
  # loudly if the headers really didn't land).
  if [ -d "${host_archdir}/include/vulkan" ]; then
    ${SUDO:-} cp -a "${host_archdir}/include/vulkan" "${archdir}/include/" \
      || warn "vulkan headers present at ${host_archdir} but cp to ${archdir} failed (${arch_suffix})"
  fi
  if [ -d "${host_archdir}/include/vk_video" ]; then
    ${SUDO:-} cp -a "${host_archdir}/include/vk_video" "${archdir}/include/" \
      || warn "vk_video headers present at ${host_archdir} but cp to ${archdir} failed (${arch_suffix})"
  fi
}

# Vulkan loader (libvulkan.so). WSI off: TVM uses Vulkan for compute only, so we
# avoid needing target windowing-system dev libraries.
_vulkan_target_build_loader() {
  local arch_suffix="$1" host_archdir="$2" archdir="$3" loader_src="$4"

  if [ -d "${loader_src}" ] && [ -d "${host_archdir}/include/vulkan" ]; then
    _vk_attempted=$((_vk_attempted + 1))
    log "Cross-building Vulkan loader for ${arch_suffix}"
    if _cross_build_sdk_component "${loader_src}" "vulkan-loader-${arch_suffix}" \
        -DCMAKE_INSTALL_PREFIX="${archdir}" \
        -DVULKAN_HEADERS_INSTALL_DIR="${host_archdir}" \
        -DBUILD_TESTS=OFF \
        -DBUILD_WSI_XCB_SUPPORT=OFF \
        -DBUILD_WSI_XLIB_SUPPORT=OFF \
        -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
        -DBUILD_WSI_DIRECTFB_SUPPORT=OFF; then
      _vk_ok=$((_vk_ok + 1))
      log "Installed target Vulkan loader: $(ls "${archdir}"/lib/libvulkan.so* 2>/dev/null | tr '\n' ' ')"
    else
      log "Target Vulkan loader unavailable; cross Vulkan will be disabled downstream"
    fi
  else
    log "Vulkan-Loader source or host headers missing; skipping target loader"
  fi
}

# SPIRV-Tools — TVM links the libs; the spirv-* executables are what make the
# foreign-arch prefix a usable SDK instead of link fodder. SPIRV_WERROR=OFF: GCC
# 16's -Warray-bounds false-positives on timer.h would otherwise fail -Werror.
# docs/vulkan-foreign-arch-sdk.md
_vulkan_target_build_spirv_tools() {
  local arch_suffix="$1" archdir="$2" spirv_tools_src="$3" spirv_headers_src="$4"

  if [ -d "${spirv_tools_src}" ]; then
    _vk_attempted=$((_vk_attempted + 1))
    log "Cross-building SPIRV-Tools for ${arch_suffix}"
    if _cross_build_sdk_component "${spirv_tools_src}" "spirv-tools-${arch_suffix}" \
        -DCMAKE_INSTALL_PREFIX="${archdir}" \
        -DSPIRV-Headers_SOURCE_DIR="${spirv_headers_src}" \
        -DSPIRV_SKIP_TESTS=ON \
        -DSPIRV_SKIP_EXECUTABLES=OFF \
        -DSPIRV_WERROR=OFF; then
      _vk_ok=$((_vk_ok + 1))
      log "Installed target SPIRV-Tools: $(ls "${archdir}"/bin/spirv-* 2>/dev/null | wc -l) tools, $(ls "${archdir}"/lib/libSPIRV-Tools*.a 2>/dev/null | wc -l) libs"
    else
      log "Target SPIRV-Tools unavailable; cross TVM Vulkan may fail to configure"
    fi
  else
    log "SPIRV-Tools source missing at ${spirv_tools_src}; skipping target SPIRV-Tools"
  fi
}

# One cross-install per SDK component. Non-fatal by contract: a component that
# will not cross-build degrades the target prefix, it does not fail the lane.
# docs/vulkan-foreign-arch-sdk.md
_vulkan_target_install_component() {
  local arch_suffix="$1" archdir="$2" src="$3" label="$4"
  shift 4

  [ -d "${src}" ] || { log "${label}: source missing at ${src}; skipping"; return 0; }
  _vk_attempted=$((_vk_attempted + 1))
  log "Cross-building ${label} for ${arch_suffix}"
  if _cross_build_sdk_component "${src}" "${label}-${arch_suffix}" \
      -DCMAKE_INSTALL_PREFIX="${archdir}" \
      -DCMAKE_PREFIX_PATH="${archdir}" \
      -DBUILD_TESTS=OFF \
      -DBUILD_TESTING=OFF \
      "$@"; then
    _vk_ok=$((_vk_ok + 1))
  else
    log "${label} unavailable on ${arch_suffix}; the target SDK ships without it"
  fi
}

# LunarG's checkout directory does not always match the component name, and
# shaderc keeps its CMake project one level down in src/.
_vulkan_target_src() {
  local root="$1" d
  shift
  for d in "$@"; do
    [ -d "${root}/${d}" ] && { printf '%s' "${root}/${d}"; return 0; }
  done
  printf '%s' "${root}/$1"
}

# label | checkout candidates (comma-separated) | extra cmake args.
# Ordered by dependency, then by cost: the config packages the later components
# resolve through find_package(CONFIG) come first, the heavy ones last.
# docs/vulkan-foreign-arch-sdk.md
_VK_TARGET_COMPONENTS="
vulkan-headers|Vulkan-Headers|
spirv-headers|SPIRV-Headers|
vulkan-utility-libraries|Vulkan-Utility-Libraries|
volk|volk|-DVOLK_INSTALL=ON
vma|VulkanMemoryAllocator|
spirv-cross|SPIRV-Cross|-DSPIRV_CROSS_CLI=ON -DSPIRV_CROSS_ENABLE_TESTS=OFF
spirv-reflect|SPIRV-Reflect|-DSPIRV_REFLECT_EXECUTABLE=ON -DSPIRV_REFLECT_STATIC_LIB=ON
shaderc|shaderc/src,shaderc|-DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_ENABLE_INSTALL=ON
vulkan-tools|Vulkan-Tools|-DBUILD_VULKANINFO=ON -DBUILD_CUBE=ON
vulkan-extensionlayer|Vulkan-ExtensionLayer|
vulkan-profiles|Vulkan-Profiles|-DPROFILES_BUILD_TESTS=OFF
vulkan-validationlayers|Vulkan-ValidationLayers|-DUPDATE_DEPS=OFF -DBUILD_WERROR=OFF
gfxreconstruct|gfxreconstruct|-DGFXRECON_BUILD_TESTS=OFF
slang|slang|-DSLANG_ENABLE_TESTS=OFF -DSLANG_ENABLE_EXAMPLES=OFF
vulkancapsviewer|VulkanCapsViewer,vulkanCapsViewer,vcv|
"

# Everything the LunarG SDK ships beyond the four TVM needed, cross-built for the
# arch the image runs. docs/vulkan-foreign-arch-sdk.md
_vulkan_target_build_sdk_rest() {
  local arch_suffix="$1" archdir="$2" target_dir="$3"
  local label cands extra src

  while IFS='|' read -r label cands extra; do
    [ -n "${label}" ] || continue
    # shellcheck disable=SC2086  # both are deliberately word-split
    src="$(_vulkan_target_src "${target_dir}/source" ${cands//,/ })"
    # shellcheck disable=SC2086
    _vulkan_target_install_component "${arch_suffix}" "${archdir}" "${src}" "${label}" \
      -DVULKAN_HEADERS_INSTALL_DIR="${archdir}" \
      -DSPIRV_HEADERS_INSTALL_DIR="${archdir}" \
      ${extra}
  done <<EOF
${_VK_TARGET_COMPONENTS}
EOF
}

# Post-install name plumbing for the cross-built glslang.
_vulkan_target_link_glslang_aliases() {
  local archdir="$1"

  # Recent glslang installs the tool as `glslang`; KOMPUTE and older tooling
  # look for `glslangValidator`. Guarantee both names exist.
  if [ -x "${archdir}/bin/glslang" ] && [ ! -e "${archdir}/bin/glslangValidator" ]; then
    ${SUDO:-} ln -s glslang "${archdir}/bin/glslangValidator"
  elif [ -x "${archdir}/bin/glslangValidator" ] && [ ! -e "${archdir}/bin/glslang" ]; then
    ${SUDO:-} ln -s glslangValidator "${archdir}/bin/glslang"
  fi
  # The SDK setup-env.sh only puts <ver>/x86_64/bin on PATH (the host tools),
  # so the target arch dir is NOT searched. Symlink the tool into /usr/local/bin
  # (on the default PATH) so `find_program(glslangValidator)` resolves it on a
  # native aarch64/riscv64 build.
  for _b in glslang glslangValidator; do
    [ -e "${archdir}/bin/${_b}" ] && ${SUDO:-} ln -sf "${archdir}/bin/${_b}" "/usr/local/bin/${_b}"
  done
  # LOAD-BEARING: the loop's last `[ -e ]` may be false and would trip errexit.
  # docs/refactoring-backlog-archive-2026-08-31.md
  return 0
}

# glslang / glslangValidator — a BUILD-TIME shader compiler. LunarG's ./vulkansdk
# only produced the HOST (x86_64) glslangValidator, which cannot run on a native
# aarch64/riscv64 runner, so a project that compiles GLSL during its build (e.g.
# KOMPUTE: `find_program(glslangValidator)` -> FATAL_ERROR) fails on those arches.
# Cross-build glslang into the target archdir/bin so ARM and RISC-V images ship a
# runnable one. ENABLE_OPT=OFF drops the SPIRV-Tools-Opt dependency (the validator
# does not need the optimiser); the Python source generation glslang runs at
# configure time is host-side and arch-independent, so it cross-builds cleanly.
_vulkan_target_build_glslang() {
  local arch_suffix="$1" archdir="$2" target_dir="$3"

  local glslang_src="${target_dir}/source/glslang"
  [ -d "${glslang_src}" ] || glslang_src="${target_dir}/source/glslang-main"
  if [ -d "${glslang_src}" ]; then
    _vk_attempted=$((_vk_attempted + 1))
    log "Cross-building glslang (glslangValidator) for ${arch_suffix}"
    if _cross_build_sdk_component "${glslang_src}" "glslang-${arch_suffix}" \
        -DCMAKE_INSTALL_PREFIX="${archdir}" \
        -DENABLE_OPT=OFF \
        -DGLSLANG_TESTS=OFF \
        -DBUILD_TESTING=OFF \
        -DENABLE_GLSLANG_BINARIES=ON \
        -DENABLE_SPVREMAPPER=OFF; then
      _vulkan_target_link_glslang_aliases "${archdir}"
      _vk_ok=$((_vk_ok + 1))
      log "Installed target glslang: $(ls "${archdir}"/bin/glslang* 2>/dev/null | tr '\n' ' '); on PATH: $(command -v glslangValidator 2>/dev/null || echo none)"
    else
      log "Target glslang unavailable; GLSL shader compilation will fail on ${arch_suffix}"
    fi
  else
    log "glslang source missing at ${target_dir}/source/glslang; skipping target glslang"
  fi
}

# TS6 aggregate verdict: a per-component failure is tolerated (each logs its own
# "unavailable; downstream may fail"), but if EVERY attempted component failed
# the cause is almost certainly systemic (a broken ${target_triplet} toolchain,
# missing cross sysroot, …) rather than three independent optional misses — and
# the old code returned 0 regardless, so downstream only discovered it much
# later as a baffling Vulkan/TVM/KOMPUTE configure failure. Surface it loudly;
# VULKAN_CROSS_STRICT=1 promotes it to fatal for callers that want the hard stop.
_vulkan_target_verdict() {
  local arch_suffix="$1" target_triplet="$2"

  log "Vulkan cross-targets ${arch_suffix}: ${_vk_ok}/${_vk_attempted} component(s) built"
  if [ "${_vk_attempted}" -gt 0 ] && [ "${_vk_ok}" -eq 0 ]; then
    warn "ALL ${_vk_attempted} Vulkan cross-component(s) FAILED for ${arch_suffix} (loader/SPIRV-Tools/glslang) — this is an env-shaped failure (broken ${target_triplet} toolchain?), not per-component optionality; downstream cross Vulkan will be disabled. Set VULKAN_CROSS_STRICT=1 to make this fatal."
    if [ "${VULKAN_CROSS_STRICT:-0}" = "1" ]; then
      die "VULKAN_CROSS_STRICT=1 and all ${_vk_attempted} Vulkan cross-components failed for ${arch_suffix}"
    fi
  fi
}

# Cross-build the Vulkan target libraries TVM needs and install them under the
# target arch dir. LunarG's ./vulkansdk only produces HOST (x86_64) tools, so a
# cross build otherwise has no target libvulkan/libSPIRV-Tools: find_package(Vulkan)
# resolves the x86_64 loader (target link fails "file in wrong format") and TVM's
# cmake errors on Vulkan_SPIRV_TOOLS_LIBRARY=NOTFOUND. Build both from the SDK's
# bundled sources with the target toolchain into /opt/vulkan/<ver>/<arch>/ (where
# detect_vulkan_library / detect_spirv_tools_library already look). Each component
# is non-fatal: if one can't build, the downstream guard disables that capability
# rather than failing the whole stage. Vulkan headers are arch-independent, so the
# host archdir's copy is reused. Loader WSI is off (Vulkan is used for compute).
# Step ORDER is a contract: headers before loader (the loader build needs them).
_build_vulkan_targets() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"
  local host_archdir="${target_dir}/x86_64"
  local archdir="${target_dir}/${arch_suffix}"
  local loader_src="${target_dir}/source/Vulkan-Loader"
  local spirv_tools_src="${target_dir}/source/SPIRV-Tools"
  local spirv_headers_src="${target_dir}/source/SPIRV-Headers"
  local _xbuild_cc _xbuild_cxx _xbuild_proc
  # TS6: aggregate verdict — individual component failures are tolerated (each is
  # optional downstream), but ALL of them failing at once is an env-shaped cause
  # (a broken cross toolchain), which used to exit 0 silently. Count attempts/ok.
  local _vk_attempted=0 _vk_ok=0

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
  _vulkan_target_build_sdk_rest "${arch_suffix}" "${archdir}" "${target_dir}"
  _vulkan_target_verdict "${arch_suffix}" "${target_triplet}"
}

install_vulkan_sdk() {
  # Fallback chain ends in the CANONICAL pin name. VULKAN_VERSION_DEFAULT is a
  # setup-dependencies.sh-local override that exists only when --vulkan-version
  # was passed — a zero-arg call used to abort "unbound variable" instead of
  # falling back to the versions.env pin it was named after.
  local version="${1:-${VULKAN_VERSION_DEFAULT:-${VULKAN_VERSION:?VULKAN_VERSION (or an explicit argument) required}}}"
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
  # VERIFIED when the pin exists (supply-chain audit #7): the SDK ships
  # glslang/spirv-tools — shader COMPILERS invoked during the media and SDK
  # builds. VULKAN_SDK_SHA256 bumps together with VULKAN_VERSION.
  if [ -n "${VULKAN_SDK_SHA256:-}" ]; then
    download_verified_file "$url" "${VULKAN_SDK_SHA256}" "$tarball" || die "Failed to download/verify Vulkan SDK"
  else
    log "WARNING: VULKAN_SDK_SHA256 unset — fetching the Vulkan SDK UNVERIFIED (pin it in versions.env alongside VULKAN_VERSION)"
    download_file "$url" "$tarball" 3 30 || die "Failed to download Vulkan SDK"
  fi
  [ -s "$tarball" ] || die "Downloaded tarball is empty"

  log "Extracting Vulkan SDK to ${VULKAN_INSTALL_ROOT}/${version}..."
  ${SUDO:-} mkdir -p "$VULKAN_TMP_DIR" || die "Failed to create ${VULKAN_TMP_DIR}"
  ${SUDO:-} chmod 1777 "$VULKAN_TMP_DIR" || die "Failed to set permissions on ${VULKAN_TMP_DIR}"

  tmpd="$(mktemp -d -p "$VULKAN_TMP_DIR" vulkan-sdk-XXXXXX 2>/dev/null)" || die "mktemp failed in ${VULKAN_TMP_DIR}"
  tar -xJf "$tarball" -C "$tmpd" || die "tar extraction failed"

  ${SUDO:-} mkdir -p "$VULKAN_INSTALL_ROOT" || die "Failed to create ${VULKAN_INSTALL_ROOT}"
  entries=( "$tmpd"/* )
  target_dir="${VULKAN_INSTALL_ROOT}/${version}"
  if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
    ${SUDO:-} rm -rf "${target_dir}"
    ${SUDO:-} mv "${entries[0]}" "${target_dir}" || die "Failed to move SDK to ${target_dir}"
  else
    ${SUDO:-} rm -rf "${target_dir}"
    ${SUDO:-} mkdir -p "${target_dir}"
    ${SUDO:-} mv "$tmpd"/* "${target_dir}/" || die "Failed to move SDK contents to ${target_dir}"
  fi

  rm -rf "$tmpd"
  rm -f "$tarball"

  ${SUDO:-} chown -R root:root "${target_dir}"
  ${SUDO:-} chmod -R a+rX "${target_dir}"
  log "Extracted to: ${target_dir}"
  log "To use in a shell: source ${target_dir}/setup-env.sh"

  if [[ "$arch_suffix" == "aarch64" || "$arch_suffix" == "riscv64" ]]; then
    _build_vulkan_sdk_cross "$arch_suffix" "$target_dir" "$target_triplet"
  fi
}
