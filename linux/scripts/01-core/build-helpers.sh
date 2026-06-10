#!/usr/bin/env bash
# build-helpers.sh — nerdctl build wrappers and build-arg helpers.
# shellcheck disable=SC2178  # nameref across functions (separate local scopes)
#
# Provides:
#   run()                         — echo + execute (DO NOT use for secret-bearing args)
#   run_quiet()                   — execute without echoing
#   append_buildkit_host_arg()    — add --buildkit-host if BUILDKIT_HOST is set
#   append_mirror_build_args()    — add USE_FAST_UBUNTU_MIRROR args
#   append_mirror_build_args_from_env() — convenience wrapper
#   append_common_build_args()    — mirror + version build args
#   append_optional_build_arg()   — add --build-arg only if value is non-empty
#   append_runtime_base_parent_build_arg() — optional BASE_IMAGE for base build
#   append_runtime_accelerator_build_args() — ENABLE_NVIDIA / ENABLE_AMD
#   append_runtime_torch_build_args() — accelerator + ONNX/PyTorch args
#   image_exists()                — check if an image exists locally
#   run_nerdctl_build()           — nerdctl build with BUILDKIT_HOST support
#   run_nerdctl_build_to_tag()    — nerdctl build -t <tag> convenience
#   pull_platform_image()         — nerdctl pull --platform

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

# Like run() but does NOT echo the command. Use when build args may contain
# secrets (e.g. GITHUB_TOKEN, registry credentials) that must not appear in logs.
run_quiet() {
  "$@"
}

append_buildkit_host_arg() {
  local -n out_args_ref=$1
  if [ -n "${BUILDKIT_HOST:-}" ]; then
    out_args_ref+=(--buildkit-host "${BUILDKIT_HOST}")
  fi
}

append_mirror_build_args() {
  local -n out_args_ref=$1
  local use_fast_mirror="${2:-${USE_FAST_UBUNTU_MIRROR:-false}}"
  local archive_url="${3:-${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-https://archive.ubuntu.com/ubuntu/}}}"
  local ports_url="${4:-${FAST_UBUNTU_PORTS_MIRROR_URL:-}}"

  out_args_ref+=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${use_fast_mirror}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${archive_url}"
  )

  if [ -n "${ports_url}" ]; then
    out_args_ref+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${ports_url}")
  fi
}

# Convenience wrapper that reads mirror defaults from the environment so callers
# don't need to repeat the same fallback chain.
append_mirror_build_args_from_env() {
  local -n _amfe_out=$1
  append_mirror_build_args _amfe_out \
    "${USE_FAST_UBUNTU_MIRROR:-false}" \
    "${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-https://archive.ubuntu.com/ubuntu/}}" \
    "${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
}

append_common_build_args() {
  local _acba_name="$1"
  append_mirror_build_args "${_acba_name}" "${2:-}" "${3:-}" "${4:-}"
  append_version_build_args "${_acba_name}"
}

append_optional_build_arg() {
  local -n out_args_ref=$1
  local arg_name="$2"
  local arg_value="${3:-}"
  if [ -n "${arg_value}" ]; then
    out_args_ref+=(--build-arg "${arg_name}=${arg_value}")
  fi
}

append_runtime_base_parent_build_arg() {
  append_optional_build_arg "$1" BASE_IMAGE "${BASE_PARENT_IMAGE:-}"
}

append_runtime_accelerator_build_args() {
  append_optional_build_arg "$1" ENABLE_NVIDIA "${ENABLE_NVIDIA:-}"
  append_optional_build_arg "$1" ENABLE_AMD "${ENABLE_AMD:-}"
}

append_runtime_torch_build_args() {
  append_runtime_accelerator_build_args "$1"
  append_optional_build_arg "$1" ONNX_PACKAGE "${ONNX_PACKAGE:-}"
  append_optional_build_arg "$1" PYTORCH_EXTRA "${PYTORCH_EXTRA:-}"
}

image_exists() {
  local nerdctl_bin image_ref
  if [ "$#" -eq 1 ]; then
    nerdctl_bin="${NERDCTL_BIN:-nerdctl}"
    image_ref="$1"
  else
    nerdctl_bin="$1"
    image_ref="$2"
  fi
  "${nerdctl_bin}" image inspect "${image_ref}" >/dev/null 2>&1
}

run_nerdctl_build() {
  local nerdctl_bin="$1"
  shift
  local -a build_cmd=("${nerdctl_bin}" build)
  append_buildkit_host_arg build_cmd
  build_cmd+=("$@")
  run "${build_cmd[@]}"
}

run_nerdctl_build_to_tag() {
  local nerdctl_bin="$1"
  local tag="$2"
  shift 2
  run_nerdctl_build "${nerdctl_bin}" -t "${tag}" "$@"
}

pull_platform_image() {
  local nerdctl_bin="$1"
  local platform="$2"
  local image_ref="$3"
  run "${nerdctl_bin}" pull --platform "${platform}" "${image_ref}"
}
