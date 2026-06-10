#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-sdk}"
TARGET_ARCHES="$(resolve_arch_list)"
CROSS_TARGETS="${CROSS_TARGETS:-${TARGET_ARCHES}}"
init_mirror_defaults
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
  --fast-ubuntu-mirror   Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL
                           Mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                          Optional mirror URL for ubuntu-ports entries
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

main() {
  while [ $# -gt 0 ]; do
    consume_shared_arg usage \
      parse_shared_orchestrator_args \
      TARGET_ARCHES USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION PUSH_IMAGES \
      "$1" "${2:-}" || break
    case "${_DP_SHIFT}" in
      1) shift; continue ;;  2) shift 2; continue ;;
    esac
    case "$1" in
      --output-root)
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --parallel-archs)
        PARALLEL_ARCHS=1
        shift
        ;;
      --max-parallel-archs)
        MAX_PARALLEL_ARCHS="$2"
        shift 2
        ;;
      *)
        warn "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  cd "${REPO_ROOT}"
  TARGET_ARCHES="$(normalize_target_arches "${TARGET_ARCHES}")"
  CROSS_TARGETS="${TARGET_ARCHES}"

  log "Building SDK artifacts for target arches: ${TARGET_ARCHES} (push=${PUSH_IMAGES})"

  # Build the compiler stage first (shared by all SDK per-arch builds).
  cross_stage_run "compiler" "" "${PUSH_IMAGES}"

  _sdk_arch_build() {
    local arch="$1" tag
    tag="$(cross_sdk_tag "${arch}")"
    cross_stage_run "sdk" "${arch}" "${PUSH_IMAGES}"
    export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${arch}" \
      "TARGET_ARCH=${arch}" \
      "SOURCE_IMAGE=${tag}" \
      "VULKAN_VERSION=${VULKAN_VERSION}"
  }

  local _flags_dir; _flags_dir="$(mktemp -d "${TMPDIR:-/tmp}/sdk-arch-loop-flags.XXXXXX")"
  run_parallel_arch_loop _sdk_arch_build "${_flags_dir}" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
}

main "$@"
