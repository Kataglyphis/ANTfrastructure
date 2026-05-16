#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-runtime}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-amd64,arm64,riscv64}}}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-runtime}"
ANDROID_IMAGE_PREFIX="${ANDROID_IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
PUSH_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-runtime-artifacts.sh [options]

Builds target-specific final runtime images from linux/Dockerfile in BUILD_MODE=cross,
exports their root filesystems, and optionally pushes the intermediate images.

Expected result:
  out/linux-runtime/amd64/rootfs/
  out/linux-runtime/arm64/rootfs/
  out/linux-runtime/riscv64/rootfs/

Options:
  --target-arches LIST   Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST   Alias for --target-arches
  --output-root DIR      Export directory root (default: out/linux-runtime)
  --image-prefix TAG     Prefix for intermediate runtime image tags
  --android-image-prefix TAG
                         Prefix for base android-cross image tags
  --fast-ubuntu-mirror   Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL
                         Mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                         Optional mirror URL for ubuntu-ports entries
  --push                 Push each built runtime artifact image after export
  -h, --help             Show this help text
EOF
}

image_exists() {
  "${NERDCTL_BIN}" image inspect "$1" >/dev/null 2>&1
}

ensure_base_image() {
  local image="$1"

  if image_exists "${image}"; then
    log "Using existing local base image: ${image}"
    return 0
  fi

  log "Pulling runtime base image: ${image}"
  run "${NERDCTL_BIN}" pull --platform linux/amd64 "${image}"
}

build_runtime_image() {
  local arch="$1"
  local tag="$2"
  local base_image="${ANDROID_IMAGE_PREFIX}-${arch}"
  local -a mirror_build_args=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${USE_FAST_UBUNTU_MIRROR}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${FAST_UBUNTU_MIRROR_URL}"
  )

  if [ -n "${FAST_UBUNTU_PORTS_MIRROR_URL}" ]; then
    mirror_build_args+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${FAST_UBUNTU_PORTS_MIRROR_URL}")
  fi

  ensure_base_image "${base_image}"

  run "${NERDCTL_BIN}" build \
    --pull=false \
    --platform linux/amd64 \
    -t "${tag}" \
    -f linux/Dockerfile \
    --build-arg BASE_IMAGE="${base_image}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${arch}" \
    "${mirror_build_args[@]}" \
    .
}

push_runtime_image() {
  local tag="$1"
  run "${NERDCTL_BIN}" push "${tag}"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --architectures|--target-arches)
        TARGET_ARCHES="$2"
        shift 2
        ;;
      --output-root)
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --image-prefix)
        IMAGE_PREFIX="$2"
        shift 2
        ;;
      --android-image-prefix)
        ANDROID_IMAGE_PREFIX="$2"
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
  log "Building final runtime artifacts for target arches: ${TARGET_ARCHES}"

  local arch
  local tag
  for arch in ${TARGET_ARCHES//,/ }; do
    tag="${IMAGE_PREFIX}-${arch}"
    build_runtime_image "${arch}" "${tag}"
    export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${arch}" \
      "TARGET_ARCH=${arch}" \
      "SOURCE_IMAGE=${tag}" \
      "BASE_IMAGE=${ANDROID_IMAGE_PREFIX}-${arch}"
    if [ "${PUSH_IMAGES}" -eq 1 ]; then
      push_runtime_image "${tag}"
    fi
  done
}

main "$@"
