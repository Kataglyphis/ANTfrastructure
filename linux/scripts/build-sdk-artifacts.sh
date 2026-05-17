#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
COMPILER_IMAGE="${COMPILER_IMAGE:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-sdk}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-amd64,arm64,riscv64}}}"
VULKAN_VERSION="${VULKAN_VERSION:-1.4.341.1}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
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

image_exists() {
  "${NERDCTL_BIN}" image inspect "$1" >/dev/null 2>&1
}

ensure_compiler_image() {
  if image_exists "${COMPILER_IMAGE}"; then
    log "Using existing cross compiler image: ${COMPILER_IMAGE}"
    return 0
  fi

  log "Cross compiler image missing; bootstrapping it first"
  local -a bootstrap_args=()
  if [ "${USE_FAST_UBUNTU_MIRROR}" = "true" ]; then
    bootstrap_args+=(--fast-ubuntu-mirror --fast-ubuntu-mirror-url "${FAST_UBUNTU_MIRROR_URL}")
    if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL}" ]; then
      bootstrap_args+=(--fast-ubuntu-ports-mirror-url "${FAST_UBUNTU_PORTS_MIRROR_URL}")
    fi
  fi
  run bash "${REPO_ROOT}/linux/scripts/build-cross-compiler.sh" "${bootstrap_args[@]}"

  image_exists "${COMPILER_IMAGE}" || {
    printf '[ERROR] Required compiler image not available after bootstrap: %s\n' "${COMPILER_IMAGE}" >&2
    exit 1
  }
}

build_sdk_image() {
  local arch="$1"
  local tag="$2"
  local -a mirror_build_args=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${USE_FAST_UBUNTU_MIRROR}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${FAST_UBUNTU_MIRROR_URL}"
  )

  if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL}" ]; then
    mirror_build_args+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${FAST_UBUNTU_PORTS_MIRROR_URL}")
  fi

  run "${NERDCTL_BIN}" build \
    --pull=false \
    --platform linux/amd64 \
    -t "${tag}" \
    -f linux/Dockerfile.sdk \
    --build-arg BASE_IMAGE="${COMPILER_IMAGE}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${arch}" \
    --build-arg VULKAN_VERSION="${VULKAN_VERSION}" \
    "${mirror_build_args[@]}" \
    .
}

push_sdk_image() {
  local tag="$1"
  run "${NERDCTL_BIN}" push "${tag}"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --architectures)
        TARGET_ARCHES="$2"
        shift 2
        ;;
      --target-arches)
        TARGET_ARCHES="$2"
        shift 2
        ;;
      --output-root)
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --compiler-image)
        COMPILER_IMAGE="$2"
        shift 2
        ;;
      --fast-ubuntu-mirror)
        USE_FAST_UBUNTU_MIRROR=true
        shift
        ;;
      --fast-ubuntu-mirror-url)
        USE_FAST_UBUNTU_MIRROR=true
        FAST_UBUNTU_MIRROR_URL="$2"
        shift 2
        ;;
      --fast-ubuntu-ports-mirror-url)
        USE_FAST_UBUNTU_MIRROR=true
        FAST_UBUNTU_PORTS_MIRROR_URL="$2"
        shift 2
        ;;
      --vulkan-version)
        VULKAN_VERSION="$2"
        shift 2
        ;;
      --push)
        PUSH_IMAGES=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
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
