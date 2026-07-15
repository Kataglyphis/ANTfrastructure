#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
runtime_flow_preamble

# Script-specific defaults (override shared where needed)
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

_artifacts_extra_arg() {
  case "$1" in
    --output-root) OUTPUT_ROOT="$2"; _OARG_SHIFT=2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; _OARG_SHIFT=2 ;;
    --push) PUSH_IMAGES=1; _OARG_SHIFT=1 ;;
    --push-all) PUSH_IMAGES=1; PUSH_INTERMEDIATE_IMAGES=1; _OARG_SHIFT=1 ;;
    *) return 1 ;;
  esac
}

main() {
  run_runtime_arg_loop usage _artifacts_extra_arg "$@"

  # Post-parse setup (replaces runtime_flow_export_setup)
  export DRY_RUN
  runtime_post_parse_setup TARGET_ARCHES "${IMAGE_PREFIX}"

  log "Building and exporting ${ARTIFACT_BUILD_MODE} runtime artifacts for target arches: ${TARGET_ARCHES}"

  run_parallel_arch_loop _build_one_artifact "$(arch_loop_flag_prefix runtime-artifact-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
}

main "$@"
