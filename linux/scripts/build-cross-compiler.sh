#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
BASE_REMOTE_TAG="${BASE_REMOTE_TAG:-${IMAGE_REGISTRY_PREFIX}:base}"
BASE_LOCAL_TAG="${BASE_LOCAL_TAG:-${IMAGE_REGISTRY_PREFIX}:base}"
COMPILER_LOCAL_TAG="${COMPILER_LOCAL_TAG:-${IMAGE_REGISTRY_PREFIX}:compiler-cross-amd64}"
COMPILER_REMOTE_TAG="${COMPILER_REMOTE_TAG:-${IMAGE_REGISTRY_PREFIX}:compiler-cross-amd64}"
CROSS_TARGETS="${CROSS_TARGETS:-amd64,arm64,riscv64}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"

REBUILD_BASE=0
PUSH_IMAGE=0

usage() {
  cat <<'EOF'
Usage: build-cross-compiler.sh [options]

Builds an amd64-hosted cross-compiler image with nerdctl.
The image stays local unless --push is requested.
If the remote base image is unavailable, the script builds a local amd64 base
image first and then uses it for the compiler build.

Options:
  --cross-targets LIST   Comma-separated target list (default: amd64,arm64,riscv64)
  --fast-ubuntu-mirror   Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL
                          Mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                         Optional mirror URL for ubuntu-ports entries
  --rebuild-base         Always rebuild the local base image instead of trying pull first
  --push                 Tag and push the finished compiler image to GHCR
  -h, --help             Show this help text

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  BASE_REMOTE_TAG        Remote base tag to try before local bootstrap
  BASE_LOCAL_TAG         Local base tag (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger:base)
  COMPILER_LOCAL_TAG     Local compiler tag
  COMPILER_REMOTE_TAG    Remote compiler tag used with --push
  USE_FAST_UBUNTU_MIRROR Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}

ensure_base_image() {
  local -a mirror_build_args=()

  append_mirror_build_args mirror_build_args "${USE_FAST_UBUNTU_MIRROR}" "${FAST_UBUNTU_MIRROR_URL}" "${FAST_UBUNTU_PORTS_MIRROR_URL}"

  if [ "${REBUILD_BASE}" -eq 0 ] && image_exists "${NERDCTL_BIN}" "${BASE_LOCAL_TAG}"; then
    log "Using existing local base image: ${BASE_LOCAL_TAG}"
    return 0
  fi

  if [ "${REBUILD_BASE}" -eq 0 ]; then
    log "Trying to pull remote base image: ${BASE_REMOTE_TAG}"
    if pull_platform_image "${NERDCTL_BIN}" linux/amd64 "${BASE_REMOTE_TAG}"; then
      if [ "${BASE_REMOTE_TAG}" != "${BASE_LOCAL_TAG}" ]; then
        run "${NERDCTL_BIN}" tag "${BASE_REMOTE_TAG}" "${BASE_LOCAL_TAG}"
      fi
      return 0
    fi
    log "Remote base image unavailable; bootstrapping ${BASE_LOCAL_TAG} locally"
  else
    log "Forced local rebuild of ${BASE_LOCAL_TAG}"
  fi

  run_nerdctl_build "${NERDCTL_BIN}" \
    --pull=false \
    --platform linux/amd64 \
    -t "${BASE_LOCAL_TAG}" \
    -f linux/Dockerfile.base \
    "${mirror_build_args[@]}" \
    .
}

build_cross_compiler() {
  local -a mirror_build_args=()

  append_mirror_build_args mirror_build_args "${USE_FAST_UBUNTU_MIRROR}" "${FAST_UBUNTU_MIRROR_URL}" "${FAST_UBUNTU_PORTS_MIRROR_URL}"

  run_nerdctl_build "${NERDCTL_BIN}" \
    --pull=false \
    --platform linux/amd64 \
    -t "${COMPILER_LOCAL_TAG}" \
    -f linux/Dockerfile.toolchain \
    --build-arg BASE_IMAGE="${BASE_LOCAL_TAG}" \
    --build-arg BUILD_MODE=cross \
    --build-arg CROSS_TARGETS="${CROSS_TARGETS}" \
    "${mirror_build_args[@]}" \
    .
}

push_cross_compiler() {
  if [ "${COMPILER_LOCAL_TAG}" != "${COMPILER_REMOTE_TAG}" ]; then
    run "${NERDCTL_BIN}" tag "${COMPILER_LOCAL_TAG}" "${COMPILER_REMOTE_TAG}"
  fi
  run "${NERDCTL_BIN}" push "${COMPILER_REMOTE_TAG}"
}

main() {
  while [ $# -gt 0 ]; do
    local oa_rc=0
    parse_shared_orchestrator_args \
      CROSS_TARGETS USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IGNORED_REPO IGNORED_VULKAN PUSH_IMAGE \
      "$1" "$2" || true
    oa_rc=$?
    case ${oa_rc} in
      2) shift 2; continue ;;
      1) shift 1; continue ;;
      255) usage; exit 0 ;;
    esac
    case "$1" in
      --cross-targets)
        CROSS_TARGETS="$2"
        shift 2
        ;;
      --rebuild-base)
        REBUILD_BASE=1
        shift
        ;;
      *)
        printf '[ERROR] Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  cd "${REPO_ROOT}"

  ensure_base_image
  build_cross_compiler

  if [ "${PUSH_IMAGE}" -eq 1 ]; then
    push_cross_compiler
  fi
}

main "$@"
