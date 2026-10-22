#!/usr/bin/env bash
# Provisioning shares the driver's architecture mapping and target SDK builder.

_vulkan_download_sdk() {
  local url="$1" tarball="$2"
  log "Downloading ${tarball} from ${url}"
  # Verified: the SDK ships shader compilers the builds run. VULKAN_SDK_SHA256 bumps with VULKAN_VERSION.
  if [ -n "${VULKAN_SDK_SHA256:-}" ]; then
    download_verified_file "$url" "${VULKAN_SDK_SHA256}" "$tarball" || die "Failed to download/verify Vulkan SDK"
  else
    log "WARNING: VULKAN_SDK_SHA256 unset — fetching the Vulkan SDK UNVERIFIED (pin it in versions.env alongside VULKAN_VERSION)"
    download_file "$url" "$tarball" 3 30 || die "Failed to download Vulkan SDK"
  fi
  [ -s "$tarball" ] || die "Downloaded tarball is empty"
}

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

  # See docs/vulkan-foreign-arch-sdk.md § The target needs its own dev packages
  local -a target_optional_packages=(
    libgl-dev libglx-dev libopengl-dev libegl-dev
    qt6-base-dev
  )

  apt_install "${host_packages[@]}"

  # The SDK builder runs the active venv python, which cannot see apt's python3-jsonschema.
  if command -v uv >/dev/null 2>&1 && [ -x /opt/python/.venv/bin/python ]; then
    UV_PYTHON=/opt/python/.venv/bin/python uv pip install jsonschema >/dev/null 2>&1 \
      || log "jsonschema venv install failed (schema validation will be skipped — non-fatal)"
  fi

  # Keep this guard. See docs/vulkan-foreign-arch-sdk.md § Building on a native arm64 host
  if cross_build_is_active && \
     command -v install_target_packages >/dev/null 2>&1; then
    install_target_packages "${target_pkgconfig_packages[@]}"
    if command -v install_optional_target_packages >/dev/null 2>&1; then
      install_optional_target_packages "${target_optional_packages[@]}"
    fi
  fi

  # Outside the guard: the native-target case, which installs nothing, is when the report matters.
  _vulkan_report_wsi_link_libs
}

install_vulkan_sdk() {
  # End on the versions.env pin: VULKAN_VERSION_DEFAULT exists only when --vulkan-version was passed.
  local version="${1:-${VULKAN_VERSION_DEFAULT:-${VULKAN_VERSION:?VULKAN_VERSION (or an explicit argument) required}}}"
  log "Installing Vulkan SDK ${version} via tarball"
  install_vulkan_prereqs

  local normalized_arch; normalized_arch="$(arch_normalize "${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}")"
  local arch_suffix; arch_suffix="$(arch_uname_name_for "${normalized_arch}")"
  local target_triplet; target_triplet="$(arch_deb_multiarch_triplet_for "${normalized_arch}")"
  [ -n "${arch_suffix}" ] || die "Unknown or unsupported architecture: ${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}"
  [ -n "${target_triplet}" ] || die "Unknown or unsupported architecture: ${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}"

  local tarball="vulkansdk-linux-x86_64-${version}.tar.xz"
  local url="https://sdk.lunarg.com/sdk/download/${version}/linux/${tarball}"
  _vulkan_download_sdk "${url}" "${tarball}"

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
