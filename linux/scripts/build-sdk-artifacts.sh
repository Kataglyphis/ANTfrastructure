#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

canonical_target_arch() {
  case "$1" in
    amd64|x86_64) printf '%s' "amd64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    riscv64|riscv|rv64*) printf '%s' "riscv64" ;;
    *) return 1 ;;
  esac
}

normalize_target_arches() {
  local raw_arches="$1"
  local raw_arch normalized_arch
  local -a normalized_arches=()

  for raw_arch in ${raw_arches//,/ }; do
    normalized_arch="$(canonical_target_arch "${raw_arch}")" || {
      printf '[ERROR] Unsupported target architecture: %s\n' "${raw_arch}" >&2
      exit 1
    }
    normalized_arches+=("${normalized_arch}")
  done

  if [ "${#normalized_arches[@]}" -eq 0 ]; then
    printf '[ERROR] At least one target architecture is required\n' >&2
    exit 1
  fi

  printf '%s' "${normalized_arches[*]}" | tr ' ' ','
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
    export_rootfs "${arch}" "${tag}"
    if [ "${PUSH_IMAGES}" -eq 1 ]; then
      push_sdk_image "${tag}"
    fi
  done
}

main "$@"
