#!/usr/bin/env bash
# vulkan.sh - Vulkan SDK install
install_vulkan_prereqs() {
  log "Installing Vulkan SDK prerequisites"
  apt_install xz-utils libglm-dev libxcb-dri3-0 \
    libxcb-present0 libpciaccess0 libpng-dev libxcb-keysyms1-dev \
    libxcb-dri3-dev libx11-dev g++ gcc libwayland-dev \
    libxrandr-dev libxcb-randr0-dev libxcb-ewmh-dev git \
    python3 bison libx11-xcb-dev liblz4-dev libzstd-dev \
    ocaml ninja-build pkg-config libxml2-dev \
    wayland-protocols python3-jsonschema clang-format qtbase5-dev qt6-base-dev \
    libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev
}
# default install location — overrideable from environment
VULKAN_INSTALL_ROOT="${VULKAN_INSTALL_ROOT:-/opt/vulkan}"
# custom tmp directory — overrideable from environment
VULKAN_TMP_DIR="${VULKAN_TMP_DIR:-/opt/tmp}"
install_vulkan_sdk() {
  local version="${1:-$VULKAN_VERSION_DEFAULT}"
  log "Installing Vulkan SDK ${version} via tarball"
  install_vulkan_prereqs
  local arch_suffix="x86_64"
  case "$ARCH" in
    x86_64) arch_suffix="x86_64" ;;
    aarch64|arm64) arch_suffix="aarch64" ;;
    riscv64|riscv|rv64*) arch_suffix="riscv64" ;;
    *) die "Unknown or unsupported architecture: $ARCH" ;;
  esac
  local tarball="vulkansdk-linux-x86_64-${version}.tar.xz"
  local url="https://sdk.lunarg.com/sdk/download/${version}/linux/${tarball}"
  log "Downloading ${tarball} from ${url}"
  wget --timeout=30 --tries=3 -q "$url" -O "$tarball" || die "Failed to download Vulkan SDK"
  [ -s "$tarball" ] || die "Downloaded tarball is empty"
  log "Extracting Vulkan SDK to ${VULKAN_INSTALL_ROOT}/${version}..."
  # ensure custom tmp directory exists with proper permissions
  sudo mkdir -p "$VULKAN_TMP_DIR" || die "Failed to create ${VULKAN_TMP_DIR}"
  sudo chmod 1777 "$VULKAN_TMP_DIR" || die "Failed to set permissions on ${VULKAN_TMP_DIR}"
  # make a safe tempdir in custom location
  tmpd="$(mktemp -d -p "$VULKAN_TMP_DIR" vulkan-sdk-XXXXXX 2>/dev/null)" || die "mktemp failed in ${VULKAN_TMP_DIR}"
  tar -xJf "$tarball" -C "$tmpd" || die "tar extraction failed"
  # ensure install root exists and is writable (use sudo if not root)
  sudo mkdir -p "$VULKAN_INSTALL_ROOT" || die "Failed to create ${VULKAN_INSTALL_ROOT}"
  # move the extracted tree into $VULKAN_INSTALL_ROOT/$version
  entries=( "$tmpd"/* )
  target_dir="${VULKAN_INSTALL_ROOT}/${version}"
  if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
    sudo rm -rf "${target_dir}"
    sudo mv "${entries[0]}" "${target_dir}" || die "Failed to move SDK to ${target_dir}"
  else
    sudo rm -rf "${target_dir}"
    sudo mkdir -p "${target_dir}"
    sudo mv "$tmpd"/* "${target_dir}/" || die "Failed to move SDK contents to ${target_dir}"
  fi
  # cleanup
  rm -rf "$tmpd"
  rm -f "$tarball"
  # set ownership & permissions (optional; adjust if you want something else)
  sudo chown -R root:root "${target_dir}"
  sudo chmod -R a+rX "${target_dir}"
  log "Extracted to: ${target_dir}"
  log "To use in a shell: source ${target_dir}/setup-env.sh"
  if [[ "$arch_suffix" == "aarch64" || "$arch_suffix" == "riscv64" ]]; then
    (
      cd "${target_dir}"
      sudo chmod +x vulkansdk
      log "Patching vulkansdk for non-interactive installs on ${arch_suffix}"
      sudo sed -E -i.bak \
        -e '/\bapt(-get)?[[:space:]]+install\b/ { /(-y|--assume-yes|--assumeyes|--yes)/! s/(\bapt(-get)?[[:space:]]+install\b)/\1 -y/ }' \
        -e '/\bdnf[[:space:]]+install\b/     { /(-y|--assumeyes|--assume-yes|--yes)/! s/(\bdnf[[:space:]]+install\b)/\1 -y/ }' \
        -e '/\bpacman[[:space:]]+-S\b/         { /(--noconfirm|-y)/! s/(\bpacman[[:space:]]+-S\b)/\1 -y/ }' \
        ./vulkansdk

      # Ensure libgcc_s and libstdc++ are findable by the linker for riscv64/aarch64 builds
      # The custom GCC install puts runtime libs in /opt/gcc-*/lib64, but CMake subprocesses
      # may not inherit LIBRARY_PATH. Create symlinks in architecture-specific paths.
      # Multiarch path: /usr/lib/<arch>-linux-gnu/ (e.g., /usr/lib/riscv64-linux-gnu/)
      ARCH_LIB_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "${ARCH}-linux-gnu")"
      sudo mkdir -p "${ARCH_LIB_DIR}" /usr/lib
      
      if [[ -n "${LIBRARY_PATH:-}" ]]; then
        log "Setting up GCC runtime library symlinks for linking..."
        for libdir in ${LIBRARY_PATH//:/ }; do
          for lib in libgcc_s.so.1 libgcc_s.so libstdc++.so.6 libstdc++.so; do
            if [[ -f "${libdir}/${lib}" ]]; then
              # Symlink to multiarch directory (primary linker search path)
              if [[ ! -e "${ARCH_LIB_DIR}/${lib}" ]]; then
                sudo ln -sf "${libdir}/${lib}" "${ARCH_LIB_DIR}/${lib}" 2>/dev/null || true
              fi
              # Also symlink to /usr/lib as fallback
              if [[ ! -e "/usr/lib/${lib}" ]]; then
                sudo ln -sf "${libdir}/${lib}" "/usr/lib/${lib}" 2>/dev/null || true
              fi
            fi
          done
        done
        log "Symlinked GCC runtime libraries to ${ARCH_LIB_DIR} and /usr/lib"
      fi
      # Run ldconfig to update linker cache
      sudo ldconfig 2>/dev/null || true

      log "Building selected SDK components..."
      JOBS="$(compute_jobs "${JOBS:-}")"
      # Base components to build
      local sdk_components=(
        glslang vulkan-headers vulkan-loader
        vulkan-validationlayers shaderc spirv-headers spirv-tools
        vulkan-extensionlayer volk vma vul
        spirv-cross spirv-reflect vulkan-profiles
      )
      if [ "${BUILD_MODE:-native}" = "cross" ]; then
        log "Skipping vulkan-tools in cross mode; vulkaninfo/vkcube would link against host GUI libraries on the amd64 builder"
      else
        sdk_components+=( vulkan-tools )
      fi
      if [ "${BUILD_MODE:-native}" = "cross" ]; then
        log "Skipping gfxreconstruct in cross mode; its build currently requires target-side LZ4 resolution not present in the amd64 artifact builder"
      else
        sdk_components+=( gfxreconstruct )
      fi
      if [ "${BUILD_MODE:-native}" = "cross" ]; then
        log "Skipping VulkanCapsViewer in cross mode; it requires target-side Qt6 packages that are not present on the amd64 artifact builder"
      else
        sdk_components+=( vcv )
      fi
      if [ "${BUILD_MODE:-native}" = "cross" ]; then
        log "Skipping slang in cross mode; its build generates target helper binaries that the amd64 artifact builder cannot execute"
      elif [[ "$arch_suffix" != "riscv64" ]]; then
        sdk_components+=( slang )
      else
        log "Skipping slang on riscv64 (not yet ported)"
      fi
      # Preserve critical environment variables through sudo for linking (libgcc_s, etc.)
      # sudo --preserve-env passes PATH, LD_LIBRARY_PATH, LIBRARY_PATH, etc. to the subprocess
      sudo --preserve-env=PATH,LD_LIBRARY_PATH,LIBRARY_PATH,PKG_CONFIG_PATH \
        ./vulkansdk -j "$JOBS" "${sdk_components[@]}"
    )
  fi
}
