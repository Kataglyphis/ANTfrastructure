#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
BASE_REMOTE_TAG="${BASE_REMOTE_TAG:-${IMAGE_REPO}:base}"
BASE_LOCAL_TAG="${BASE_LOCAL_TAG:-${IMAGE_REPO}:base}"
COMPILER_LOCAL_TAG="${COMPILER_LOCAL_TAG:-${IMAGE_REPO}:cross-compiler-amd64}"
COMPILER_REMOTE_TAG="${COMPILER_REMOTE_TAG:-${IMAGE_REPO}:cross-compiler-amd64}"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
init_mirror_defaults

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
  --image-repo REPO      Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
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
  local -a build_args=()
  append_common_build_args build_args
  ensure_local_image "${BASE_LOCAL_TAG}" linux/Dockerfile.base "${BASE_REMOTE_TAG}" build_args
}

build_cross_compiler() {
  local -a build_args=()
  append_common_build_args build_args

  run_nerdctl_build "${NERDCTL_BIN}" \
    --pull=false \
    --platform linux/amd64 \
    -t "${COMPILER_LOCAL_TAG}" \
    -f linux/Dockerfile.toolchain \
    --build-arg BASE_IMAGE="${BASE_LOCAL_TAG}" \
    --build-arg BUILD_MODE=cross \
    --build-arg CROSS_TARGETS="${CROSS_TARGETS}" \
    "${build_args[@]}" \
    .
}

push_cross_compiler() {
  if [ "${COMPILER_LOCAL_TAG}" != "${COMPILER_REMOTE_TAG}" ]; then
    run "${NERDCTL_BIN}" tag "${COMPILER_LOCAL_TAG}" "${COMPILER_REMOTE_TAG}"
  fi
  retry 3 10 "pushing compiler image" run "${NERDCTL_BIN}" push "${COMPILER_REMOTE_TAG}"
}

main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    dispatch_parsed_args parse_shared_orchestrator_args \
      CROSS_TARGETS USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO _ignored_vulkan PUSH_IMAGE \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
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
        warn "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  # Refresh tag defaults now that IMAGE_REPO may have been changed via --image-repo.
  BASE_REMOTE_TAG="${BASE_REMOTE_TAG:-${IMAGE_REPO}:base}"
  BASE_LOCAL_TAG="${BASE_LOCAL_TAG:-${IMAGE_REPO}:base}"
  COMPILER_LOCAL_TAG="${COMPILER_LOCAL_TAG:-${IMAGE_REPO}:cross-compiler-amd64}"
  COMPILER_REMOTE_TAG="${COMPILER_REMOTE_TAG:-${IMAGE_REPO}:cross-compiler-amd64}"

  cd "${REPO_ROOT}"

  ensure_base_image
  build_cross_compiler

  if [ "${PUSH_IMAGE}" -eq 1 ]; then
    push_cross_compiler
  fi
}

main "$@"
