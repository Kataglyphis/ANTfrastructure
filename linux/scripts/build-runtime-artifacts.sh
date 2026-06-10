#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-runtime}"
TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-${CROSS_DEFAULT_ARCHES}}}}"
IMAGE_PREFIX="${IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:latest-cross}"
ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:cross-android}"
ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
TORCH_APP_MODE="${TORCH_APP_MODE:-}"
USE_FAST_UBUNTU_MIRROR="${USE_FAST_UBUNTU_MIRROR:-false}"
FAST_UBUNTU_MIRROR_URL="${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT}}"
FAST_UBUNTU_PORTS_MIRROR_URL="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
PUSH_IMAGES=0
PUSH_INTERMEDIATE_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-runtime-artifacts.sh [options]

Builds the same cross runtime flow used for publishable images:
1. clean per-architecture base images
2. package images that layer target-built payload from cross-android-${arch}
3. final wrapper images (includes torch venv + app + runtime scripts) from linux/Dockerfile.torch
4. exports the final wrapper rootfs for each architecture

Options:
  --output-root DIR             Export directory root (default: out/linux-runtime)
  --image-prefix TAG            Prefix for built wrapper image tags
  --push                        Push wrapper images after export (intermediates stay local)
  --push-all                    Push ALL intermediate images too (base/package)
  -h, --help                    Show this help text
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
  --artifact-image-prefix TAG   Cross tag prefix, or exact artifact image ref in native mode
  --artifact-build-mode MODE    Artifact source mode: cross or native (default: cross)
  --base-dockerfile PATH        Base Dockerfile (default: linux/Dockerfile.base)
  --package-dockerfile PATH     Package Dockerfile (default: linux/Dockerfile.package)
  --torch-dockerfile PATH       Alias for --wrapper-dockerfile (deprecated)
  --wrapper-dockerfile PATH     Final wrapper Dockerfile (default: linux/Dockerfile.torch)
  --torch-app-mode MODE         TORCH_APP_MODE for linux/Dockerfile.torch
  --fast-ubuntu-mirror          Replace Ubuntu archive/security/ports mirrors during Docker builds
  --fast-ubuntu-mirror-url URL  Archive mirror URL to use with --fast-ubuntu-mirror
  --fast-ubuntu-ports-mirror-url URL
                                 Optional mirror URL for ubuntu-ports entries
EOF
  cat <<'EOF'
Environment overrides:
  OUTPUT_ROOT                   Root directory for exported rootfs artifacts
  IMAGE_PREFIX                  Prefix for wrapper image tags
  NERDCTL_BIN                  nerdctl executable to use
  BUILDKIT_HOST                Optional BuildKit socket/address passed to nerdctl build
  TARGET_ARCHES                Comma-separated architecture list
  TARGET_ARCH                  Alias for TARGET_ARCHES
  ARCHITECTURES                Alias for TARGET_ARCHES
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                                true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT         Temporary directory root for local stage handoff
  BASE_DOCKERFILE_PATH         Base Dockerfile path
  BASE_PARENT_IMAGE            Optional parent image passed as BASE_IMAGE to the
                                selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH      Package Dockerfile path
  TORCH_DOCKERFILE_PATH        Torch Dockerfile path
  WRAPPER_DOCKERFILE_PATH      Final wrapper Dockerfile path
  TORCH_APP_MODE               TORCH_APP_MODE passed to linux/Dockerfile.torch
  ENABLE_NVIDIA                Optional accelerator flag passed to package/torch/wrapper builds
  ENABLE_AMD                   Optional accelerator flag passed to package/torch/wrapper builds
  ONNX_PACKAGE                 Optional torch ONNX package override
  PYTORCH_EXTRA                Optional torch PyTorch extra override
  USE_FAST_UBUNTU_MIRROR       Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL       Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}

main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    runtime_dispatch_shared_args \
      TARGET_ARCHES ARTIFACT_IMAGE_PREFIX ARTIFACT_BUILD_MODE \
      BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH \
      TORCH_APP_MODE \
      USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL FAST_UBUNTU_PORTS_MIRROR_URL \
      PUSH_INTERMEDIATE_IMAGES \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      --output-root)
        OUTPUT_ROOT="$2"
        shift 2
        ;;
      --image-prefix)
        IMAGE_PREFIX="$2"
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
      *)
        printf '[ERROR] Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  runtime_post_parse_setup TARGET_ARCHES

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
        "PACKAGE_IMAGE=$(runtime_package_tag "${arch}")" \
        "BASE_IMAGE=$(runtime_base_tag "${arch}")" \
        "ARTIFACT_IMAGE=$(runtime_artifact_image_ref "${arch}")"
    fi
  done
}

main "$@"
