#!/usr/bin/env bash
set -euo pipefail

# setup-vulkan-symlinks.sh
# Creates architecture symlinks under /opt/vulkan and links /opt/vulkan/active
# to the appropriate architecture folder.
#
# The Vulkan SDK installs only under x86_64/; this creates aarch64/ and riscv64/
# symlinks pointing at x86_64/ so the runtime can find ICDs on any architecture.

main() {
  local target_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-amd64}}}"

  for vulkan_dir in /opt/vulkan/*/; do
    [ -d "${vulkan_dir}" ] || continue

    if [ -d "${vulkan_dir}/x86_64" ] && [ ! -e "${vulkan_dir}/aarch64" ]; then
      ln -sf x86_64 "${vulkan_dir}/aarch64"
    fi
    if [ -d "${vulkan_dir}/x86_64" ] && [ ! -e "${vulkan_dir}/riscv64" ]; then
      ln -sf x86_64 "${vulkan_dir}/riscv64"
    fi

    local arch_dir
    case "${target_arch}" in
      amd64)   arch_dir="x86_64" ;;
      arm64|aarch64) arch_dir="aarch64" ;;
      riscv64) arch_dir="riscv64" ;;
      *)       arch_dir="x86_64" ;;
    esac

    ln -sf "${vulkan_dir}${arch_dir}" /opt/vulkan/active
  done
}

main "$@"
