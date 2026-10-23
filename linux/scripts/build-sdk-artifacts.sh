#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
orchestrator_preamble

OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-sdk}"
TARGET_ARCHES="$(resolve_arch_list)"
CROSS_TARGETS="${CROSS_TARGETS:-${TARGET_ARCHES}}"
PUSH_IMAGES=0
# shellcheck disable=SC2034 # default for the arch loop in parallel-loop.sh
PARALLEL_ARCHS=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"

usage() {
  cat <<'EOF'
Usage: build-sdk-artifacts.sh [options]

Builds target-specific SDK artifact images on an amd64 host and exports their
root filesystems into per-architecture output directories.
The images stay local unless --push is requested.

Expected result:
  out/linux-sdk/amd64/rootfs/
  out/linux-sdk/arm64/rootfs/
  out/linux-sdk/riscv64/rootfs/

Options:
EOF
  runtime_usage_row '--target-arches LIST' 25 sdk
  runtime_usage_row '--architectures LIST' 25 sdk
  cat <<'EOF'
  --output-root DIR      Export directory root (default: out/linux-sdk)
EOF
  orchestrator_usage_mirror_options
  cat <<'EOF'
  --vulkan-version VER   Vulkan SDK version to build
  --push                 Push each built SDK artifact image after export
EOF
  runtime_usage_row --parallel-archs 25 sdk
  runtime_usage_row '--max-parallel-archs N' 25 sdk
  cat <<'EOF'
  -h, --help             Show this help text

Environment overrides:
EOF
  runtime_usage_row NERDCTL_BIN 25 sdk
  runtime_usage_row TARGET_ARCHES 25 sdk
  runtime_usage_row TARGET_ARCH 25 sdk
  runtime_usage_row ARCHITECTURES 25 sdk
  cat <<'EOF'
  OUTPUT_ROOT            Root directory for exported rootfs artifacts
  VULKAN_VERSION         Vulkan SDK version
  IMAGE_REPO             Registry prefix for image tags
EOF
  runtime_usage_row USE_FAST_UBUNTU_MIRROR 25 sdk
  runtime_usage_row FAST_UBUNTU_MIRROR_URL 25 sdk
  runtime_usage_row FAST_UBUNTU_PORTS_MIRROR_URL 31 sdk
}

_sdk_extra_arg() {
  case "$1" in
    --output-root) OUTPUT_ROOT="$2"; _OARG_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

main() {
  run_orchestrator_arg_loop usage _sdk_extra_arg \
    TARGET_ARCHES USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
    FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION PUSH_IMAGES \
    "$@"

  cd "${REPO_ROOT}"
  CROSS_TARGETS="${TARGET_ARCHES}"

  log "Building SDK artifacts for target arches: ${TARGET_ARCHES} (push=${PUSH_IMAGES})"

  # Build the compiler stage first (shared by all SDK per-arch builds).
  cross_stage_run "compiler" "" "${PUSH_IMAGES}"

  run_parallel_arch_loop _sdk_arch_build "$(arch_loop_flag_prefix sdk-arch-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
}

_sdk_arch_build() {
  local arch="$1" tag
  tag="$(cross_sdk_tag "${arch}")"
  # || return 1 is load-bearing: under `if ! fn` errexit is off, and a stale tag would export green.
  cross_stage_run "sdk" "${arch}" "${PUSH_IMAGES}" || return 1
  export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${arch}" \
    "TARGET_ARCH=${arch}" \
    "SOURCE_IMAGE=${tag}" \
    "VULKAN_VERSION=${VULKAN_VERSION}"
}

main "$@"
