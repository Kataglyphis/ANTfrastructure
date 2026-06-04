#!/usr/bin/env bash
# vulkan.sh - Vulkan SDK install

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

  if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
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

_patch_vulkan_sdk_for_cross_build() {
  local arch_suffix="$1"
  local target_dir="$2"
  local target_triplet="$3"

  (
    cd "${target_dir}"
    ${SUDO:-sudo} chmod +x vulkansdk
    log "Patching vulkansdk for non-interactive installs on ${arch_suffix}"
    ${SUDO:-sudo} sed -E -i.bak \
      -e '/\bapt(-get)?[[:space:]]+install\b/ { /(-y|--assume-yes|--assumeyes|--yes)/! s/(\bapt(-get)?[[:space:]]+install\b)/\1 -y/ }' \
      -e '/\bdnf[[:space:]]+install\b/     { /(-y|--assumeyes|--assume-yes|--yes)/! s/(\bdnf[[:space:]]+install\b)/\1 -y/ }' \
      -e '/\bpacman[[:space:]]+-S\b/         { /(--noconfirm|-y)/! s/(\bpacman[[:space:]]+-S\b)/\1 -y/ }' \
      ./vulkansdk

    log "Disabling SPIRV-Tools warnings-as-errors in vulkansdk"
    ${SUDO:-sudo} perl -0pi -e 's/-DSPIRV_SKIP_TESTS="ON" \\\n+    --install-prefix/ -DSPIRV_SKIP_TESTS="ON" \\\n+    -DSPIRV_WERROR="OFF" \\\n+    -DCMAKE_COMPILE_WARNING_AS_ERROR="OFF" \\\n+    --install-prefix/s' ./vulkansdk

    log "Pinning Vulkan-Loader to the extracted VulkanHeaders package"
    ${SUDO:-sudo} perl -0pi -e 's/-DVULKAN_HEADERS_INSTALL_DIR="\$ARCHDIR" \\\n    -DSYSCONFDIR="\/etc"/-DVULKAN_HEADERS_INSTALL_DIR="\$ARCHDIR" \\\n+    -DVulkanHeaders_DIR="\$ARCHDIR\/share\/cmake\/VulkanHeaders" \\\n+    -DCMAKE_PREFIX_PATH="\$ARCHDIR;\$ARCHDIR\/share\/cmake;\$ARCHDIR\/lib\/cmake" \\\n+    -DCMAKE_INCLUDE_PATH="\$ARCHDIR\/include" \\\n+    -DSYSCONFDIR="\/etc"/s' ./vulkansdk

    log "Normalizing patched vulkansdk formatting"
    ${SUDO:-sudo} perl -0pi -e 's/\n\+    -DSPIRV_WERROR/\n    -DSPIRV_WERROR/g; s/\n\+    -DCMAKE_COMPILE_WARNING_AS_ERROR/\n    -DCMAKE_COMPILE_WARNING_AS_ERROR/g; s/\n\+    --install-prefix/\n    --install-prefix/g; s/\n\+    -DVulkanHeaders_DIR/\n    -DVulkanHeaders_DIR/g; s/\n\+    -DCMAKE_PREFIX_PATH/\n    -DCMAKE_PREFIX_PATH/g; s/\n\+    -DCMAKE_INCLUDE_PATH/\n    -DCMAKE_INCLUDE_PATH/g; s/\n\+    -DSYSCONFDIR/\n    -DSYSCONFDIR/g' ./vulkansdk

    log "Adding retry wrapper around upstream git clone/pull helper"
    ${SUDO:-sudo} tee -a ./vulkansdk >/dev/null <<'EOF'

clone_pull_repo() {
  REPO_DIR=$1
  REPO_URL=$2
  REPO_REF=$3
  attempt=1
  while [ $attempt -le 5 ]; do
    if [ -d "${REPO_DIR}" ]; then
      if git -C "${REPO_DIR}" checkout "${REPO_REF}" && git -C "${REPO_DIR}" pull origin "${REPO_REF}"; then
        break
      fi
    else
      if git -C "${SOURCEDIR}" clone --recurse-submodules "${REPO_URL}" "${REPO_DIR}" && git -C "${REPO_DIR}" checkout "${REPO_REF}"; then
        break
      fi
    fi
    if [ $attempt -eq 5 ]; then
      return 1
    fi
    echo "Retrying repo fetch for ${REPO_URL} (attempt ${attempt}/5 failed)"
    rm -rf "${REPO_DIR}"
    sleep $((attempt * 5))
    attempt=$((attempt + 1))
  done
  [ -f "${REPO_DIR}/.gitmodules" ] && git -C "${REPO_DIR}" submodule update || true
}
EOF

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
        export CPATH="${SDK_ARCHDIR}/include:/usr/include${CPATH:+:${CPATH}}"
        export C_INCLUDE_PATH="${SDK_ARCHDIR}/include:/usr/include${C_INCLUDE_PATH:+:${C_INCLUDE_PATH}}"
        export CPLUS_INCLUDE_PATH="${SDK_ARCHDIR}/include:/usr/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
      fi

      if [[ -d "${SDK_ARCHDIR}/include/vulkan" ]]; then
        log "Replacing standard Vulkan include paths with SDK headers"
        ${SUDO:-sudo} mkdir -p /usr/include /usr/local/include "${target_include_dir}"
        ${SUDO:-sudo} rm -rf /usr/include/vulkan /usr/local/include/vulkan "${target_include_dir}/vulkan"
        ${SUDO:-sudo} ln -s "${SDK_ARCHDIR}/include/vulkan" /usr/include/vulkan
        ${SUDO:-sudo} ln -s "${SDK_ARCHDIR}/include/vulkan" /usr/local/include/vulkan
        ${SUDO:-sudo} ln -s "${SDK_ARCHDIR}/include/vulkan" "${target_include_dir}/vulkan"
      fi
      if [[ -d "${SDK_ARCHDIR}/include/vk_video" ]]; then
        ${SUDO:-sudo} mkdir -p /usr/include /usr/local/include "${target_include_dir}"
        ${SUDO:-sudo} rm -rf /usr/include/vk_video /usr/local/include/vk_video "${target_include_dir}/vk_video"
        ${SUDO:-sudo} ln -s "${SDK_ARCHDIR}/include/vk_video" /usr/include/vk_video
        ${SUDO:-sudo} ln -s "${SDK_ARCHDIR}/include/vk_video" /usr/local/include/vk_video
        ${SUDO:-sudo} ln -s "${SDK_ARCHDIR}/include/vk_video" "${target_include_dir}/vk_video"
      fi
    fi

    if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
      unset PKG_CONFIG_PATH
      export PKG_CONFIG_ALLOW_CROSS=1
      export PKG_CONFIG_SYSROOT_DIR=/
      if command -v cross_pkg_config_libdir >/dev/null 2>&1; then
        export PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${target_triplet}")"
      else
        export PKG_CONFIG_LIBDIR="/usr/${target_triplet}/lib/pkgconfig:/usr/lib/${target_triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
      fi
      log "Using cross pkg-config search path ${PKG_CONFIG_LIBDIR}"
    fi

    log "Building selected SDK components..."
    JOBS="$(compute_jobs "${JOBS:-}")"
    local sdk_components=(
      glslang vulkan-headers vulkan-loader
      vulkan-validationlayers shaderc spirv-headers spirv-tools
      vulkan-extensionlayer volk vma vul
      spirv-cross spirv-reflect vulkan-profiles
    )
    if cross_build_enabled; then
      log "Skipping vulkan-tools for foreign-arch cross builds"
    else
      sdk_components+=( vulkan-tools )
    fi
    if cross_build_enabled; then
      log "Skipping gfxreconstruct for foreign-arch cross builds"
    else
      sdk_components+=( gfxreconstruct )
    fi
    if cross_build_enabled; then
      log "Skipping VulkanCapsViewer for foreign-arch cross builds"
    else
      sdk_components+=( vcv )
    fi
    if cross_build_enabled; then
      log "Skipping slang for foreign-arch cross builds"
    elif [[ "$arch_suffix" != "riscv64" ]]; then
      sdk_components+=( slang )
    else
      log "Skipping slang on riscv64 (not yet ported)"
    fi

    ${SUDO:-sudo} --preserve-env=PATH,LD_LIBRARY_PATH,LIBRARY_PATH,PKG_CONFIG_PATH,PKG_CONFIG_LIBDIR,PKG_CONFIG_ALLOW_CROSS,PKG_CONFIG_SYSROOT_DIR,CMAKE_PREFIX_PATH,CMAKE_INCLUDE_PATH,CPATH,C_INCLUDE_PATH,CPLUS_INCLUDE_PATH \
      ./vulkansdk -j "$JOBS" "${sdk_components[@]}"
  )
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
  wget --timeout=30 --tries=3 -q "$url" -O "$tarball" || die "Failed to download Vulkan SDK"
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
    _patch_vulkan_sdk_for_cross_build "$arch_suffix" "$target_dir" "$target_triplet"
  fi
}
