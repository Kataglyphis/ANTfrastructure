#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-runtime}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-amd64,arm64,riscv64}}}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross}"
ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-cross}"
ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
TORCH_DOCKERFILE_PATH="${TORCH_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile}"
TORCH_APP_MODE="${TORCH_APP_MODE:-}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
PUSH_IMAGES=0
PUSH_INTERMEDIATE_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-runtime-artifacts.sh [options]

Builds the same cross runtime flow used for publishable images:
1. clean per-architecture base images
2. package images that layer target-built payload from android-cross-${arch}
3. torch images from linux/Dockerfile.torch
4. final wrapper images from linux/Dockerfile
5. exports the final wrapper rootfs for each architecture

Options:
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
  --output-root DIR             Export directory root (default: out/linux-runtime)
  --image-prefix TAG            Prefix for built wrapper image tags
  --artifact-image-prefix TAG   Cross tag prefix, or exact artifact image ref in native mode
  --artifact-build-mode MODE    Artifact source mode: cross or native (default: cross)
  --base-dockerfile PATH        Base Dockerfile (default: linux/Dockerfile.base)
  --package-dockerfile PATH     Package Dockerfile (default: linux/Dockerfile.package)
  --torch-dockerfile PATH       Torch Dockerfile (default: linux/Dockerfile.torch)
  --wrapper-dockerfile PATH     Final wrapper Dockerfile (default: linux/Dockerfile)
  --torch-app-mode MODE         TORCH_APP_MODE for linux/Dockerfile.torch
                                (default: install in cross mode, all in native mode)
  --fast-ubuntu-mirror          Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL  Archive mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                                 Optional mirror URL for ubuntu-ports entries
  --push                        Push wrapper images after export (intermediates stay local)
  --push-all                    Push ALL intermediate images too (base/package/torch)
  -h, --help                    Show this help text

Environment overrides:
  NERDCTL_BIN                   nerdctl executable to use
  BUILDKIT_HOST                 Optional BuildKit socket/address passed to nerdctl build
  TARGET_ARCHES                 Comma-separated target list
  TARGET_ARCH                   Alias for TARGET_ARCHES
  ARCHITECTURES                 Alias for TARGET_ARCHES
  OUTPUT_ROOT                   Root directory for exported rootfs artifacts
  IMAGE_PREFIX                  Prefix for wrapper image tags
  ARTIFACT_IMAGE_PREFIX         Cross tag prefix, or exact artifact image ref in native mode
  ARTIFACT_BUILD_MODE           Artifact source mode: cross or native
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                                true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT          Temporary directory root for local stage handoff
  PUSH_INTERMEDIATE_IMAGES      1 to also push base/package/torch (default: 0)
  BASE_DOCKERFILE_PATH          Base Dockerfile path
  BASE_PARENT_IMAGE             Optional parent image passed as BASE_IMAGE to the
                                selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH       Package Dockerfile path
  TORCH_DOCKERFILE_PATH         Torch Dockerfile path
  WRAPPER_DOCKERFILE_PATH       Final wrapper Dockerfile path
  TORCH_APP_MODE                TORCH_APP_MODE passed to linux/Dockerfile.torch
  ENABLE_NVIDIA                 Optional accelerator flag passed to package/torch/
                                wrapper builds
  ENABLE_AMD                    Optional accelerator flag passed to package/torch/
                                wrapper builds
  ONNX_PACKAGE                  Optional torch ONNX package override
  PYTORCH_EXTRA                 Optional torch PyTorch extra override
  USE_FAST_UBUNTU_MIRROR        Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL        Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL  Optional ports mirror URL used when the fast mirror is enabled
EOF
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
      --artifact-image-prefix)
        ARTIFACT_IMAGE_PREFIX="$2"
        shift 2
        ;;
      --artifact-build-mode)
        ARTIFACT_BUILD_MODE="$2"
        shift 2
        ;;
      --base-dockerfile)
        BASE_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --package-dockerfile)
        PACKAGE_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --torch-dockerfile)
        TORCH_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --wrapper-dockerfile)
        WRAPPER_DOCKERFILE_PATH="$2"
        shift 2
        ;;
      --torch-app-mode)
        TORCH_APP_MODE="$2"
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
      --push-all)
        PUSH_IMAGES=1
        PUSH_INTERMEDIATE_IMAGES=1
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
  RUNTIME_IMAGE_PREFIX="${IMAGE_PREFIX}"
  runtime_prepare_local_context_chain
  runtime_install_local_context_cleanup_trap
  log "Building and exporting ${ARTIFACT_BUILD_MODE} runtime artifacts for target arches: ${TARGET_ARCHES}"

  local arch
  local tag
  for arch in ${TARGET_ARCHES//,/ }; do
    if runtime_use_local_stage_context_outputs; then
      runtime_build_chain "${arch}" "${OUTPUT_ROOT}/${arch}/rootfs"
      runtime_write_artifact_metadata "${arch}" "${OUTPUT_ROOT}/${arch}"
    else
      runtime_build_chain "${arch}"
      tag="$(runtime_wrapper_tag "${arch}")"
      export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${arch}" \
        "TARGET_ARCH=${arch}" \
        "SOURCE_IMAGE=${tag}" \
        "TORCH_IMAGE=$(runtime_torch_tag "${arch}")" \
        "PACKAGE_IMAGE=$(runtime_package_tag "${arch}")" \
        "BASE_IMAGE=$(runtime_base_tag "${arch}")" \
        "ARTIFACT_IMAGE=$(runtime_artifact_image_ref "${arch}")"
    fi
  done
}

main "$@"
