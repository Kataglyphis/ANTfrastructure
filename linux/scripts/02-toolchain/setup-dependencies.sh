#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
if [ -f "${SCRIPT_DIR}/../01-core/modules.sh" ]; then
  source "${SCRIPT_DIR}/../01-core/modules.sh"
elif [ -f "/opt/scripts/core/modules.sh" ]; then
  source "/opt/scripts/core/modules.sh"
else
  echo "Error: modules.sh not found (expected ${SCRIPT_DIR}/../01-core/modules.sh or /opt/scripts/core/modules.sh)" >&2
  exit 1
fi

# Source required modules
source_module common.sh
source_module repos.sh
source_module core.sh
source_module cmake.sh
source_module llvm.sh
source_module gcc.sh
source_module vulkan.sh
source_module extras.sh
source_module verify.sh

usage() {
  cat <<EOF
Usage: $0 [--llvm N] [--clang N] [--gcc N] [--vulkan-version V] [--arch A] <all|base|repos|cmake|llvm|gcc|vulkan|extras|verify>

Examples:
  $0 --llvm 22 --clang 22 --gcc 16 cmake
  $0 --llvm 22 --clang 22 --gcc 16 llvm
  $0 --vulkan-version 1.4.328.1 vulkan
  $0 --llvm 22 --clang 22 --gcc 16 --vulkan-version 1.4.328.1 all
EOF
}

main() {
  # Defaults (can be overridden by args)
  LLVM_WANTED="${LLVM_WANTED:-22}"
  CLANG_WANTED="${CLANG_WANTED:-22}"
  GCC_WANTED="${GCC_WANTED:-16}"
  VULKAN_VERSION_DEFAULT="${VULKAN_VERSION_DEFAULT:-1.4.341.1}"

  local cmd="all"
  local arch_override=""

  # Parse args
  while [ $# -gt 0 ]; do
    case "$1" in
      --llvm)          LLVM_WANTED="$2"; shift 2 ;;
      --clang)         CLANG_WANTED="$2"; shift 2 ;;
      --gcc)           GCC_WANTED="$2"; shift 2 ;;
      --vulkan-version)VULKAN_VERSION_DEFAULT="$2"; shift 2 ;;
      --arch)          arch_override="$2"; shift 2 ;;
      all|base|repos|cmake|llvm|gcc|vulkan|extras|verify)
        cmd="$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  # Export for modules
  export LLVM_WANTED CLANG_WANTED GCC_WANTED VULKAN_VERSION_DEFAULT

  require_sudo
  detect_system
  if [ -n "$arch_override" ]; then
    ARCH="$arch_override"
    export ARCH
    log "Overridden arch=${ARCH}"
  fi

  case "$cmd" in
    base)
      install_core_tools
      ;;
    repos)
      add_kitware_repo
      add_llvm_repo
      ;;
    cmake)
      install_core_tools
      install_cmake
      ;;
    llvm)
      install_core_tools
      install_llvm_clang
      ;;
    gcc)
      install_core_tools
      install_gcc
      ;;
    vulkan)
      install_core_tools
      install_vulkan_sdk "$VULKAN_VERSION_DEFAULT"
      ;;
    extras)
      install_extras
      ;;
    verify)
      verify_summary
      ;;
    all)
      install_core_tools
      install_cmake
      install_llvm_clang
      install_gcc
      install_vulkan_sdk "$VULKAN_VERSION_DEFAULT"
      install_extras
      verify_summary
      ;;
  esac
}

main "$@"
