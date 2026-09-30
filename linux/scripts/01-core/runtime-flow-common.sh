# shellcheck shell=bash
# Shared defaults for build-runtime-artifacts.sh and build-runtime-manifest.sh.
[ -n "${_RUNTIME_FLOW_COMMON_SH_LOADED:-}" ] && return 0
_RUNTIME_FLOW_COMMON_SH_LOADED=1
# Arch defaults stay with each caller, since the two name their arch variable differently.

init_runtime_flow_defaults() {
  [ -n "${RUNTIME_FLOW_DEFAULTS_INITIALIZED:-}" ] && return 0
  RUNTIME_FLOW_DEFAULTS_INITIALIZED=1

  # Same owner as cross-stage-build.sh's prefix, or a non-amd64 host names the AMD box's artifact.
  ARTIFACT_IMAGE_PREFIX="${ARTIFACT_IMAGE_PREFIX:-$(cross_android_tag_prefix)}"
  ARTIFACT_BUILD_MODE="${ARTIFACT_BUILD_MODE:-cross}"
  BASE_DOCKERFILE_PATH="${BASE_DOCKERFILE_PATH:-linux/Dockerfile.base}"
  PACKAGE_DOCKERFILE_PATH="${PACKAGE_DOCKERFILE_PATH:-linux/Dockerfile.package}"
  WRAPPER_DOCKERFILE_PATH="${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}"
  TORCH_APP_MODE="${TORCH_APP_MODE:-}"
  init_mirror_defaults

  # CLI-only, hard-reset so a leaked env var can never trigger a push; MAX_PARALLEL_ARCHS stays env-overridable.
  PUSH_IMAGES=0
  PUSH_INTERMEDIATE_IMAGES=0
  DRY_RUN=0
  PARALLEL_ARCHS=0
  MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"
}
