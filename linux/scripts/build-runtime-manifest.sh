#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_NAME="${IMAGE_NAME:-}"
ARCHITECTURES="${ARCHITECTURES:-amd64,arm64,riscv64}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest}"
ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-linux/Dockerfile.runtime-package}"

PUSH_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-runtime-manifest.sh --image IMAGE [options]

Builds one runtime image per architecture by overlaying target-built payload
from amd64-hosted cross artifact images onto a real target-platform base image,
then optionally pushes a multi-architecture manifest with nerdctl.

Options:
  --image IMAGE           Base image tag to use (required)
  --architectures LIST    Comma-separated list (default: amd64,arm64,riscv64)
  --base-image IMAGE      Real target-platform base image (default: :latest)
  --artifact-image-prefix TAG
                         Prefix for amd64-hosted cross artifact image tags
  --dockerfile PATH      Packaging Dockerfile (default: linux/Dockerfile.runtime-package)
  --push                  Push per-architecture images and the manifest
  -h, --help              Show this help text

Environment overrides:
  NERDCTL_BIN             nerdctl executable to use
  IMAGE_NAME              Base image name, equivalent to --image
  ARCHITECTURES           Comma-separated architecture list
  BASE_IMAGE              Real target-platform base image
  ARTIFACT_IMAGE_PREFIX   Prefix for cross artifact image tags
  DOCKERFILE_PATH         Packaging Dockerfile path
EOF
}

build_arch_image() {
  local arch="$1"
  local tag="${IMAGE_NAME}-${arch}"
  local artifact_image="${ARTIFACT_IMAGE_PREFIX}-${arch}"

  run "${NERDCTL_BIN}" build \
    --pull=true \
    --platform "linux/${arch}" \
    -t "${tag}" \
    -f "${DOCKERFILE_PATH}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "ARTIFACT_IMAGE=${artifact_image}" \
    .

  if [ "${PUSH_IMAGES}" -eq 1 ]; then
    run "${NERDCTL_BIN}" push "${tag}"
  fi
}

create_manifest() {
  local refs=()
  local arch

  for arch in ${ARCHITECTURES//,/ }; do
    refs+=("${IMAGE_NAME}-${arch}")
  done

  "${NERDCTL_BIN}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  run "${NERDCTL_BIN}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_IMAGES}" -eq 1 ]; then
    run "${NERDCTL_BIN}" manifest push --purge "${IMAGE_NAME}"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --image)
        IMAGE_NAME="$2"
        shift 2
        ;;
      --base-image)
        BASE_IMAGE="$2"
        shift 2
        ;;
      --artifact-image-prefix)
        ARTIFACT_IMAGE_PREFIX="$2"
        shift 2
        ;;
      --dockerfile)
        DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --architectures)
        ARCHITECTURES="$2"
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

  if [ -z "${IMAGE_NAME}" ]; then
    printf '[ERROR] --image is required\n' >&2
    usage >&2
    exit 1
  fi

  cd "${REPO_ROOT}"
  ARCHITECTURES="$(normalize_target_arches "${ARCHITECTURES}")"
  log "Building final runtime package images for architectures: ${ARCHITECTURES}"

  local arch
  for arch in ${ARCHITECTURES//,/ }; do
    build_arch_image "${arch}"
  done

  create_manifest
}

main "$@"
