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
TARGET_ARCHES="$(resolve_arch_list)"
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
  --repair                     Alias for --manifest-only (repair manifest from existing per-arch images)
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

Environment overrides:
  IMAGE_NAME                   Final manifest image ref, equivalent to --image
EOF
  runtime_shared_usage_env_overrides
}

create_manifest() {
  local refs=()
  local arch

  for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
    refs+=("$(runtime_wrapper_tag "${arch}")")
  done

  if is_dry_run; then
    log "[DRY RUN] would create manifest ${IMAGE_NAME} from refs: ${refs[*]}"
    return 0
  fi

  if "${NERDCTL_BIN:-nerdctl}" manifest inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    "${NERDCTL_BIN:-nerdctl}" manifest rm "${IMAGE_NAME}" >/dev/null 2>&1 || true
  fi
  run "${NERDCTL_BIN:-nerdctl}" manifest create "${IMAGE_NAME}" "${refs[@]}"

  if [ "${PUSH_MANIFEST}" -eq 1 ]; then
    run "${NERDCTL_BIN:-nerdctl}" manifest push --purge "${IMAGE_NAME}"
  fi
}

main() {
  while [ $# -gt 0 ]; do
    consume_shared_arg usage \
      parse_shared_runtime_args \
      TARGET_ARCHES ARTIFACT_IMAGE_PREFIX ARTIFACT_BUILD_MODE \
      BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH \
      TORCH_APP_MODE \
      USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL FAST_UBUNTU_PORTS_MIRROR_URL \
      PUSH_INTERMEDIATE_IMAGES \
      "$1" "${2:-}" || break
    consume_dp_shift && { shift "${_DP_SHIFT}"; continue; }
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
      --manifest-only|--repair)
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
        warn "Unknown option: $1"; usage >&2; exit 1
        ;;
    esac
  done

  if [ -z "${IMAGE_NAME}" ]; then
    err "--image is required"
  fi

  # Post-parse setup (replaces runtime_flow_export_setup)
  export DRY_RUN
  runtime_post_parse_setup TARGET_ARCHES "${IMAGE_NAME}"

  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    log "Building ${ARTIFACT_BUILD_MODE} runtime package flow for architectures: ${TARGET_ARCHES}"
  else
    log "Creating manifest only for architectures: ${TARGET_ARCHES}"
  fi

  local arch
  if [ "${BUILD_IMAGES}" -eq 1 ]; then
    run_parallel_arch_loop runtime_build_chain "/tmp/runtime-arch-loop-flags" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
  fi

  if [ "${CREATE_MANIFEST}" -eq 1 ]; then
    create_manifest
  fi
}

main "$@"
