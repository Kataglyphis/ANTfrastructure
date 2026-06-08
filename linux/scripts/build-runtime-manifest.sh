#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/runtime-cli.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_NAME="${IMAGE_NAME:-}"
ARCHITECTURES="${ARCHITECTURES:-${TARGET_ARCHES:-${TARGET_ARCH:-${CROSS_DEFAULT_ARCHES}}}}"
ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:android-cross}"
ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
TORCH_APP_MODE="${TORCH_APP_MODE:-}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT}}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"

PUSH_IMAGES=0
PUSH_MANIFEST=0
PUSH_INTERMEDIATE_IMAGES=0
BUILD_IMAGES=1
CREATE_MANIFEST=1

usage() {
  cat <<'EOF'
Usage: build-runtime-manifest.sh --image IMAGE [options]

Builds the documented cross publish flow end-to-end:
1. clean per-architecture base images
2. package images that layer target-built payload from android-cross-${arch}
3. final wrapper images (includes torch venv + app + runtime scripts)
4. one multi-architecture manifest

Options:
  --image IMAGE                Final manifest image ref to build (required)
  --push-images                Push per-architecture wrapper images only
  --push-all                   Push ALL images (wrapper + base/package intermediates)
  --push-manifest              Push the final manifest after creating it
  --skip-manifest              Build images only; do not create a manifest locally
  --manifest-only              Create/push the manifest only; skip all image builds
  --push                       Short for --push-images --push-manifest (intermediates stay local)
  -h, --help                   Show this help text
EOF
  runtime_cli_usage_common
  echo
  cat <<'EOF'
Environment overrides:
  IMAGE_NAME                   Final manifest image ref, equivalent to --image
EOF
  runtime_cli_env_common
}

create_manifest() {
  local refs=()
  local arch

  for arch in ${ARCHITECTURES//,/ }; do
    refs+=("$(runtime_wrapper_tag "${arch}")")
  done

  if "${NERDCTL_BIN}" manifest inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    "${NERDCTL_BIN}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  fi
  run "${NERDCTL_BIN}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_MANIFEST}" -eq 1 ]; then
    run "${NERDCTL_BIN}" manifest push --purge "${IMAGE_NAME}"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    runtime_dispatch_shared_args \
      ARCHITECTURES ARTIFACT_IMAGE_PREFIX ARTIFACT_BUILD_MODE \
      BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH \
      TORCH_APP_MODE \
      USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL FAST_UBUNTU_PORTS_MIRROR_URL \
      PUSH_INTERMEDIATE_IMAGES \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      2) shift 2; continue ;;
      1) shift 1; continue ;;
      255) usage; exit 0 ;;
    esac
    case "$1" in
      --image)
        IMAGE_NAME="$2"
        shift 2
        ;;
      --push-images)
        PUSH_IMAGES=1
        shift
        ;;
      --push-manifest)
        PUSH_MANIFEST=1
        shift
        ;;
      --skip-manifest)
        CREATE_MANIFEST=0
        shift
        ;;
      --manifest-only)
        BUILD_IMAGES=0
        shift
        ;;
      --push)
        PUSH_IMAGES=1
        PUSH_MANIFEST=1
        shift
        ;;
      --push-all)
        PUSH_IMAGES=1
        PUSH_MANIFEST=1
        PUSH_INTERMEDIATE_IMAGES=1
        shift
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

  runtime_post_parse_setup ARCHITECTURES "${IMAGE_NAME}"

  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    log "Building ${ARTIFACT_BUILD_MODE} runtime package flow for architectures: ${ARCHITECTURES}"
  else
    log "Creating manifest only for architectures: ${ARCHITECTURES}"
  fi

  local arch
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    for arch in ${ARCHITECTURES//,/ }; do
      runtime_build_chain "${arch}"
    done
  fi

  if [ "${CREATE_MANIFEST}" -eq 1 ]; then
    create_manifest
  fi
}

main "$@"
