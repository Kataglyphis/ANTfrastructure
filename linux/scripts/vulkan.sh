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

install_vulkan_sdk() {
  local version="${1:-$VULKAN_VERSION_DEFAULT}"
  log "Installing Vulkan SDK ${version} via tarball"
  install_vulkan_prereqs

  local arch_suffix="x86_64"
  case "$ARCH" in
    x86_64) arch_suffix="x86_64" ;;
    aarch64|arm64) arch_suffix="aarch64" ;;
    *) die "Unknown or unsupported architecture: $ARCH" ;;
  esac

  local tarball="vulkansdk-linux-${arch_suffix}-${version}.tar.xz"
  local url="https://sdk.lunarg.com/sdk/download/${version}/linux/${tarball}"

  log "Downloading ${tarball} from ${url}"
  wget --timeout=30 --tries=3 -q "$url" -O "$tarball" || die "Failed to download Vulkan SDK"
  [ -s "$tarball" ] || die "Downloaded tarball is empty"

  log "Extracting Vulkan SDK..."
  tar xf "$tarball"
  rm -f "$tarball"
  [ -d "$version" ] || die "Extraction failed"

  log "Extracted to: $version"
  log "To use in a shell: source ${version}/setup-env.sh"

  if [ "$arch_suffix" = "aarch64" ]; then
    (
      cd "$version"
      chmod +x vulkansdk
      log "Patching vulkansdk for non-interactive installs on ARM"
      sed -E -i.bak \
        -e '/\bapt(-get)?[[:space:]]+install\b/ { /(-y|--assume-yes|--assumeyes|--yes)/! s/(\bapt(-get)?[[:space:]]+install\b)/\1 -y/ }' \
        -e '/\bdnf[[:space:]]+install\b/     { /(-y|--assumeyes|--assume-yes|--yes)/! s/(\bdnf[[:space:]]+install\b)/\1 -y/ }' \
        -e '/\bpacman[[:space:]]+-S\b/         { /(--noconfirm|-y)/! s/(\bpacman[[:space:]]+-S\b)/\1 -y/ }' \
        ./vulkansdk
      log "Building selected SDK components..."
      ./vulkansdk -j "$(nproc)" \
        glslang vulkan-tools vulkan-headers vulkan-loader \
        vulkan-validationlayers shaderc spirv-headers spirv-tools \
        vulkan-extensionlayer volk vma vcv vul slang
    )
  fi
}