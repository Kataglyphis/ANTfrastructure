#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"
# shellcheck disable=SC1091
source "${_ARTIFACT_COMMON_DIR}/runtime-flow-common.sh"
init_runtime_flow_defaults

# Script-specific defaults (override shared where needed)
TARGET_ARCHES="$(resolve_arch_list)"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/out/linux-runtime}"
IMAGE_PREFIX="${IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:latest-cross}"

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
  --dry-run                    Print build commands without executing them
  --parallel-archs              Build per-architecture images in parallel
  --max-parallel-archs N        Max concurrent arch builds (default: 4)
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
EOF
  runtime_shared_usage_env_overrides
}

_build_one_artifact() {
  local _arch="$1"
  local tag
  if runtime_use_local_stage_context_outputs; then
    runtime_build_chain "${_arch}" "${OUTPUT_ROOT}/${_arch}/rootfs"
    runtime_write_artifact_metadata "${_arch}" "${OUTPUT_ROOT}/${_arch}"
  else
    runtime_build_chain "${_arch}"
    tag="$(runtime_wrapper_tag "${_arch}")"
    export_rootfs_from_image "${NERDCTL_BIN}" "${tag}" "${OUTPUT_ROOT}/${_arch}" \
      "TARGET_ARCH=${_arch}" \
      "SOURCE_IMAGE=${tag}" \
      "PACKAGE_IMAGE=$(runtime_package_tag "${_arch}")" \
      "BASE_IMAGE=$(runtime_base_tag "${_arch}")" \
      "ARTIFACT_IMAGE=$(runtime_artifact_image_ref "${_arch}")"
  fi
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
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --parallel-archs)
        PARALLEL_ARCHS=1
        shift
        ;;
      --max-parallel-archs)
        MAX_PARALLEL_ARCHS="$2"
        shift 2
        ;; 
      *)
        err "Unknown option: $1"
        ;;
    esac
  done

  runtime_flow_export_setup TARGET_ARCHES "${IMAGE_PREFIX}"

  log "Building and exporting ${ARTIFACT_BUILD_MODE} runtime artifacts for target arches: ${TARGET_ARCHES}"

  run_parallel_arch_loop _build_one_artifact "/tmp/runtime-artifact-loop-flags" "${MAX_PARALLEL_ARCHS}" ${TARGET_ARCHES//,/ }
}

main "$@"
