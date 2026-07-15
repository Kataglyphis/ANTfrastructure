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
  --target-arches LIST   Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST   Alias for --target-arches
  --output-root DIR      Export directory root (default: out/linux-sdk)
EOF
  orchestrator_usage_mirror_options
  cat <<'EOF'
  --vulkan-version VER   Vulkan SDK version to build
  --push                 Push each built SDK artifact image after export
  --parallel-archs       Build per-architecture images in parallel
  --max-parallel-archs N Max concurrent arch builds (default: nproc)
  -h, --help             Show this help text

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  TARGET_ARCHES          Comma-separated target list
  TARGET_ARCH            Alias for TARGET_ARCHES
  ARCHITECTURES          Alias for TARGET_ARCHES
  OUTPUT_ROOT            Root directory for exported rootfs artifacts
  VULKAN_VERSION         Vulkan SDK version
  IMAGE_REPO             Registry prefix for image tags
  USE_FAST_UBUNTU_MIRROR Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
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
  cross_stage_run "sdk" "${arch}" "${PUSH_IMAGES}"
  export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${arch}" \
    "TARGET_ARCH=${arch}" \
    "SOURCE_IMAGE=${tag}" \
    "VULKAN_VERSION=${VULKAN_VERSION}"
}

main "$@"
