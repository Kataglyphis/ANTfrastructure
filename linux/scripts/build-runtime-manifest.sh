#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_NAME="${IMAGE_NAME:-}"
ARCHITECTURES="${ARCHITECTURES:-${TARGET_ARCHES:-${TARGET_ARCH:-amd64,arm64,riscv64}}}"
ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross}"
ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
TORCH_APP_MODE="${TORCH_APP_MODE:-}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
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
  --target-arches LIST         Comma-separated list (default: amd64,arm64,riscv64)
  --architectures LIST         Alias for --target-arches
  --artifact-image-prefix TAG  Cross tag prefix, or exact artifact image ref in native mode
  --artifact-build-mode MODE   Artifact source mode: cross or native (default: cross)
  --base-dockerfile PATH       Base Dockerfile (default: linux/Dockerfile.base)
  --package-dockerfile PATH    Package Dockerfile (default: linux/Dockerfile.package)
  --wrapper-dockerfile PATH    Final wrapper Dockerfile (default: linux/Dockerfile.torch)
  --torch-app-mode MODE        TORCH_APP_MODE for the wrapper build
                               (default: install in cross mode, all in native mode)
  --fast-ubuntu-mirror         Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL Archive mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                                Optional mirror URL for ubuntu-ports entries
  --push-images                Push per-architecture wrapper images only
  --push-all                   Push ALL images (wrapper + base/package intermediates)
  --push-manifest              Push the final manifest after creating it
  --skip-manifest              Build images only; do not create a manifest locally
  --manifest-only              Create/push the manifest only; skip all image builds
  --push                       Short for --push-images --push-manifest (intermediates stay local)
  -h, --help                   Show this help text

Environment overrides:
  NERDCTL_BIN                  nerdctl executable to use
  BUILDKIT_HOST                Optional BuildKit socket/address passed to nerdctl build
  IMAGE_NAME                   Final manifest image ref, equivalent to --image
  TARGET_ARCHES                Comma-separated architecture list
  TARGET_ARCH                  Alias for TARGET_ARCHES
  ARCHITECTURES                Alias for TARGET_ARCHES
  ARTIFACT_IMAGE_PREFIX        Cross tag prefix, or exact artifact image ref in native mode
  ARTIFACT_BUILD_MODE          Artifact source mode: cross or native
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                               true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT         Temporary directory root for local stage handoff
  PUSH_INTERMEDIATE_IMAGES     1 to also push base/package (default: 0)
  BASE_DOCKERFILE_PATH         Base Dockerfile path
  BASE_PARENT_IMAGE            Optional parent image passed as BASE_IMAGE to the
                               selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH      Package Dockerfile path
  WRAPPER_DOCKERFILE_PATH      Final wrapper Dockerfile path
  TORCH_APP_MODE               TORCH_APP_MODE passed to the wrapper build
  ENABLE_NVIDIA                Optional accelerator flag passed to package/wrapper builds
  ENABLE_AMD                   Optional accelerator flag passed to package/wrapper builds
  ONNX_PACKAGE                 Optional ONNX package override
  PYTORCH_EXTRA                Optional PyTorch extra override
  USE_FAST_UBUNTU_MIRROR       Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL       Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}

create_manifest() {
  local refs=()
  local arch

  for arch in ${ARCHITECTURES//,/ }; do
    refs+=("$(runtime_wrapper_tag "${arch}")")
  done

  "${NERDCTL_BIN}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  run "${NERDCTL_BIN}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_MANIFEST}" -eq 1 ]; then
    run "${NERDCTL_BIN}" manifest push --purge "${IMAGE_NAME}"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    local shared_rc=0
    parse_shared_runtime_args \
      ARCHITECTURES ARTIFACT_IMAGE_PREFIX ARTIFACT_BUILD_MODE \
      BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH \
      TORCH_APP_MODE \
      USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL FAST_UBUNTU_PORTS_MIRROR_URL \
      PUSH_INTERMEDIATE_IMAGES \
      "$1" "$2" || true
    shared_rc=$?
    case ${shared_rc} in
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
      # --push-all is partially handled by the shared parser (which sets
      # PUSH_INTERMEDIATE_IMAGES=1). Re-catch it here to also set the
      # manifest-specific flags.
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

  cd "${REPO_ROOT}"
  ARCHITECTURES="$(normalize_target_arches "${ARCHITECTURES}")"
  RUNTIME_IMAGE_PREFIX="${IMAGE_NAME}"
  runtime_prepare_local_context_chain
  runtime_install_local_context_cleanup_trap
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
