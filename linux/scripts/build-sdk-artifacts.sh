#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
COMPILER_IMAGE="${COMPILER_IMAGE:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-sdk}"
ARCHITECTURES="${ARCHITECTURES:-arm64,riscv64}"
VULKAN_VERSION="${VULKAN_VERSION:-1.4.341.1}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk-artifact}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-http://de.archive.ubuntu.com/ubuntu/}"

usage() {
  cat <<'EOF'
Usage: build-sdk-artifacts.sh [options]

Builds target-specific SDK artifact images on an amd64 host and exports their
root filesystems into per-architecture output directories.

Expected result:
  out/linux-sdk/arm64/rootfs/
  out/linux-sdk/riscv64/rootfs/

Options:
  --architectures LIST   Comma-separated list (default: arm64,riscv64)
  --output-root DIR      Export directory root (default: out/linux-sdk)
  --compiler-image TAG   Cross compiler image to use as base
  --fast-ubuntu-mirror   Replace security.ubuntu.com during Docker builds
  --fast-ubuntu-mirror-url URL
                         Mirror URL to use with --fast-ubuntu-mirror
  --vulkan-version VER   Vulkan SDK version to build
  -h, --help             Show this help text

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  ARCHITECTURES          Comma-separated architecture list
  OUTPUT_ROOT            Root directory for exported rootfs artifacts
  COMPILER_IMAGE         Cross compiler image to use as base
  VULKAN_VERSION         Vulkan SDK version
  IMAGE_PREFIX           Prefix for local artifact image tags
  USE_FAST_UBUNTU_MIRROR Set to true to replace archive/security Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when the fast mirror is enabled
EOF
}

log() {
  printf '[INFO] %s\n' "$*"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
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

  run "${NERDCTL_BIN}" build \
    --platform linux/amd64 \
    -t "${tag}" \
    --output "type=image,name=${tag},push=false" \
    -f linux/Dockerfile.sdk-artifact \
    --build-arg BASE_IMAGE="${COMPILER_IMAGE}" \
    --build-arg BUILD_MODE=cross \
    --build-arg TARGET_ARCH="${arch}" \
    --build-arg VULKAN_VERSION="${VULKAN_VERSION}" \
    "${mirror_build_args[@]}" \
    .
}

export_rootfs() {
  local arch="$1"
  local tag="$2"
  local artifact_dir="${OUTPUT_ROOT}/${arch}"
  local rootfs_dir="${artifact_dir}/rootfs"
  local cid=""

  rm -rf "${artifact_dir}"
  mkdir -p "${rootfs_dir}"

  cid="$(${NERDCTL_BIN} create "${tag}" /bin/true)"
  cleanup_container() {
    if [ -n "${cid}" ]; then
      "${NERDCTL_BIN}" rm -f "${cid}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_container RETURN

  "${NERDCTL_BIN}" export "${cid}" | tar -xpf - -C "${rootfs_dir}"

  cat > "${artifact_dir}/artifact.env" <<EOF
TARGET_ARCH=${arch}
SOURCE_IMAGE=${tag}
VULKAN_VERSION=${VULKAN_VERSION}
EOF

  cleanup_container
  trap - RETURN
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --architectures)
        ARCHITECTURES="$2"
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
      --vulkan-version)
        VULKAN_VERSION="$2"
        shift 2
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
  ensure_compiler_image

  local arch
  local tag
  for arch in ${ARCHITECTURES//,/ }; do
    tag="${IMAGE_PREFIX}-${arch}"
    build_sdk_image "${arch}" "${tag}"
    export_rootfs "${arch}" "${tag}"
  done
}

main "$@"
