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

  # make a safe tempdir, extract there
  tmpd="$(mktemp -d)"
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

  if [ "$arch_suffix" = "aarch64" ]; then
    (
      cd "${target_dir}"
      chmod +x vulkansdk
      log "Patching vulkansdk for non-interactive installs on ARM"
      sed -E -i.bak \
        -e '/\bapt(-get)?[[:space:]]+install\b/ { /(-y|--assume-yes|--assumeyes|--yes)/! s/(\bapt(-get)?[[:space:]]+install\b)/\1 -y/ }' \
        -e '/\bdnf[[:space:]]+install\b/     { /(-y|--assumeyes|--assume-yes|--yes)/! s/(\bdnf[[:space:]]+install\b)/\1 -y/ }' \
        -e '/\bpacman[[:space:]]+-S\b/         { /(--noconfirm|-y)/! s/(\bpacman[[:space:]]+-S\b)/\1 -y/ }' \
        ./vulkansdk
      log "Building selected SDK components..."
      JOBS=$(nproc)
      [ "$JOBS" -lt 1 ] && JOBS=1
      ./vulkansdk -j "$JOBS" \
        glslang vulkan-tools vulkan-headers vulkan-loader \
        vulkan-validationlayers shaderc spirv-headers spirv-tools \
        vulkan-extensionlayer volk vma vcv vul slang
    )
  fi
}
