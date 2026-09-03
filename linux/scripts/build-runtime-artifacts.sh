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
  --push                        Push wrapper images after export (intermediates stay local)
  --push-all                    Push ALL intermediate images too (base/package)
EOF
  runtime_shared_usage_options
  cat <<'EOF'
  -h, --help                    Show this help text

Environment overrides:
  OUTPUT_ROOT                   Root directory for exported rootfs artifacts
  IMAGE_PREFIX                  Prefix for wrapper image tags
EOF
  runtime_shared_usage_env_overrides
}

_build_one_artifact() {
  local _arch="$1"
  local tag
  # `|| return 1` on every chain call is load-bearing: run_parallel_arch_loop
  # calls this via `if ! fn`, which suppresses errexit for the whole call tree
  # — without the guards, a failed build falls through to the export below,
  # which exports the STALE tag left by a previous run and reports green.
  if runtime_use_local_stage_context_outputs; then
    runtime_build_chain "${_arch}" "${OUTPUT_ROOT}/${_arch}/rootfs" || return 1
    runtime_write_artifact_metadata "${_arch}" "${OUTPUT_ROOT}/${_arch}" || return 1
  else
    runtime_build_chain "${_arch}" || return 1
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
