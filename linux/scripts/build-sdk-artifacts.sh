#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
COMPILER_IMAGE="${COMPILER_IMAGE:-${IMAGE_REGISTRY_PREFIX}:cross-compiler-amd64}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-sdk}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-${CROSS_DEFAULT_ARCHES}}}}"
# VULKAN_VERSION default comes from versions.env via artifact-common.sh
VULKAN_VERSION="${VULKAN_VERSION:-1.4.341.1}"
IMAGE_PREFIX="${IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:cross-sdk}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT}}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
PUSH_IMAGES=0

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
  --compiler-image TAG   Cross compiler image to use as base
  --fast-ubuntu-mirror   Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL
                           Mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                          Optional mirror URL for ubuntu-ports entries
  --vulkan-version VER   Vulkan SDK version to build
  --push                Push each built SDK artifact image after export
  -h, --help             Show this help text

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  TARGET_ARCHES          Comma-separated target list
  TARGET_ARCH            Alias for TARGET_ARCHES
  ARCHITECTURES          Alias for TARGET_ARCHES
  OUTPUT_ROOT            Root directory for exported rootfs artifacts
  COMPILER_IMAGE         Cross compiler image to use as base
  VULKAN_VERSION         Vulkan SDK version
  IMAGE_PREFIX           Prefix for local artifact image tags
  USE_FAST_UBUNTU_MIRROR Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}

ensure_compiler_image() {
  if image_exists "${NERDCTL_BIN}" "${COMPILER_IMAGE}"; then
    log "Using existing cross compiler image: ${COMPILER_IMAGE}"
    return 0
  fi

  log "Cross compiler image missing; bootstrapping it first"
  run env \
    NERDCTL_BIN="${NERDCTL_BIN}" \
    BUILDKIT_HOST="${BUILDKIT_HOST:-}" \
    COMPILER_LOCAL_TAG="${COMPILER_IMAGE}" \
    COMPILER_REMOTE_TAG="${COMPILER_IMAGE}" \
    CROSS_TARGETS="${TARGET_ARCHES}" \
    USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR}" \
    FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL}" \
    FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL}" \
    bash "${REPO_ROOT}/linux/scripts/build-cross-compiler.sh"

  image_exists "${NERDCTL_BIN}" "${COMPILER_IMAGE}" || {
    printf '[ERROR] Required compiler image not available after bootstrap: %s\n' "${COMPILER_IMAGE}" >&2
    exit 1
  }
}

build_sdk_image() {
  local arch="$1"
  local tag="$2"
  local -a build_args=()
  append_mirror_build_args_from_env build_args
  append_version_build_args build_args

  run_nerdctl_build "${NERDCTL_BIN}" \
    --pull=false \
    --platform linux/amd64 \
    -t "${tag}" \
    -f linux/Dockerfile.sdk \
    --build-arg BASE_IMAGE="${COMPILER_IMAGE}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${arch}" \
    --build-arg VULKAN_VERSION="${VULKAN_VERSION}" \
    "${build_args[@]}" \
    .
}

push_sdk_image() {
  local tag="$1"
  run "${NERDCTL_BIN}" push "${tag}"
}

main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    dispatch_parsed_args parse_shared_orchestrator_args \
      TARGET_ARCHES USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IGNORED_REPO VULKAN_VERSION PUSH_IMAGES \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      --output-root)
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --compiler-image)
        COMPILER_IMAGE="$2"
        shift 2
        ;;
      *)
        printf '[ERROR] Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  cd "${REPO_ROOT}"
  TARGET_ARCHES="$(normalize_target_arches "${TARGET_ARCHES}")"
  ensure_compiler_image
  log "Building SDK artifacts for target arches: ${TARGET_ARCHES}"

  local arch
  local tag
  for arch in ${TARGET_ARCHES//,/ }; do
    tag="${IMAGE_PREFIX}-${arch}"
    build_sdk_image "${arch}" "${tag}"
    export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${arch}" \
      "TARGET_ARCH=${arch}" \
      "SOURCE_IMAGE=${tag}" \
      "VULKAN_VERSION=${VULKAN_VERSION}"
    if [ "${PUSH_IMAGES}" -eq 1 ]; then
      push_sdk_image "${tag}"
    fi
  done
}

main "$@"
