#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"
# shellcheck disable=SC1091
source "${_ARTIFACT_COMMON_DIR}/runtime-flow-common.sh"
init_runtime_flow_defaults

# Script-specific defaults (override shared where needed)
IMAGE_NAME="${IMAGE_NAME:-}"
ARCHITECTURES="${ARCHITECTURES:-${TARGET_ARCHES:-${TARGET_ARCH:-${CROSS_DEFAULT_ARCHES}}}}"
PUSH_MANIFEST=0
BUILD_IMAGES=1
CREATE_MANIFEST=1

usage() {
  cat <<'EOF'
Usage: build-runtime-manifest.sh --image IMAGE [options]

Builds the documented cross publish flow end-to-end:
1. clean per-architecture base images
2. package images that layer target-built payload from cross-android-${arch}
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
  --dry-run                    Print build commands without executing them
  --parallel-archs              Build per-architecture images in parallel
  --max-parallel-archs N        Max concurrent arch builds (default: 4)
  -h, --help                   Show this help text
  --target-arches LIST          Comma-separated target list (default: amd64,arm64,riscv64)
  --architectures LIST          Alias for --target-arches
  --image-prefix TAG            Prefix for built wrapper image tags
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
  IMAGE_NAME                   Final manifest image ref, equivalent to --image
EOF
  runtime_shared_usage_env_overrides
}

create_manifest() {
  local refs=()
  local arch

  for arch in ${ARCHITECTURES//,/ }; do
    refs+=("$(runtime_wrapper_tag "${arch}")")
  done

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[DRY RUN] would create manifest ${IMAGE_NAME} from refs: ${refs[*]}"
    return 0
  fi

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
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
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

  if [ -z "${IMAGE_NAME}" ]; then
    err "--image is required"
  fi

  runtime_flow_export_setup ARCHITECTURES "${IMAGE_NAME}"

  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    log "Building ${ARTIFACT_BUILD_MODE} runtime package flow for architectures: ${ARCHITECTURES}"
  else
    log "Creating manifest only for architectures: ${ARCHITECTURES}"
  fi

  local arch
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    run_parallel_arch_loop runtime_build_chain "/tmp/runtime-arch-loop-flags" "${MAX_PARALLEL_ARCHS}" ${ARCHITECTURES//,/ }
  fi

  if [ "${CREATE_MANIFEST}" -eq 1 ]; then
    create_manifest
  fi
}

main "$@"
