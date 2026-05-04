#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
BASE_REMOTE_TAG="${BASE_REMOTE_TAG:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps}"
BASE_LOCAL_TAG="${BASE_LOCAL_TAG:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps}"
COMPILER_LOCAL_TAG="${COMPILER_LOCAL_TAG:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64}"
COMPILER_REMOTE_TAG="${COMPILER_REMOTE_TAG:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler-cross-amd64}"
CROSS_TARGETS="${CROSS_TARGETS:-arm64,riscv64}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-http://de.archive.ubuntu.com/ubuntu/}"

REBUILD_BASE=0
PUSH_IMAGE=0

usage() {
  cat <<'EOF'
Usage: build-cross-compiler.sh [options]

Builds an amd64-hosted cross-compiler image with nerdctl.
If the remote os-deps image is unavailable, the script builds a local amd64 base
image first and then uses it for the compiler build.

Options:
  --cross-targets LIST   Comma-separated target list (default: arm64,riscv64)
  --fast-ubuntu-mirror   Replace security.ubuntu.com during Docker builds
  --fast-ubuntu-mirror-url URL
                         Mirror URL to use with --fast-ubuntu-mirror
  --rebuild-base         Always rebuild local os-deps instead of trying pull first
  --push                 Tag and push the finished compiler image to GHCR
  -h, --help             Show this help text

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  BASE_REMOTE_TAG        Remote base tag to try before local bootstrap
  BASE_LOCAL_TAG         Local os-deps tag (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps)
  COMPILER_LOCAL_TAG     Local compiler tag
  COMPILER_REMOTE_TAG    Remote compiler tag used with --push
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

ensure_base_image() {
  local -a mirror_build_args=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${USE_FAST_UBUNTU_MIRROR}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${FAST_UBUNTU_MIRROR_URL}"
  )

  if [ "${REBUILD_BASE}" -eq 0 ] && image_exists "${BASE_LOCAL_TAG}"; then
    log "Using existing local base image: ${BASE_LOCAL_TAG}"
    return 0
  fi

  if [ "${REBUILD_BASE}" -eq 0 ]; then
    log "Trying to pull remote base image: ${BASE_REMOTE_TAG}"
    if run "${NERDCTL_BIN}" pull --platform linux/amd64 "${BASE_REMOTE_TAG}"; then
      if [ "${BASE_REMOTE_TAG}" != "${BASE_LOCAL_TAG}" ]; then
        run "${NERDCTL_BIN}" tag "${BASE_REMOTE_TAG}" "${BASE_LOCAL_TAG}"
      fi
      return 0
    fi
    log "Remote base image unavailable; bootstrapping ${BASE_LOCAL_TAG} locally"
  else
    log "Forced local rebuild of ${BASE_LOCAL_TAG}"
  fi

  run "${NERDCTL_BIN}" build \
    --platform linux/amd64 \
    -t "${BASE_LOCAL_TAG}" \
    --output "type=image,name=${BASE_LOCAL_TAG},push=false" \
    -f linux/Dockerfile.os-deps \
    "${mirror_build_args[@]}" \
    .
}

build_cross_compiler() {
  local -a mirror_build_args=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${USE_FAST_UBUNTU_MIRROR}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${FAST_UBUNTU_MIRROR_URL}"
  )

  run "${NERDCTL_BIN}" build \
    --platform linux/amd64 \
    -t "${COMPILER_LOCAL_TAG}" \
    --output "type=image,name=${COMPILER_LOCAL_TAG},push=false" \
    -f linux/Dockerfile.compiler \
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
    case "$1" in
      --cross-targets)
        CROSS_TARGETS="$2"
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
      --rebuild-base)
        REBUILD_BASE=1
        shift
        ;;
      --push)
        PUSH_IMAGE=1
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

  ensure_base_image
  build_cross_compiler

  if [ "${PUSH_IMAGE}" -eq 1 ]; then
    push_cross_compiler
  fi
}

main "$@"
