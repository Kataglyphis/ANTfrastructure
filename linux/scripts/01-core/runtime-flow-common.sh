# shellcheck shell=bash
# runtime-flow-common.sh — shared initialization and defaults for runtime scripts.
# Sourced directly by build-runtime-artifacts.sh and build-runtime-manifest.sh.
[ -n "${_RUNTIME_FLOW_COMMON_SH_LOADED:-}" ] && return 0
_RUNTIME_FLOW_COMMON_SH_LOADED=1
#
# Provides:
#   RUNTIME_FLOW_DEFAULTS_INITIALIZED — flag set after init_runtime_flow_defaults
#   init_runtime_flow_defaults()      — set up shared variable defaults
#
# Shared defaults set by init_runtime_flow_defaults:
#   NERDCTL_BIN, ARTIFACT_IMAGE_PREFIX, ARTIFACT_BUILD_MODE,
#   BASE_DOCKERFILE_PATH, PACKAGE_DOCKERFILE_PATH, WRAPPER_DOCKERFILE_PATH,
#   TORCH_APP_MODE, init_mirror_defaults
#   PUSH_IMAGES=0, PUSH_INTERMEDIATE_IMAGES=0, DRY_RUN=0,
#   PARALLEL_ARCHS=0, MAX_PARALLEL_ARCHS
#
# Note: TARGET_ARCHES / ARCHITECTURES defaults are script-specific (they may
# use different variable names); each script initializes its own arch variable
# after calling init_runtime_flow_defaults.

init_runtime_flow_defaults() {
  [ -n "${RUNTIME_FLOW_DEFAULTS_INITIALIZED:-}" ] && return 0
  RUNTIME_FLOW_DEFAULTS_INITIALIZED=1

  ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-${IMAGE_REGISTRY_PREFIX}:cross-android}"
  ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
  BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
  PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
  WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
  TORCH_APP_MODE="${TORCH_APP_MODE:-}"
  init_mirror_defaults

  # Deliberately CLI-only: these flag vars are hard-reset here and any env
  # values are intentionally discarded (accidental env leakage must never be
  # able to trigger pushes), unlike MAX_PARALLEL_ARCHS below which is
  # env-overridable.
  PUSH_IMAGES=0
  PUSH_INTERMEDIATE_IMAGES=0
  DRY_RUN=0
  PARALLEL_ARCHS=0
  MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"
}
