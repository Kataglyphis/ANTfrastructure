#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FOUND_MODULES=0
# shellcheck disable=SC1091
for _bs_path in "/opt/scripts/core/modules.sh" "${SCRIPT_DIR}/modules.sh" "${SCRIPT_DIR}/../01-core/modules.sh"; do
  if [ -f "${_bs_path}" ]; then
    source "${_bs_path}"
    source_modules_framework "${SCRIPT_DIR}"
    _FOUND_MODULES=1
    break
  fi
done
[ "${_FOUND_MODULES}" -eq 1 ] || { echo "Error: modules.sh not found" >&2; exit 1; }
unset _bs_path _FOUND_MODULES

# Source required modules. cmake.sh, vulkan.sh AND llvm.sh are sourced LAZILY
# (in their own dispatch arms below), NOT here. TG1 established the pattern
# for cmake/vulkan; TG1-residual (2026-08-24) extends it to llvm.sh, whose
# whole family (llvm.sh -> llvm-cross.sh + llvm-validate.sh at source time,
# plus the build-clang.sh it exec's) has exactly THREE consumers outside
# those files (audit: every function defined in the trio grepped against the
# eager closure — zero hits anywhere on the gcc path):
#   install_llvm_clang             -> llvm / dockerfile-llvm / all arms
#   install_target_clang_toolchain -> target-clang arm
#   verify_cross_llvm_targets      -> verify_summary (verify / all arms),
#                                     behind the declare -F guard in
#                                     01-core/verify.sh
# Each of those arms sources llvm.sh first, so the GCC RUN (dockerfile-gcc)
# drops the four llvm bind-mounts and an llvm-cross.sh / llvm-validate.sh /
# build-clang.sh edit no longer invalidates the multi-hour GCC layer. A
# wrongly-classified arm fails FAST at `source_module llvm.sh`
# (module-not-found) BEFORE any compile starts — never mid-build.
source_module common.sh
source_module cross-env.sh
source_module repos.sh
source_module core.sh
source_module gcc.sh
source_module verify.sh

usage() {
  cat <<EOF
Usage: $0 [--llvm N] [--clang N] [--gcc N] [--vulkan-version V] [--arch A] <all|base|repos|cmake|llvm|gcc|vulkan|verify|dockerfile-gcc|dockerfile-llvm|target-clang>

Examples:
  $0 --llvm 22 --clang 22 --gcc 16 cmake
  $0 --llvm 22 --clang 22 --gcc 16 llvm
  $0 --vulkan-version 1.4.328.1 vulkan
  $0 --llvm 22 --clang 22 --gcc 16 --vulkan-version 1.4.328.1 all
EOF
}

skip_core_tools() {
  case "${SETUP_DEPENDENCIES_SKIP_CORE_TOOLS:-false}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

setup_dependencies_apply_arch_override() {
  local normalized_arch_override="${1:-}"

  [ -n "${normalized_arch_override}" ] || return 0
  cross_set_target_env "${normalized_arch_override}" "setup-dependencies.sh --arch"
  ARCH="$(arch_uname_name_for "${TARGET_ARCH}")"
  export ARCH
}

setup_dependencies_seed_verify_cross_targets() {
  local cmd="${1:-}"
  local normalized_arch_override="${2:-}"

  [ -n "${normalized_arch_override}" ] || return 0
  cross_mode_requested || return 0
  [ -z "${VERIFY_CROSS_TARGETS:-}" ] || return 0

  case "${cmd}" in
    verify|all)
      VERIFY_CROSS_TARGETS="${normalized_arch_override}"
      export VERIFY_CROSS_TARGETS
      ;;
  esac
}

install_core_tools_if_needed() {
  if skip_core_tools; then
    log "Skipping install_core_tools because SETUP_DEPENDENCIES_SKIP_CORE_TOOLS=${SETUP_DEPENDENCIES_SKIP_CORE_TOOLS}"
    return 0
  fi

  install_core_tools
}

install_vulkan_for_current_env() {
  local version="$1"

  if cross_mode_requested; then
    (
      prepare_cross_target_env "${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}" "setup-dependencies.sh vulkan"
      install_vulkan_sdk "${version}"
    )
  else
    install_vulkan_sdk "${version}"
  fi
}

dockerfile_install_gcc() {
  install_core_tools_if_needed
  GCC_WANTED="$(version_major "${GCC_VERSION:-${GCC_WANTED:-16}}")"
  export GCC_WANTED
  install_gcc
}

dockerfile_install_llvm() {
  install_core_tools_if_needed
  LLVM_WANTED="$(version_major "${LLVM_RELEASE:-${LLVM_WANTED:-${CLANG_WANTED:-22}}}")"
  CLANG_WANTED="${LLVM_WANTED}"
  export LLVM_WANTED CLANG_WANTED
  install_llvm_clang
}

main() {
  local cmd="all"
  local arch_override=""
  local normalized_arch_override=""

  # Parse args
  while [ $# -gt 0 ]; do
    case "$1" in
      --llvm)          LLVM_WANTED="$2"; shift 2 ;;
      --clang)         CLANG_WANTED="$2"; shift 2 ;;
      --gcc)           GCC_WANTED="$2"; shift 2 ;;
      --vulkan-version)VULKAN_VERSION_DEFAULT="$2"; shift 2 ;;
      --arch)          arch_override="$2"; shift 2 ;;
      all|base|repos|cmake|llvm|gcc|vulkan|verify|dockerfile-gcc|dockerfile-llvm|target-clang)
        cmd="$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  # Export for modules
  export LLVM_WANTED CLANG_WANTED GCC_WANTED VULKAN_VERSION_DEFAULT

  if [ -n "$arch_override" ]; then
    normalized_arch_override="$(cross_require_single_target_arch "${arch_override}" "setup-dependencies.sh --arch")"
    setup_dependencies_apply_arch_override "${normalized_arch_override}"
  fi

  require_sudo
  detect_system
  if [ -n "$normalized_arch_override" ]; then
    setup_dependencies_apply_arch_override "${normalized_arch_override}"
    log "Overridden arch=${normalized_arch_override}"
  fi
  setup_dependencies_seed_verify_cross_targets "${cmd}" "${normalized_arch_override}"

  case "$cmd" in
    base)
      install_core_tools_if_needed
      ;;
    repos)
      add_kitware_repo
      add_llvm_repo
      ;;
    cmake)
      source_module cmake.sh   # TG1: lazy — sourced only where install_cmake is used
      install_core_tools_if_needed
      install_cmake
      ;;
    llvm)
      source_module llvm.sh   # TG1-residual: lazy — see the header note
      install_core_tools_if_needed
      install_llvm_clang
      ;;
    gcc)
      install_core_tools_if_needed
      install_gcc
      ;;
    vulkan)
      source_module vulkan.sh   # TG1: lazy — sourced only where install_vulkan_* is used
      [ -n "${VULKAN_VERSION_DEFAULT:-}" ] || die "--vulkan-version is required for the vulkan command"
      install_core_tools_if_needed
      install_vulkan_for_current_env "$VULKAN_VERSION_DEFAULT"
      ;;
    verify)
      # llvm.sh MUST be sourced here: verify_summary calls
      # verify_cross_llvm_targets behind a `declare -F` guard — without this
      # the cross-LLVM verification (toolchain RUN 3c + the sdk verify RUN)
      # would silently self-disable instead of failing.
      source_module llvm.sh   # TG1-residual: lazy — see the header note
      verify_summary
      ;;
    dockerfile-gcc)
      dockerfile_install_gcc
      ;;
    dockerfile-llvm)
      source_module llvm.sh   # TG1-residual: lazy — see the header note
      dockerfile_install_llvm
      ;;
    target-clang)
      source_module llvm.sh   # TG1-residual: lazy — see the header note
      install_core_tools_if_needed
      install_target_clang_toolchain "${normalized_arch_override:-${TARGET_ARCH:-${TARGETARCH:-}}}"
      ;;
    all)
      source_module cmake.sh    # TG1: lazy modules — the `all` path needs all three
      source_module vulkan.sh
      source_module llvm.sh
      [ -n "${VULKAN_VERSION_DEFAULT:-}" ] || die "--vulkan-version is required for the all command"
      install_core_tools_if_needed
      install_cmake
      install_llvm_clang
      install_gcc
      install_vulkan_for_current_env "$VULKAN_VERSION_DEFAULT"
      verify_summary
      ;;
  esac
}

main "$@"
